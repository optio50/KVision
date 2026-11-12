#include "hikvisionmanager.h"
#include "context.h"
#include <QDebug>
#include <QDateTime>
#include <QTemporaryFile>
#include <cstring>
#include <QProcess>
#include <QRegularExpression>
#include <QRegularExpressionMatchIterator>
#include <QThread>
#include <algorithm>

HikvisionManager* HikvisionManager::m_instance = nullptr;

HikvisionManager::HikvisionManager(QObject *parent)
    : QObject(parent)
    , m_initialized(false)
{
    m_instance = this;

    std::thread initThread([this]() {
        if (NET_DVR_Init()) {
            m_initialized = true;
            if (!Context::enableLogs()) {
                NET_DVR_SetLogPrint(FALSE);
            }
            qDebug() << "[Hikvision] HCNetSDK Initialized successfully in background.";
        } else {
            qWarning() << "[Hikvision] Failed to initialize HCNetSDK.";
        }
        {
            std::lock_guard<std::mutex> lock(m_initMutex);
            m_initCompleted = true;
        }
        m_initCond.notify_all();
    });
    initThread.detach();

    // Start background worker thread for PTZ commands
    m_ptzWorker = std::thread(&HikvisionManager::ptzWorkerLoop, this);
}

HikvisionManager::~HikvisionManager()
{
    // Wait for all active async discovery threads to finish
    {
        std::lock_guard<std::mutex> lock(m_discoveryMutex);
        for (QThread *thread : m_discoveryThreads) {
            thread->disconnect(this); // Disconnect all signals connected to this
            thread->wait();
        }
        m_discoveryThreads.clear();
    }

    // Stop the worker thread cleanly first
    {
        std::lock_guard<std::mutex> lock(m_ptzMutex);
        m_ptzWorkerStop = true;
    }
    m_ptzCond.notify_all();
    if (m_ptzWorker.joinable()) {
        m_ptzWorker.join();
    }

    ensureInitialized();

    // Logout all active sessions
    for (auto it = m_sessions.begin(); it != m_sessions.end(); ++it) {
        NET_DVR_Logout(it.value().lUserID);
    }
    m_sessions.clear();

    for (auto it = m_sharedSessions.begin(); it != m_sharedSessions.end(); ++it) {
        NET_DVR_Logout(it.value().lUserID);
    }
    m_sharedSessions.clear();

    if (m_initialized) {
        NET_DVR_Cleanup();
        qDebug() << "[Hikvision] HCNetSDK Cleaned up.";
    }
    m_instance = nullptr;
}

HikvisionManager* HikvisionManager::instance()
{
    return m_instance;
}

static QByteArray fetchUrl(const QString &ip, int port, const QString &username, const QString &password, const QString &path) {
    QProcess process;
    QStringList args;
    args << "-s" << "-k" << "--anyauth" << "-u" << QString("%1:%2").arg(username, password)
         << "--max-time" << "4"
         << QString("http://%1:%2%3").arg(ip).arg(port).arg(path);
    
    qDebug() << "[Hikvision ISAPI] Querying:" << args.last();
    process.start("curl", args);
    if (process.waitForFinished(5000)) {
        QByteArray res = process.readAllStandardOutput();
        if (!res.isEmpty()) return res;
    }

    // Fallback to HTTPS if HTTP failed (e.g. port 443, 8443 or SSL-only NVR)
    QStringList httpsArgs;
    httpsArgs << "-s" << "-k" << "--anyauth" << "-u" << QString("%1:%2").arg(username, password)
              << "--max-time" << "4"
              << QString("https://%1:%2%3").arg(ip).arg(port).arg(path);
    process.start("curl", httpsArgs);
    if (process.waitForFinished(5000)) {
        return process.readAllStandardOutput();
    }
    return QByteArray();
}

// PUT an XML body to an ISAPI endpoint on the camera. Same auth/timeout/fallback
// semantics as fetchUrl(). Returns the response body (usually a ResponseStatus XML).
static QByteArray putUrl(const QString &ip, int port, const QString &username, const QString &password,
                         const QString &path, const QByteArray &body)
{
    const QString tmpFile = QStringLiteral("/tmp/kvision-put-XXXXXX.xml");
    QTemporaryFile tf(tmpFile);
    if (!tf.open()) {
        qWarning() << "[Hikvision ISAPI] Cannot create temp file for PUT body";
        return QByteArray();
    }
    tf.write(body);
    tf.close();
    const QString tfPath = tf.fileName();

    QStringList args;
    args << "-s" << "-k" << "--anyauth" << "-u" << QString("%1:%2").arg(username, password)
         << "--max-time" << "4" << "-X" << "PUT"
         << "--data-binary" << QString("@%1").arg(tfPath)
         << "-H" << "Content-Type: application/xml"
         << QString("http://%1:%2%3").arg(ip).arg(port).arg(path);

    qDebug() << "[Hikvision ISAPI] PUT:" << args.last();
    QProcess process;
    process.start("curl", args);
    QByteArray res;
    if (process.waitForFinished(5000))
        res = process.readAllStandardOutput();

    // Fallback to HTTPS if HTTP failed
    if (res.isEmpty()) {
        QStringList httpsArgs;
        httpsArgs << "-s" << "-k" << "--anyauth" << "-u" << QString("%1:%2").arg(username, password)
                  << "--max-time" << "4" << "-X" << "PUT"
                  << "--data-binary" << QString("@%1").arg(tfPath)
                  << "-H" << "Content-Type: application/xml"
                  << QString("https://%1:%2%3").arg(ip).arg(port).arg(path);
        process.start("curl", httpsArgs);
        if (process.waitForFinished(5000))
            res = process.readAllStandardOutput();
    }

    tf.remove();
    return res;
}

// Unstick a camera whose LAN event-push dispatcher has wedged. For every event trigger of the
// given channel (motion, line crossing, intrusion, tamper, ...) that has the "center"
// (Surveillance Center / LAN push) notification enabled, toggles that notification off and back
// on, restoring the original config. Works for standalone cameras and NVR channels.
// Returns "ok..." or an error/warning string.
QString HikvisionManager::unstickEventDetection(const QString &ip, int httpPort, const QString &username,
                                                const QString &password, int channelId, const QString &label)
{
    const QString cleanIp = ip.trimmed();
    if (cleanIp.isEmpty())
        return QStringLiteral("error: empty ip");

    const int port = httpPort > 0 ? httpPort : 80;
    const int channel = channelId > 0 ? channelId : 1;

    emit unstickProgress(label, QStringLiteral("Reading event triggers..."));

    // 1. Find the triggers that belong to this channel
    QStringList triggerIds;
    const QByteArray listXml = fetchUrl(cleanIp, port, username, password, QStringLiteral("/ISAPI/Event/triggers"));
    if (!listXml.isEmpty()) {
        const QString text = QString::fromUtf8(listXml);
        QRegularExpression blockRx(QStringLiteral("<EventTrigger(?:\\s[^>]*)?>([\\s\\S]*?)</EventTrigger>"));
        QRegularExpression idRx(QStringLiteral("<id>([^<]+)</id>"));
        QRegularExpression chanRx(QStringLiteral("<(?:dynVideoInputChannelID|videoInputChannelID)>(\\d+)</"));
        auto it = blockRx.globalMatch(text);
        while (it.hasNext()) {
            const QString block = it.next().captured(1);
            const QString id = idRx.match(block).captured(1).trimmed();
            if (id.isEmpty())
                continue;
            bool onChannel = false;
            auto cit = chanRx.globalMatch(block);
            while (cit.hasNext()) {
                if (cit.next().captured(1).toInt() == channel)
                    onChannel = true;
            }
            if (onChannel)
                triggerIds << id;
        }
    }
    if (triggerIds.isEmpty()) // older firmware without a trigger list: fall back to motion detection
        triggerIds << QStringLiteral("VMD-%1").arg(channel);

    QRegularExpression centerBlock(
        QStringLiteral("<EventTriggerNotification>\\s*<id>center</id>.*?</EventTriggerNotification>"),
        QRegularExpression::DotMatchesEverythingOption);
    emit unstickProgress(label, QStringLiteral("Checking %1 trigger(s)...").arg(triggerIds.size()));
    auto accepted = [](const QByteArray &r) {
        return r.contains("<statusCode>1</statusCode>") || r.contains("<statusString>OK</statusString>");
    };

    int fixed = 0;
    QStringList problems;
    for (const QString &id : triggerIds) {
        const QString path = QStringLiteral("/ISAPI/Event/triggers/") + id;
        emit unstickProgress(label, QStringLiteral("Checking %1...").arg(id));

        // 2. Read the trigger's current config; skip triggers that don't push to the center
        const QByteArray original = fetchUrl(cleanIp, port, username, password, path);
        if (original.isEmpty())
            continue;
        QString centerOffXml = QString::fromUtf8(original);
        if (!centerBlock.match(centerOffXml).hasMatch())
            continue;
        centerOffXml.remove(centerBlock);

        // 3. PUT center OFF
        emit unstickProgress(label, QStringLiteral("Resetting %1...").arg(id));
        const QByteArray putOff = putUrl(cleanIp, port, username, password, path, centerOffXml.toUtf8());
        if (putOff.isEmpty() || !accepted(putOff)) {
            problems << QStringLiteral("%1: center OFF %2").arg(id, putOff.isEmpty() ? QStringLiteral("failed (no response)")
                                                                                   : QStringLiteral("rejected"));
            continue;
        }

        // 4. PUT original back (center ON - restores the user's config)
        const QByteArray putOn = putUrl(cleanIp, port, username, password, path, original);
        if (putOn.isEmpty() || !accepted(putOn)) {
            problems << QStringLiteral("%1: center left OFF, restore failed - run again").arg(id);
            continue;
        }
        ++fixed;
    }

    if (!problems.isEmpty())
        return QStringLiteral("warning: ") + problems.join(QStringLiteral("; "));
    if (fixed == 0)
        return QStringLiteral("error: no event triggers with center push found for channel %1 (check credentials/connectivity)").arg(channel);
    return QStringLiteral("ok (%1 trigger(s) reset)").arg(fixed);
}

void HikvisionManager::unstickEventDetectionAsync(const QString &ip, int httpPort, const QString &username,
                                                  const QString &password, int channelId, const QString &label)
{
    QThread *thread = QThread::create([this, ip, httpPort, username, password, channelId, label]() {
        const QString result = unstickEventDetection(ip, httpPort, username, password, channelId, label);
        emit unstickFinished(label, result);
    });

    {
        std::lock_guard<std::mutex> lock(m_discoveryMutex);
        m_discoveryThreads.append(thread);
    }
    connect(thread, &QThread::finished, this, [this, thread]() {
        std::lock_guard<std::mutex> lock(m_discoveryMutex);
        m_discoveryThreads.removeOne(thread);
    });
    connect(thread, &QThread::finished, thread, &QThread::deleteLater);
    thread->start();
}

QString HikvisionManager::fetchStreamingChannels(const QString &ip, int httpPort, const QString &username, const QString &password)
{
    QString cleanIp = ip.trimmed();
    if (cleanIp.startsWith(QStringLiteral("http://"), Qt::CaseInsensitive)) cleanIp = cleanIp.mid(7);
    if (cleanIp.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) cleanIp = cleanIp.mid(8);
    if (cleanIp.contains(QLatin1Char(':"'))) cleanIp = cleanIp.section(QLatin1Char('":'), 0, 0);
    if (httpPort <= 0) httpPort = 80;
    QByteArray xml = fetchUrl(cleanIp, httpPort, username, password, QStringLiteral("/ISAPI/Streaming/channels"));
    if (xml.isEmpty() && httpPort != 80) {
        xml = fetchUrl(cleanIp, 80, username, password, QStringLiteral("/ISAPI/Streaming/channels"));
    }
    return QString::fromUtf8(xml);
}

QVariantMap HikvisionManager::proxyCameraCached(const QString &nvrIp, int httpPort, const QString &username, const QString &password, int channelId)
{
    QString cleanIp = nvrIp.trimmed();
    if (cleanIp.contains(QLatin1Char(':')))
        cleanIp = cleanIp.section(QLatin1Char(':'), 0, 0);
    if (httpPort <= 0)
        httpPort = 80;

    if (!m_proxyCache.contains(cleanIp)) {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        if (m_proxyFailedAt.contains(cleanIp) && now - m_proxyFailedAt.value(cleanIp) < 30000)
            return QVariantMap();
        const QByteArray xml = fetchUrl(cleanIp, httpPort, username, password, QStringLiteral("/ISAPI/ContentMgmt/InputProxy/channels"));
        const QString text = QString::fromUtf8(xml);
        QHash<int, QVariantMap> channels;
        QRegularExpression blockRx(QStringLiteral("<InputProxyChannel[^>]*>([\\s\\S]*?)</InputProxyChannel>"));
        QRegularExpression idRx(QStringLiteral("<id>(\\d+)</id>"));
        QRegularExpression ipRx(QStringLiteral("<ipAddress>([^<]+)</ipAddress>"));
        QRegularExpression srcRx(QStringLiteral("<srcInputPort>(\\d+)</srcInputPort>"));
        QRegularExpression mgmtPortRx(QStringLiteral("<managePortNo>(\\d+)</managePortNo>"));
        auto it = blockRx.globalMatch(text);
        while (it.hasNext()) {
            const QString block = it.next().captured(1);
            const int id = idRx.match(block).captured(1).toInt();
            if (id <= 0)
                continue;
            QVariantMap cam;
            int sourceChannel = srcRx.match(block).captured(1).toInt();
            if (sourceChannel <= 0)
                sourceChannel = 1;
            const int mgmtPort = mgmtPortRx.match(block).captured(1).toInt();
            cam.insert(QStringLiteral("ip"), ipRx.match(block).captured(1).trimmed());
            cam.insert(QStringLiteral("channel"), sourceChannel);
            cam.insert(QStringLiteral("sdkPort"), mgmtPort > 0 ? mgmtPort : 8000);
            channels.insert(id, cam);
        }
        if (channels.isEmpty()) {
            m_proxyFailedAt.insert(cleanIp, now);
            return QVariantMap();
        }
        m_proxyFailedAt.remove(cleanIp);
        m_proxyCache.insert(cleanIp, channels);
    }
    return m_proxyCache.value(cleanIp).value(channelId);
}

QHash<int, QVariantMap> HikvisionManager::fetchProxyChannels(const QString &nvrIp, int httpPort, const QString &username, const QString &password)
{
    QHash<int, QVariantMap> channels;
    QString cleanIp = nvrIp.trimmed();
    if (cleanIp.contains(QLatin1Char(':')))
        cleanIp = cleanIp.section(QLatin1Char(':'), 0, 0);
    if (httpPort <= 0)
        httpPort = 80;
    const QByteArray xml = fetchUrl(cleanIp, httpPort, username, password, QStringLiteral("/ISAPI/ContentMgmt/InputProxy/channels"));
    if (xml.isEmpty())
        return channels;
    const QString text = QString::fromUtf8(xml);
    QRegularExpression blockRx(QStringLiteral("<InputProxyChannel[^>]*>([\\s\\S]*?)</InputProxyChannel>"));
    QRegularExpression idRx(QStringLiteral("<id>(\\d+)</id>"));
    QRegularExpression ipRx(QStringLiteral("<ipAddress>([^<]+)</ipAddress>"));
    QRegularExpression srcRx(QStringLiteral("<srcInputPort>(\\d+)</srcInputPort>"));
    QRegularExpression mgmtPortRx(QStringLiteral("<managePortNo>(\\d+)</managePortNo>"));
    auto it = blockRx.globalMatch(text);
    while (it.hasNext()) {
        const QString block = it.next().captured(1);
        const int id = idRx.match(block).captured(1).toInt();
        if (id <= 0)
            continue;
        int sourceChannel = srcRx.match(block).captured(1).toInt();
        if (sourceChannel <= 0)
            sourceChannel = 1;
        const int mgmtPort = mgmtPortRx.match(block).captured(1).toInt();
        QVariantMap cam;
        cam.insert(QStringLiteral("ip"), ipRx.match(block).captured(1).trimmed());
        cam.insert(QStringLiteral("channel"), sourceChannel);
        cam.insert(QStringLiteral("sdkPort"), mgmtPort > 0 ? mgmtPort : 8000);
        channels.insert(id, cam);
    }
    return channels;
}

QVariantMap HikvisionManager::proxyCamera(const QString &nvrIp, int httpPort, const QString &username, const QString &password, int channelId)
{
    QVariantMap result;
    QString cleanIp = nvrIp.trimmed();
    if (cleanIp.contains(QLatin1Char(':"'))) cleanIp = cleanIp.section(QLatin1Char('":'), 0, 0);
    if (httpPort <= 0) httpPort = 80;
    QByteArray xml = fetchUrl(cleanIp, httpPort, username, password, QStringLiteral("/ISAPI/ContentMgmt/InputProxy/channels"));
    if (xml.isEmpty()) return result;

    const QString text = QString::fromUtf8(xml);
    QRegularExpression blockRx(QStringLiteral("<InputProxyChannel[^>]*>([\\s\\S]*?)</InputProxyChannel>"));
    QRegularExpression idRx(QStringLiteral("<id>(\\d+)</id>"));
    QRegularExpression ipRx(QStringLiteral("<ipAddress>([^<]+)</ipAddress>"));
    QRegularExpression srcRx(QStringLiteral("<srcInputPort>(\\d+)</srcInputPort>"));
    QRegularExpression mgmtPortRx(QStringLiteral("<managePortNo>(\\d+)</managePortNo>"));
    auto it = blockRx.globalMatch(text);
    while (it.hasNext()) {
        const QString block = it.next().captured(1);
        if (idRx.match(block).captured(1).toInt() != channelId) continue;
        const int mgmtPort = mgmtPortRx.match(block).captured(1).toInt();
        result.insert(QStringLiteral("sdkPort"), mgmtPort > 0 ? mgmtPort : 8000);
        int sourceChannel = srcRx.match(block).captured(1).toInt();
        if (sourceChannel <= 0) sourceChannel = 1;
        result.insert(QStringLiteral("ip"), ipRx.match(block).captured(1).trimmed());
        result.insert(QStringLiteral("channel"), sourceChannel);
        return result;
    }
    return result;
}

QVariantList HikvisionManager::discoverCameras(const QString &ip, int port, int httpPort, const QString &username, const QString &password)
{
    QVariantList cameraList;
    QSet<int> seenChannels;

    QString cleanIp = ip.trimmed();
    if (cleanIp.startsWith("http://", Qt::CaseInsensitive)) cleanIp = cleanIp.mid(7);
    if (cleanIp.startsWith("https://", Qt::CaseInsensitive)) cleanIp = cleanIp.mid(8);
    if (cleanIp.contains(":")) cleanIp = cleanIp.section(':', 0, 0);

    // Try ISAPI HTTP discovery first to support real NVRs/DVRs
    if (httpPort <= 0) {
        httpPort = 80;
    }
    if (port <= 0) {
        port = 8000;
    }

    qDebug() << "[Hikvision] Attempting real NVR HTTP ISAPI discovery on" << cleanIp << "port" << httpPort;

    // 1. Try IP Proxy Channels (/ISAPI/ContentMgmt/InputProxy/channels) - Standard for Hikvision IP NVRs
    QByteArray xmlIP = fetchUrl(cleanIp, httpPort, username, password, "/ISAPI/ContentMgmt/InputProxy/channels");
    if (xmlIP.isEmpty() && httpPort != 80) {
        xmlIP = fetchUrl(cleanIp, 80, username, password, "/ISAPI/ContentMgmt/InputProxy/channels");
        if (!xmlIP.isEmpty()) {
            httpPort = 80;
        }
    }
    if (!xmlIP.isEmpty()) {
        qDebug() << "[Hikvision ISAPI] Found InputProxy channels XML. Parsing...";
        QRegularExpression rxIP("<InputProxyChannel[^>]*>([\\s\\S]*?)</InputProxyChannel>");
        QRegularExpressionMatchIterator iIP = rxIP.globalMatch(QString::fromUtf8(xmlIP));
        while (iIP.hasNext()) {
            QRegularExpressionMatch match = iIP.next();
            QString channelXml = match.captured(1);
            
            QRegularExpression rxId("<id>(\\d+)</id>");
            QRegularExpression rxName("<name>(.*?)</name>");
            QRegularExpression rxChanName("<channelName>(.*?)</channelName>");
            
            int id = rxId.match(channelXml).captured(1).toInt();
            QString name = rxName.match(channelXml).captured(1);
            if (name.isEmpty()) {
                name = rxChanName.match(channelXml).captured(1);
            }
            
            if (id > 0 && !seenChannels.contains(id)) {
                seenChannels.insert(id);
                QVariantMap cam;
                cam.insert("channelId", id);
                cam.insert("name", name.isEmpty() ? QString("Camera %1").arg(id) : name);
                cam.insert("recorderIp", cleanIp);
                cameraList.append(cam);
                qDebug() << "[Hikvision ISAPI] Discovered proxy IP channel:" << id << "name:" << name;
            }
        }
    }

    // 2. Try Analog/TVI Video Inputs (/ISAPI/System/Video/inputs/channels) - For DVRs / Hybrid NVRs
    QByteArray xmlAnalog = fetchUrl(cleanIp, httpPort, username, password, "/ISAPI/System/Video/inputs/channels");
    if (xmlAnalog.isEmpty() && httpPort != 80 && cameraList.isEmpty()) {
        xmlAnalog = fetchUrl(cleanIp, 80, username, password, "/ISAPI/System/Video/inputs/channels");
        if (!xmlAnalog.isEmpty()) {
            httpPort = 80;
        }
    }
    if (!xmlAnalog.isEmpty()) {
        qDebug() << "[Hikvision ISAPI] Found Video inputs channels XML. Parsing...";
        QRegularExpression rxChan("<VideoInputChannel[^>]*>([\\s\\S]*?)</VideoInputChannel>");
        QRegularExpressionMatchIterator iChan = rxChan.globalMatch(QString::fromUtf8(xmlAnalog));
        while (iChan.hasNext()) {
            QRegularExpressionMatch match = iChan.next();
            QString channelXml = match.captured(1);
            
            QRegularExpression rxId("<id>(\\d+)</id>");
            QRegularExpression rxName("<name>(.*?)</name>");
            QRegularExpression rxChanName("<channelName>(.*?)</channelName>");
            QRegularExpression rxEnabled("<videoInputEnabled>(.*?)</videoInputEnabled>");
            
            int id = rxId.match(channelXml).captured(1).toInt();
            QString name = rxName.match(channelXml).captured(1);
            if (name.isEmpty()) {
                name = rxChanName.match(channelXml).captured(1);
            }
            QString enabled = rxEnabled.match(channelXml).captured(1);
            
            if (id > 0 && enabled != "false" && !seenChannels.contains(id)) {
                seenChannels.insert(id);
                QVariantMap cam;
                cam.insert("channelId", id);
                cam.insert("name", name.isEmpty() ? QString("Camera %1").arg(id) : name);
                cam.insert("recorderIp", cleanIp);
                cameraList.append(cam);
                qDebug() << "[Hikvision ISAPI] Discovered analog channel:" << id << "name:" << name;
            }
        }
    }

    // 3. Try Streaming Channels (/ISAPI/Streaming/channels) - Universal fallback on all Hikvision devices
    if (cameraList.isEmpty()) {
        QByteArray xmlStreaming = fetchUrl(cleanIp, httpPort, username, password, "/ISAPI/Streaming/channels");
        if (xmlStreaming.isEmpty() && httpPort != 80) {
            xmlStreaming = fetchUrl(cleanIp, 80, username, password, "/ISAPI/Streaming/channels");
        }
        if (!xmlStreaming.isEmpty()) {
            qDebug() << "[Hikvision ISAPI] Found Streaming channels XML. Parsing...";
            QRegularExpression rxStream("<StreamingChannel[^>]*>([\\s\\S]*?)</StreamingChannel>");
            QRegularExpressionMatchIterator iStream = rxStream.globalMatch(QString::fromUtf8(xmlStreaming));
            while (iStream.hasNext()) {
                QRegularExpressionMatch match = iStream.next();
                QString channelXml = match.captured(1);
                
                QRegularExpression rxId("<id>(\\d+)</id>");
                QRegularExpression rxName("<channelName>(.*?)</channelName>");
                QRegularExpression rxEnabled("<enabled>(.*?)</enabled>");
                
                int rawId = rxId.match(channelXml).captured(1).toInt();
                QString name = rxName.match(channelXml).captured(1);
                QString enabled = rxEnabled.match(channelXml).captured(1);
                
                if (rawId > 0 && enabled != "false") {
                    int baseChanId = (rawId >= 100) ? (rawId / 100) : rawId;
                    if (!seenChannels.contains(baseChanId)) {
                        seenChannels.insert(baseChanId);
                        QVariantMap cam;
                        cam.insert("channelId", baseChanId);
                        cam.insert("name", name.isEmpty() ? QString("Camera %1").arg(baseChanId) : name);
                        cam.insert("recorderIp", cleanIp);
                        cameraList.append(cam);
                        qDebug() << "[Hikvision ISAPI] Discovered streaming channel:" << baseChanId << "(raw ID: " << rawId << ") name:" << name;
                    }
                }
            }
        }
    }

    if (!cameraList.isEmpty()) {
        return cameraList;
    }

    qDebug() << "[Hikvision] Real NVR HTTP ISAPI discovery returned no channels. Falling back to SDK/Mock...";

    if (!m_initialized) {
        qWarning() << "[Hikvision] Cannot login: SDK not initialized.";
        return cameraList;
    }

    // Logout from previous session on same IP if any
    logout(ip);

    NET_DVR_USER_LOGIN_INFO loginInfo;
    std::memset(&loginInfo, 0, sizeof(NET_DVR_USER_LOGIN_INFO));
    
    std::strncpy(loginInfo.sDeviceAddress, ip.toUtf8().constData(), sizeof(loginInfo.sDeviceAddress) - 1);
    loginInfo.wPort = static_cast<WORD>(port);
    std::strncpy(loginInfo.sUserName, username.toUtf8().constData(), sizeof(loginInfo.sUserName) - 1);
    std::strncpy(loginInfo.sPassword, password.toUtf8().constData(), sizeof(loginInfo.sPassword) - 1);
    loginInfo.bUseAsynLogin = FALSE;
    loginInfo.byLoginMode = 0; // Private mode

    NET_DVR_DEVICEINFO_V40 deviceInfo;
    std::memset(&deviceInfo, 0, sizeof(NET_DVR_DEVICEINFO_V40));

    LONG lUserID = NET_DVR_Login_V40(&loginInfo, &deviceInfo);
    if (lUserID < 0) {
        qWarning() << "[Hikvision] Login failed for IP:" << ip;
        return cameraList;
    }

    bool wasLogged = false;
    bool isLoggedNow = false;
    {
        std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
        wasLogged = isLoggedInternal(ip);
        m_sessions.insert(ip, {lUserID, deviceInfo});
        isLoggedNow = isLoggedInternal(ip);
    }
    qDebug() << "[Hikvision] Logged in successfully to IP:" << ip << "with UserID:" << lUserID;
    if (wasLogged != isLoggedNow) {
        emit sessionStatusChanged(ip, isLoggedNow);
    }

    // Discover real cameras via NET_DVR_GET_IPPARACFG_V40
    NET_DVR_IPPARACFG_V40 ipParaCfg;
    std::memset(&ipParaCfg, 0, sizeof(NET_DVR_IPPARACFG_V40));
    DWORD bytesReturned = 0;
    
    BOOL getCfgRet = NET_DVR_GetDVRConfig(lUserID, NET_DVR_GET_IPPARACFG_V40, 0, &ipParaCfg, sizeof(NET_DVR_IPPARACFG_V40), &bytesReturned);
    
    if (getCfgRet) {
        DWORD startDChan = ipParaCfg.dwStartDChan;
        DWORD ipChanNum = ipParaCfg.dwDChanNum;
        if (ipChanNum == 0) ipChanNum = 64; // Max support
        
        for (DWORD i = 0; i < ipChanNum; ++i) {
            if (ipParaCfg.struIPDevInfo[i].byEnable == 1) {
                int chanId = static_cast<int>(startDChan + i);
                QVariantMap cam;
                cam.insert("channelId", chanId);
                cam.insert("name", QString("Camera %1").arg(i + 1));
                cam.insert("recorderIp", ip);
                cameraList.append(cam);
                qDebug() << "[Hikvision] Discovered active IP camera on channel:" << chanId;
            }
        }
    }
    
    // Fallback if no active IP cameras found or config query failed
    if (cameraList.isEmpty()) {
        int startChan = deviceInfo.struDeviceV30.byStartChan;
        int numChan = deviceInfo.struDeviceV30.byIPChanNum;
        
        if (numChan == 0) {
            startChan = deviceInfo.struDeviceV30.byStartChan;
            numChan = deviceInfo.struDeviceV30.byChanNum;
        }
 
        if (numChan == 0) {
            numChan = 4;
            startChan = 1;
        }

        for (int i = 0; i < numChan; ++i) {
            int chanId = startChan + i;
            QVariantMap cam;
            cam.insert("channelId", chanId);
            cam.insert("name", QString("Camera %1").arg(i + 1));
            cam.insert("recorderIp", ip);
            cameraList.append(cam);
        }
    }

    return cameraList;
}

void HikvisionManager::discoverCamerasAsync(const QString &ip, int port, int httpPort, const QString &username, const QString &password)
{
    QThread *thread = QThread::create([this, ip, port, httpPort, username, password]() {
        QVariantList cameras = discoverCameras(ip, port, httpPort, username, password);
        bool success = !cameras.isEmpty();
        QString errorMsg = success ? "" : tr("LNG_00099");
        emit discoveryFinished(ip, cameras, success, errorMsg);
    });

    {
        std::lock_guard<std::mutex> lock(m_discoveryMutex);
        m_discoveryThreads.append(thread);
    }

    connect(thread, &QThread::finished, this, [this, thread]() {
        std::lock_guard<std::mutex> lock(m_discoveryMutex);
        m_discoveryThreads.removeOne(thread);
    });

    connect(thread, &QThread::finished, thread, &QThread::deleteLater);
    thread->start();
}

void HikvisionManager::logout(const QString &ip)
{
    LONG lUserID = -1;
    bool wasLogged = false;
    bool isLoggedNow = false;
    {
        std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
        wasLogged = isLoggedInternal(ip);
        if (m_sessions.contains(ip)) {
            lUserID = m_sessions.take(ip).lUserID;
        }
        isLoggedNow = isLoggedInternal(ip);
    }
    if (lUserID >= 0) {
        ensureInitialized();
        NET_DVR_Logout(lUserID);
        qDebug() << "[Hikvision] Logged out from IP:" << ip << "UserID:" << lUserID;
    }
    if (wasLogged != isLoggedNow) {
        emit sessionStatusChanged(ip, isLoggedNow);
    }
}

bool HikvisionManager::isLogged(const QString &ip)
{
    std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
    return isLoggedInternal(ip);
}

bool HikvisionManager::isLoggedInternal(const QString &ip) const
{
    return m_sessions.contains(ip) || m_sharedSessions.contains(ip);
}

bool HikvisionManager::getDeviceInfo(const QString &ip, NET_DVR_DEVICEINFO_V40 &deviceInfo)
{
    std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
    if (m_sessions.contains(ip)) {
        deviceInfo = m_sessions.value(ip).deviceInfo;
        return true;
    }
    if (m_sharedSessions.contains(ip)) {
        deviceInfo = m_sharedSessions.value(ip).deviceInfo;
        return true;
    }
    return false;
}

LONG HikvisionManager::getSession(const QString &ip, int port, const QString &username, const QString &password)
{
    bool wasLogged = false;
    bool isLoggedNow = false;

    // 1. Check if already logged in
    {
        std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
        if (m_sessions.contains(ip)) {
            return m_sessions.value(ip).lUserID;
        }
        if (m_sharedSessions.contains(ip)) {
            return m_sharedSessions.value(ip).lUserID;
        }
        wasLogged = isLoggedInternal(ip);
    }

    // 2. Not logged in, log in
    ensureInitialized();

    if (!m_initialized) {
        qWarning() << "[Hikvision] Cannot get session: SDK not initialized.";
        return -1;
    }

    NET_DVR_USER_LOGIN_INFO loginInfo;
    std::memset(&loginInfo, 0, sizeof(NET_DVR_USER_LOGIN_INFO));
    std::strncpy(loginInfo.sDeviceAddress, ip.toUtf8().constData(), sizeof(loginInfo.sDeviceAddress) - 1);
    loginInfo.wPort = static_cast<WORD>(port);
    std::strncpy(loginInfo.sUserName, username.toUtf8().constData(), sizeof(loginInfo.sUserName) - 1);
    std::strncpy(loginInfo.sPassword, password.toUtf8().constData(), sizeof(loginInfo.sPassword) - 1);
    loginInfo.bUseAsynLogin = FALSE;
    loginInfo.byLoginMode = 0; // Private mode

    NET_DVR_DEVICEINFO_V40 deviceInfo;
    std::memset(&deviceInfo, 0, sizeof(NET_DVR_DEVICEINFO_V40));

    LONG lUserID = NET_DVR_Login_V40(&loginInfo, &deviceInfo);
    if (lUserID < 0) {
        DWORD err = NET_DVR_GetLastError();
        qWarning() << "[Hikvision] getSession login FAILED for IP:" << ip << "Error:" << err;
        return -1;
    }

    {
        std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
        m_sessions.insert(ip, {lUserID, deviceInfo});
        isLoggedNow = isLoggedInternal(ip);
    }

    qDebug() << "[Hikvision] getSession login SUCCESS for IP:" << ip << "UserID:" << lUserID;
    if (wasLogged != isLoggedNow) {
        emit sessionStatusChanged(ip, isLoggedNow);
    }

    return lUserID;
}

qint64 HikvisionManager::deviceTimeMs(const QString &ip, int port, const QString &username, const QString &password)
{
    LONG lUserID = getSession(ip, port, username, password);
    if (lUserID < 0) {
        qWarning() << "[Hikvision] deviceTimeMs failed to get session for IP:" << ip;
        return -1;
    }
    NET_DVR_TIME t;
    std::memset(&t, 0, sizeof(t));
    DWORD returned = 0;
    if (!NET_DVR_GetDVRConfig(lUserID, NET_DVR_GET_TIMECFG, 0, &t, sizeof(t), &returned)) {
        qWarning() << "[Hikvision] NET_DVR_GET_TIMECFG failed for" << ip << "error" << NET_DVR_GetLastError();
        return -1;
    }
    QDateTime dt(QDate(static_cast<int>(t.dwYear), static_cast<int>(t.dwMonth), static_cast<int>(t.dwDay)),
                 QTime(static_cast<int>(t.dwHour), static_cast<int>(t.dwMinute), static_cast<int>(t.dwSecond)),
                 Qt::LocalTime);
    return dt.isValid() ? dt.toMSecsSinceEpoch() : -1;
}

bool HikvisionManager::forceIFrame(const QString &ip, int port, const QString &username, const QString &password, int channelId)
{
    LONG lUserID = getSession(ip, port, username, password);
    if (lUserID < 0) {
        qWarning() << "[Hikvision] forceIFrame failed to get session for IP:" << ip;
        return false;
    }

    NET_DVR_DEVICEINFO_V40 deviceInfo;
    int targetChannel = channelId;
    if (getDeviceInfo(ip, deviceInfo)) {
        int startDChan = deviceInfo.struDeviceV30.byStartDChan;
        int chanNum = deviceInfo.struDeviceV30.byChanNum;
        int startChan = deviceInfo.struDeviceV30.byStartChan;
        if (startDChan > 0 && channelId < startDChan) {
            if (channelId <= chanNum) {
                targetChannel = startChan + channelId - 1;
            } else {
                targetChannel = startDChan + (channelId - chanNum) - 1;
            }
            qDebug() << "[Hikvision] Translated logical channel" << channelId << "to SDK channel ID" << targetChannel << "for MakeKeyFrame";
        }
    }

    // Wywołanie API Hikvision wymuszające I-Frame (Main stream)
    BOOL ret = NET_DVR_MakeKeyFrame(lUserID, static_cast<LONG>(targetChannel));
    if (!ret) {
        DWORD err = NET_DVR_GetLastError();
        qWarning() << "[Hikvision] NET_DVR_MakeKeyFrame failed for IP:" << ip << "Channel:" << targetChannel << "Error:" << err;
        
        // Czasami urządzenia wspierają tylko MakeKeyFrameSub dla sub-streamu, 
        // ale w KVision problem dotyczy głównie Main streamu.
        return false;
    }
    
    qDebug() << "[Hikvision] NET_DVR_MakeKeyFrame succeeded for IP:" << ip << "Channel:" << targetChannel;
    return true;
}

bool HikvisionManager::ptzZoom(const QString &ip, int port, const QString &username, const QString &password, int channelId, int command, bool stop)
{
    {
        std::lock_guard<std::mutex> lock(m_ptzMutex);
        m_ptzQueue.push({ip, port, username, password, channelId, command, stop, 0});
    }
    m_ptzCond.notify_one();
    return true;
}

bool HikvisionManager::ptzPreset(const QString &ip, int port, const QString &username, const QString &password, int channelId, int command, int presetIndex)
{
    {
        std::lock_guard<std::mutex> lock(m_ptzMutex);
        m_ptzQueue.push({ip, port, username, password, channelId, command, false, presetIndex});
    }
    m_ptzCond.notify_one();
    return true;
}

void HikvisionManager::ptzWorkerLoop()
{
    while (true) {
        PtzCommand cmd;
        {
            std::unique_lock<std::mutex> lock(m_ptzMutex);
            m_ptzCond.wait(lock, [this]() { return m_ptzWorkerStop || !m_ptzQueue.empty(); });
            if (m_ptzWorkerStop && m_ptzQueue.empty()) {
                break;
            }
            cmd = m_ptzQueue.front();
            m_ptzQueue.pop();
        }

        // Process the command asynchronously
        LONG lUserID = getSession(cmd.ip, cmd.port, cmd.username, cmd.password);
        if (lUserID < 0) {
            qWarning() << "[Hikvision PTZ Worker] Failed to get session for IP:" << cmd.ip;
            continue;
        }

        NET_DVR_DEVICEINFO_V40 deviceInfo;
        int targetChannel = cmd.channelId;
        if (getDeviceInfo(cmd.ip, deviceInfo)) {
            int startDChan = deviceInfo.struDeviceV30.byStartDChan;
            int chanNum = deviceInfo.struDeviceV30.byChanNum;
            int startChan = deviceInfo.struDeviceV30.byStartChan;
            if (startDChan > 0 && cmd.channelId < startDChan) {
                if (cmd.channelId <= chanNum) {
                    targetChannel = startChan + cmd.channelId - 1;
                } else {
                    targetChannel = startDChan + (cmd.channelId - chanNum) - 1;
                }
                qDebug() << "[Hikvision PTZ Worker] Translated logical channel" << cmd.channelId << "to SDK channel ID" << targetChannel;
            }
        }

        BOOL ret = FALSE;
        if (cmd.presetIndex > 0) {
            // Preset command (SET_PRESET=8, GOTO_PRESET=39, CLE_PRESET=9) — acts on a preset slot
            ret = NET_DVR_PTZPreset_Other(lUserID, static_cast<LONG>(targetChannel), static_cast<DWORD>(cmd.command), static_cast<DWORD>(cmd.presetIndex));
        } else {
            DWORD dwStop = cmd.stop ? 1 : 0;
            ret = NET_DVR_PTZControl_Other(lUserID, static_cast<LONG>(targetChannel), static_cast<DWORD>(cmd.command), dwStop);
        }
        if (!ret) {
            DWORD err = NET_DVR_GetLastError();
            qWarning() << "[Hikvision PTZ Worker] PTZ Control failed for IP:" << cmd.ip << "Channel:" << targetChannel 
                       << "Command:" << cmd.command << "Preset:" << cmd.presetIndex << "Stop:" << cmd.stop << "Error:" << err;
        } else {
            qDebug() << "[Hikvision PTZ Worker] PTZ Control succeeded for IP:" << cmd.ip << "Channel:" << targetChannel 
                     << "Command:" << cmd.command << "Preset:" << cmd.presetIndex << "Stop:" << cmd.stop;
        }
    }
}

LONG HikvisionManager::loginShared(const QString &ip, int port, const QString &username, const QString &password, NET_DVR_DEVICEINFO_V40 &deviceInfo)
{
    bool wasLogged = false;
    bool isLoggedNow = false;
    LONG lUserID = -1;

    {
        std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
        if (m_sharedSessions.contains(ip)) {
            auto &session = m_sharedSessions[ip];
            session.refCount++;
            deviceInfo = session.deviceInfo;
            qDebug() << "[Hikvision Shared] Reusing session for IP:" << ip << "UserID:" << session.lUserID << "RefCount:" << session.refCount;
            return session.lUserID;
        }
        wasLogged = isLoggedInternal(ip);
    }

    qDebug() << "[Hikvision Shared] Creating NEW session for IP:" << ip << ":" << port;

    ensureInitialized();

    if (!m_initialized) {
        qWarning() << "[Hikvision Shared] Cannot login: SDK not initialized.";
        return -1;
    }

    NET_DVR_USER_LOGIN_INFO loginInfo;
    std::memset(&loginInfo, 0, sizeof(NET_DVR_USER_LOGIN_INFO));
    std::strncpy(loginInfo.sDeviceAddress, ip.toUtf8().constData(), sizeof(loginInfo.sDeviceAddress) - 1);
    loginInfo.wPort = static_cast<WORD>(port);
    std::strncpy(loginInfo.sUserName, username.toUtf8().constData(), sizeof(loginInfo.sUserName) - 1);
    std::strncpy(loginInfo.sPassword, password.toUtf8().constData(), sizeof(loginInfo.sPassword) - 1);
    loginInfo.bUseAsynLogin = FALSE;
    loginInfo.byLoginMode = 0;

    NET_DVR_DEVICEINFO_V40 devInfo;
    std::memset(&devInfo, 0, sizeof(NET_DVR_DEVICEINFO_V40));

    lUserID = NET_DVR_Login_V40(&loginInfo, &devInfo);
    if (lUserID < 0) {
        DWORD err = NET_DVR_GetLastError();
        qWarning() << "[Hikvision Shared] Login FAILED for IP:" << ip << "Error:" << err;
        return -1;
    }

    {
        std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
        SharedSession session;
        session.lUserID = lUserID;
        session.deviceInfo = devInfo;
        session.refCount = 1;

        m_sharedSessions.insert(ip, session);
        deviceInfo = devInfo;
        isLoggedNow = isLoggedInternal(ip);
    }

    qDebug() << "[Hikvision Shared] Login SUCCESS for IP:" << ip << "UserID:" << lUserID;
    if (wasLogged != isLoggedNow) {
        emit sessionStatusChanged(ip, isLoggedNow);
    }
    return lUserID;
}

void HikvisionManager::logoutShared(const QString &ip)
{
    bool wasLogged = false;
    bool isLoggedNow = false;
    LONG lUserIDToLogout = -1;

    {
        std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
        wasLogged = isLoggedInternal(ip);
        if (m_sharedSessions.contains(ip)) {
            auto &session = m_sharedSessions[ip];
            session.refCount--;
            qDebug() << "[Hikvision Shared] Decremented refCount for IP:" << ip << "New RefCount:" << session.refCount;
            if (session.refCount <= 0) {
                lUserIDToLogout = session.lUserID;
                m_sharedSessions.remove(ip);
            }
        }
        isLoggedNow = isLoggedInternal(ip);
    }

    if (lUserIDToLogout >= 0) {
        ensureInitialized();
        NET_DVR_Logout(lUserIDToLogout);
        qDebug() << "[Hikvision Shared] Logged out session for IP:" << ip << "UserID:" << lUserIDToLogout;
    }

    if (wasLogged != isLoggedNow) {
        emit sessionStatusChanged(ip, isLoggedNow);
    }
}

void HikvisionManager::forceLogoutShared(const QString &ip)
{
    bool wasLogged = false;
    bool isLoggedNow = false;
    LONG lUserIDToLogout = -1;

    {
        std::lock_guard<std::mutex> lock(m_sharedSessionsMutex);
        wasLogged = isLoggedInternal(ip);
        if (m_sharedSessions.contains(ip)) {
            auto &session = m_sharedSessions[ip];
            lUserIDToLogout = session.lUserID;
            m_sharedSessions.remove(ip);
            qDebug() << "[Hikvision Shared] Force logout requested. Removing session for IP:" << ip << "UserID:" << lUserIDToLogout;
        }
        isLoggedNow = isLoggedInternal(ip);
    }

    if (lUserIDToLogout >= 0) {
        ensureInitialized();
        NET_DVR_Logout(lUserIDToLogout);
        qDebug() << "[Hikvision Shared] Logged out session for IP (force):" << ip << "UserID:" << lUserIDToLogout;
    }

    if (wasLogged != isLoggedNow) {
        emit sessionStatusChanged(ip, isLoggedNow);
    }
}

void HikvisionManager::ensureInitialized() const
{
    std::unique_lock<std::mutex> lock(m_initMutex);
    m_initCond.wait(lock, [this]() { return m_initCompleted; });
}
