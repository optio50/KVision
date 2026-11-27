#include "hikvisionisapi.h"
#include <QNetworkRequest>
#include <QUrl>
#include <QXmlStreamReader>
#include <QDebug>
#include <QThread>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QProcess>
#include <QTemporaryFile>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QLocale>
#include <QRegularExpression>
#include <QSettings>
#include <algorithm>
#include <cstring>
#include "hikvisionmanager.h"
#include "context.h"
#include "config.h"
#include "recordersecrets.h"

HikvisionISAPI::HikvisionISAPI(QObject *parent)
    : QObject(parent)
{
    m_netManager = new QNetworkAccessManager(this);
    connect(m_netManager, &QNetworkAccessManager::authenticationRequired,
            this, &HikvisionISAPI::onAuthenticationRequired);
}

void HikvisionISAPI::searchRecordings(const QVariantMap &recorderInfo, int channelId, const QDateTime &start, const QDateTime &end)
{
    QString sessionId = QUuid::createUuid().toString();
    HikvisionSearchSession session;
    session.recorderInfo = recorderInfo;
    session.channelId = channelId;
    session.startTime = start;
    session.endTime = end;
    session.isMonthSearch = false;
    session.currentPosition = 1;
    m_sessions[sessionId] = session;

    doSearchRequest(sessionId);
}

// What the recorder says a saved event was, for the colour on the timeline. Motion is its own group; the smart
// events carry a minor type (line crossing, field detection = intrusion, region entrance, region exit...).
static QString eventKind(WORD major, WORD minor)
{
    if (major == EVENT_MOT_DET)
        return QStringLiteral("motion");
    if (major == EVENT_VCA_DETECTION) {
        switch (minor) {
        case EVENT_VCA_TRAVERSE_PLANE: return QStringLiteral("line");
        case EVENT_FIELD_DETECTION: return QStringLiteral("intrusion");
        case EVENT_ENTER_REGION: return QStringLiteral("enter");
        case EVENT_EXIT_REGION: return QStringLiteral("exit");
        default: break;
        }
    }
    return QStringLiteral("other");
}

void HikvisionISAPI::searchEvents(const QVariantMap &recorderInfo, int channelId, const QDateTime &start, const QDateTime &end)
{
    HikvisionSearchSession session;
    session.recorderInfo = recorderInfo;
    session.channelId = channelId;
    session.startTime = start;
    session.endTime = end;
    session.isMonthSearch = false;

    QThread *worker = QThread::create([this, session]() {
        const QString ip = session.recorderInfo.value("ip").toString();
        const int port = session.recorderInfo.value("sdkPort").toInt() > 0
            ? session.recorderInfo.value("sdkPort").toInt()
            : session.recorderInfo.value("port").toInt();
        const QString username = session.recorderInfo.value("username").toString();
        const QString password = session.recorderInfo.value("password").toString();

        NET_DVR_DEVICEINFO_V40 deviceInfo;
        std::memset(&deviceInfo, 0, sizeof(deviceInfo));
        const LONG userId = HikvisionManager::instance()->loginShared(ip, port > 0 ? port : 8000, username, password, deviceInfo);
        QVariantList segments;
        if (userId >= 0) {
            int channel = session.channelId;
            const auto &info = deviceInfo.struDeviceV30;
            if (info.byChanNum == 0 && info.byIPChanNum > 0)
                channel = session.channelId + info.byStartDChan - 1;
            else if (info.byChanNum > 0 && session.channelId > info.byChanNum)
                channel = info.byStartDChan + (session.channelId - info.byChanNum) - 1;
            else if (info.byChanNum > 0)
                channel = session.channelId + info.byStartChan - 1;

            // Continuous files do not carry the red smart marks. Those live in the event log.
            const WORD majorTypes[] = {EVENT_MOT_DET, EVENT_VCA_DETECTION, EVENT_VCA_BEHAVIOR};
            for (WORD majorType : majorTypes) {
                NET_DVR_SEARCH_EVENT_PARAM_V40 param;
                std::memset(&param, 0, sizeof(param));
                param.wMajorType = majorType;
                param.wMinorType = 0xffff;
                param.byLockType = 0xff;
                fillSdkTime(param.struStartTime, session.startTime);
                fillSdkTime(param.struEndTime, session.endTime);
                if (majorType == EVENT_MOT_DET) {
                    param.uSeniorParam.struMotionParam.wMotDetChanNo[0] = static_cast<WORD>(channel);
                } else if (majorType == EVENT_VCA_BEHAVIOR) {
                    param.uSeniorParam.struVcaParam.wChanNo[0] = static_cast<WORD>(channel);
                    param.uSeniorParam.struVcaParam.byRuleID = 0xff;
                } else {
                    param.uSeniorParam.struVCADetect.wChanNo[0] = static_cast<WORD>(channel);
                }

                const LONG findHandle = NET_DVR_FindFileByEvent_V40(userId, &param);
                if (findHandle < 0) {
                    qDebug() << "[ISAPI] Event search failed for channel" << channel
                               << "major" << majorType << "error" << NET_DVR_GetLastError();
                    continue;
                }
                int accepted = 0;
                NET_DVR_SEARCH_EVENT_RET_V40 event;
                int guard = 0;
                while (guard++ < 4000) {
                    const LONG state = NET_DVR_FindNextEvent_V40(findHandle, &event);
                    if (state == 1000) {
                        const NET_DVR_TIME &rawStart = event.struStartTime;
                        const NET_DVR_TIME &rawEnd = event.struEndTime;
                        QDateTime eventStart(QDate(rawStart.dwYear, rawStart.dwMonth, rawStart.dwDay),
                                             QTime(rawStart.dwHour, rawStart.dwMinute, rawStart.dwSecond));
                        QDateTime eventEnd(QDate(rawEnd.dwYear, rawEnd.dwMonth, rawEnd.dwDay),
                                           QTime(rawEnd.dwHour, rawEnd.dwMinute, rawEnd.dwSecond));
                        if (!eventStart.isValid())
                            continue;
                        if (!eventEnd.isValid() || eventEnd <= eventStart)
                            eventEnd = eventStart.addSecs(10);
                        if (accepted < 5) {
                            qDebug() << "[ISAPI] Event channel" << channel
                                     << "major" << event.wMajorType << "minor" << event.wMinorType
                                     << eventStart.toString(Qt::ISODate) << eventEnd.toString(Qt::ISODate);
                        }
                        QVariantMap segment;
                        segment["startTime"] = eventStart.toMSecsSinceEpoch();
                        segment["endTime"] = eventEnd.toMSecsSinceEpoch();
                        segment["timeIsLocal"] = true;
                        segment["event"] = true;
                        segment["kind"] = eventKind(event.wMajorType, event.wMinorType);
                        segments.append(segment);
                        accepted++;
                    } else if (state == 1002) {
                        QThread::msleep(10);
                    } else {
                        break;
                    }
                }
                NET_DVR_FindClose_V30(findHandle);
                qDebug() << "[ISAPI] Event search channel" << channel << "major" << majorType << "accepted" << accepted;
            }
            qDebug() << "[ISAPI] Event search finished for channel" << channel << "events" << segments.count();
        }

        QMetaObject::invokeMethod(this, [this, session, segments]() {
            emit eventsFinished(session.recorderInfo.value("ip").toString(), session.channelId, session.startTime, segments);
        }, Qt::QueuedConnection);
    });
    connect(worker, &QThread::finished, worker, &QThread::deleteLater);
    worker->start();
}

void HikvisionISAPI::searchMonthAvailability(const QVariantMap &recorderInfo, int channelId, int year, int month)
{
    QString sessionId = QUuid::createUuid().toString();
    HikvisionSearchSession session;
    session.recorderInfo = recorderInfo;
    session.channelId = channelId;
    
    QDate firstDay(year, month, 1);
    QDate lastDay(year, month, firstDay.daysInMonth());
    
    session.startTime = QDateTime(firstDay, QTime(0, 0, 0), Qt::LocalTime);
    session.endTime = QDateTime(lastDay, QTime(23, 59, 59), Qt::LocalTime);
    session.isMonthSearch = true;
    session.year = year;
    session.month = month;
    session.currentPosition = 1;
    m_sessions[sessionId] = session;

    doSearchRequest(sessionId);
}

void HikvisionISAPI::doSearchRequest(const QString &sessionId)
{
    if (!m_sessions.contains(sessionId)) return;
    const HikvisionSearchSession &session = m_sessions[sessionId];

    QString ip = session.recorderInfo["ip"].toString();
    int port = session.recorderInfo.contains("httpPort") ? session.recorderInfo["httpPort"].toInt() : 80;
    if (port <= 0) port = 80; // fallback if invalid
    m_currentUser = session.recorderInfo["username"].toString();
    m_currentPassword = session.recorderInfo["password"].toString();

    QUrl url(QString("http://%1:%2/ISAPI/ContentMgmt/search").arg(ip).arg(port));
    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/xml");

    QString startTimeStr = session.startTime.toUTC().toString("yyyy-MM-ddThh:mm:ss") + "Z";
    QString endTimeStr = session.endTime.toUTC().toString("yyyy-MM-ddThh:mm:ss") + "Z";

    qDebug() << "[ISAPI] doSearchRequest session:" << sessionId
             << "channelId:" << session.channelId
             << "startTime (orig):" << session.startTime.toString(Qt::ISODate)
             << "startTime (local):" << session.startTime.toLocalTime().toString(Qt::ISODate)
             << "startTimeStr:" << startTimeStr
             << "endTimeStr:" << endTimeStr
             << "pos:" << session.currentPosition;

    QString xmlPayload = QString(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<CMSearchDescription xmlns=\"http://www.hikvision.com/ver20/XMLSchema\">\n"
        "  <searchID>%1</searchID>\n"
        "  <trackList>\n"
        "    <trackID>%2</trackID>\n"
        "  </trackList>\n"
        "  <timeSpanList>\n"
        "    <timeSpan>\n"
        "      <startTime>%3</startTime>\n"
        "      <endTime>%4</endTime>\n"
        "    </timeSpan>\n"
        "  </timeSpanList>\n"
        "  <maxResults>1000</maxResults>\n"
        "  <searchResultPostion>%5</searchResultPostion>\n"
        "  <metadataList>\n"
        "    <metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor>\n"
        "  </metadataList>\n"
        "</CMSearchDescription>\n"
    ).arg(sessionId).arg(session.channelId * 100 + 1).arg(startTimeStr).arg(endTimeStr).arg(session.currentPosition);

    QNetworkReply *reply = m_netManager->post(request, xmlPayload.toUtf8());
    reply->setProperty("sessionId", sessionId);
    reply->setProperty("username", m_currentUser);
    reply->setProperty("password", m_currentPassword);
    m_activeReplies[sessionId] = reply;
    connect(reply, &QNetworkReply::finished, this, &HikvisionISAPI::onReplyFinished);

    const bool standaloneCamera = session.channelId <= 1;
    if (standaloneCamera) {
        qWarning() << "[ISAPI] Standalone camera; using SDK recording search";
        startSdkSearch(sessionId);
        return;
    }
    QTimer::singleShot(8000, this, [this, sessionId]() {
        if (!m_sessions.contains(sessionId) || m_sessions[sessionId].sdkFallbackStarted)
            return;
        qWarning() << "[ISAPI] Search timed out; falling back to SDK recording search";
        if (m_activeReplies.contains(sessionId) && m_activeReplies[sessionId]) {
            m_activeReplies[sessionId]->abort();
        } else {
            startSdkSearch(sessionId);
        }
    });
}

void HikvisionISAPI::onAuthenticationRequired(QNetworkReply *reply, QAuthenticator *authenticator)
{
    if (reply) {
        QString user = reply->property("username").toString();
        QString pass = reply->property("password").toString();
        if (!user.isEmpty()) {
            authenticator->setUser(user);
            authenticator->setPassword(pass);
            return;
        }
    }
    authenticator->setUser(m_currentUser);
    authenticator->setPassword(m_currentPassword);
}

void HikvisionISAPI::onReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    QString sessionId = reply->property("sessionId").toString();
    m_activeReplies.remove(sessionId);
    reply->deleteLater();

    if (!m_sessions.contains(sessionId)) {
        return; // Session cancelled or already finished
    }
    
    HikvisionSearchSession &session = m_sessions[sessionId];
    QString recorderIp = session.recorderInfo["ip"].toString();

    if (reply->error() != QNetworkReply::NoError) {
        qWarning() << "[ISAPI] Search failed:" << reply->errorString();
        if (session.isMonthSearch) {
            QVariantList daysList;
            for (int d : session.accumulatedDays) daysList.append(d);
            emit monthAvailabilityFinished(recorderIp, session.channelId, session.year, session.month, daysList, false);
        } else {
            if (session.accumulatedSegments.count() > 0) {
                emit searchFinished(recorderIp, session.channelId, session.startTime, session.accumulatedSegments);
            } else {
                emit searchFailed(recorderIp, session.channelId, session.startTime, reply->errorString());
            }
        }
        if (!session.sdkFallbackStarted) {
            startSdkSearch(sessionId);
            return;
        }
        m_sessions.remove(sessionId);
        return;
    }

    QByteArray response = reply->readAll();
    QXmlStreamReader xml(response);

    bool inMatchList = false;
    bool inMatchItem = false;
    QString responseStatusStrg;
    
    QDateTime currentStart;
    QDateTime currentEnd;
    
    int matchItemsCount = 0;

    while (!xml.atEnd() && !xml.hasError()) {
        QXmlStreamReader::TokenType token = xml.readNext();

        if (token == QXmlStreamReader::StartElement) {
            QString name = xml.name().toString();
            if (name == "responseStatusStrg") {
                responseStatusStrg = xml.readElementText().trimmed();
            } else if (name == "matchList") {
                inMatchList = true;
            } else if (inMatchList && name == "searchMatchItem") {
                inMatchItem = true;
                matchItemsCount++;
            } else if (inMatchItem && name == "startTime") {
                QString val = xml.readElementText();
                currentStart = QDateTime::fromString(val, Qt::ISODate).toLocalTime();
            } else if (inMatchItem && name == "endTime") {
                QString val = xml.readElementText();
                currentEnd = QDateTime::fromString(val, Qt::ISODate).toLocalTime();
            }
        } else if (token == QXmlStreamReader::EndElement) {
            QString name = xml.name().toString();
            if (name == "matchList") {
                inMatchList = false;
            } else if (name == "searchMatchItem") {
                inMatchItem = false;
                if (currentStart.isValid() && currentEnd.isValid()) {
                    if (session.isMonthSearch) {
                        int day = currentStart.date().day();
                        if (!session.accumulatedDays.contains(day)) {
                            session.accumulatedDays.append(day);
                        }
                    } else {
                        QVariantMap segment;
                        segment["startTime"] = currentStart.toMSecsSinceEpoch();
                        segment["endTime"] = currentEnd.toMSecsSinceEpoch();
                        session.accumulatedSegments.append(segment);
                    }
                }
                currentStart = QDateTime();
                currentEnd = QDateTime();
            }
        }
    }

    if (xml.hasError()) {
        qWarning() << "[ISAPI] XML parsing error:" << xml.errorString();
        if (session.isMonthSearch) {
            QVariantList daysList;
            for (int d : session.accumulatedDays) daysList.append(d);
            emit monthAvailabilityFinished(recorderIp, session.channelId, session.year, session.month, daysList, false);
        } else {
            emit searchFailed(recorderIp, session.channelId, session.startTime, xml.errorString());
        }
        m_sessions.remove(sessionId);
        return;
    }

    if (matchItemsCount == 0) {
        // Done paginating
        if (session.isMonthSearch) {
            QVariantList daysList;
            for (int d : session.accumulatedDays) {
                daysList.append(d);
            }
            qDebug() << "[ISAPI] Month availability finished (no more matches) for channel:" << session.channelId << "days:" << daysList;
            emit monthAvailabilityFinished(recorderIp, session.channelId, session.year, session.month, daysList, true);
        } else {
            qDebug() << "[ISAPI] Day search finished (no more matches) for channel:" << session.channelId << "segments:" << session.accumulatedSegments.count();
            emit searchFinished(recorderIp, session.channelId, session.startTime, session.accumulatedSegments);
        }
        m_sessions.remove(sessionId);
        return;
    }

    // If responseStatusStrg is MORE, there are more pages (limit to 100000 results to avoid infinite loop)
    if (responseStatusStrg == "MORE" && session.currentPosition < 100000) {
        qDebug() << "[ISAPI] Session" << sessionId << "status MORE; paginating next page from:" << (session.currentPosition + matchItemsCount);
        session.currentPosition += matchItemsCount;
        doSearchRequest(sessionId); // Fetch next page
    } else {
        // Done paginating
        if (session.isMonthSearch) {
            QVariantList daysList;
            for (int d : session.accumulatedDays) {
                daysList.append(d);
            }
            qDebug() << "[ISAPI] Month availability finished for channel:" << session.channelId << "days:" << daysList;
            emit monthAvailabilityFinished(recorderIp, session.channelId, session.year, session.month, daysList, true);
        } else {
            qDebug() << "[ISAPI] Day search finished for channel:" << session.channelId << "segments:" << session.accumulatedSegments.count();
            emit searchFinished(recorderIp, session.channelId, session.startTime, session.accumulatedSegments);
        }
        m_sessions.remove(sessionId);
    }
}

void HikvisionISAPI::fillSdkTime(NET_DVR_TIME &out, const QDateTime &value)
{
    out.dwYear = value.date().year();
    out.dwMonth = value.date().month();
    out.dwDay = value.date().day();
    out.dwHour = value.time().hour();
    out.dwMinute = value.time().minute();
    out.dwSecond = value.time().second();
}

QDateTime HikvisionISAPI::fromSdkTime(const NET_DVR_TIME_SEARCH &value)
{
    return QDateTime(QDate(value.wYear, value.byMonth, value.byDay),
                     QTime(value.byHour, value.byMinute, value.bySecond));
}

void HikvisionISAPI::startSdkSearch(const QString &sessionId)
{
    if (!m_sessions.contains(sessionId))
        return;
    HikvisionSearchSession session = m_sessions.take(sessionId);
    if (session.sdkFallbackStarted)
        return;
    session.sdkFallbackStarted = true;

    QThread *worker = QThread::create([this, session]() {
        const QString ip = session.recorderInfo.value("ip").toString();
        const int port = session.recorderInfo.value("sdkPort").toInt() > 0
            ? session.recorderInfo.value("sdkPort").toInt()
            : session.recorderInfo.value("port").toInt();
        const QString username = session.recorderInfo.value("username").toString();
        const QString password = session.recorderInfo.value("password").toString();

        NET_DVR_DEVICEINFO_V40 deviceInfo;
        std::memset(&deviceInfo, 0, sizeof(deviceInfo));
        LONG userId = HikvisionManager::instance()->loginShared(ip, port > 0 ? port : 8000, username, password, deviceInfo);
        if (userId < 0) {
            QMetaObject::invokeMethod(this, [this, session]() {
                emit searchFailed(session.recorderInfo.value("ip").toString(), session.channelId, session.startTime, tr("SDK login failed"));
            }, Qt::QueuedConnection);
            return;
        }

        int channel = session.channelId;
        const auto &info = deviceInfo.struDeviceV30;
        if (info.byChanNum == 0 && info.byIPChanNum > 0)
            channel = session.channelId + info.byStartDChan - 1;
        else if (info.byChanNum > 0 && session.channelId > info.byChanNum)
            channel = info.byStartDChan + (session.channelId - info.byChanNum) - 1;
        else if (info.byChanNum > 0)
            channel = session.channelId + info.byStartChan - 1;

        NET_DVR_FILECOND_V40 cond;
        std::memset(&cond, 0, sizeof(cond));
        cond.lChannel = channel;
        cond.dwFileType = 0xFF;
        cond.dwIsLocked = 0xFF;
        fillSdkTime(cond.struStartTime, session.startTime);
        fillSdkTime(cond.struStopTime, session.endTime);

        QVariantList segments;
        QList<int> days;
        LONG findHandle = NET_DVR_FindFile_V40(userId, &cond);
        if (findHandle >= 0) {
            NET_DVR_FINDDATA_V50 data;
            while (true) {
                int state = NET_DVR_FindNextFile_V50(findHandle, &data);
                if (state == 1000) {
                    QDateTime start = fromSdkTime(data.struStartTime);
                    QDateTime end = fromSdkTime(data.struStopTime);
                    if (start.isValid() && end.isValid() && start < end) {
                        if (session.isMonthSearch) {
                            if (!days.contains(start.date().day()))
                                days.append(start.date().day());
                        } else {
                            QVariantMap segment;
                            segment["startTime"] = start.toMSecsSinceEpoch();
                            segment["endTime"] = end.toMSecsSinceEpoch();
                            segment["timeIsLocal"] = true;
                            segments.append(segment);
                        }
                    }
                } else if (state == 1002) {
                    QThread::msleep(10);
                } else {
                    break;
                }
            }
            NET_DVR_FindClose_V30(findHandle);
        }
        HikvisionManager::instance()->logoutShared(ip);

        QMetaObject::invokeMethod(this, [this, session, segments, days]() {
            const QString ip = session.recorderInfo.value("ip").toString();
            if (session.isMonthSearch) {
                QVariantList dayList;
                for (int day : days)
                    dayList.append(day);
                emit monthAvailabilityFinished(ip, session.channelId, session.year, session.month, dayList, true);
            } else {
                emit searchFinished(ip, session.channelId, session.startTime, segments);
            }
        }, Qt::QueuedConnection);
    });
    connect(worker, &QThread::finished, worker, &QThread::deleteLater);
    worker->start();
}

namespace {

QByteArray curlExchange(const QString &user, const QString &pass, const QString &url, const QByteArray &post, int timeoutSec, const QByteArray &contentType = QByteArray("application/json"))
{
    QProcess process;
    QStringList args;
    args << QStringLiteral("-sS") << QStringLiteral("-k") << QStringLiteral("--anyauth")
         << QStringLiteral("-u") << (user + QLatin1Char(':') + pass)
         << QStringLiteral("--max-time") << QString::number(timeoutSec);
    QTemporaryFile bodyFile;
    if (!post.isEmpty()) {
        if (!bodyFile.open())
            return QByteArray();
        bodyFile.write(post);
        bodyFile.close();
        args << QStringLiteral("-H") << (QByteArray("Content-Type: ") + contentType)
             << QStringLiteral("--data-binary") << (QLatin1Char('@') + bodyFile.fileName());
    }
    args << url;
    process.start(QStringLiteral("curl"), args);
    if (!process.waitForFinished((timeoutSec + 3) * 1000)) {
        process.kill();
        process.waitForFinished(1000);
        return QByteArray();
    }
    return process.readAllStandardOutput();
}

QString saveSmartCrop(const QByteArray &jpeg, double x, double y, double w, double h, const QString &dir, int index)
{
    QImage img;
    if (!img.loadFromData(jpeg) || img.isNull())
        return QString();
    if (w > 0.0 && h > 0.0) {
        double sx = x, sy = y, sw = w, sh = h;
        if (sx > 1.5 || sy > 1.5 || sw > 1.5 || sh > 1.5) {
            sx /= 10000.0;
            sy /= 10000.0;
            sw /= 10000.0;
            sh /= 10000.0;
        }
        const QRect crop(int(sx * img.width()), int(sy * img.height()),
                         qMax(1, int(sw * img.width())), qMax(1, int(sh * img.height())));
        const QRect fitted = crop.intersected(img.rect());
        if (fitted.width() >= 8 && fitted.height() >= 8)
            img = img.copy(fitted);
    }
    const QString path = dir + QStringLiteral("/smart-%1.jpg").arg(index);
    if (!img.save(path, "JPEG", 85))
        return QString();
    return path;
}

QString kindLabel(const QString &kind)
{
    if (kind == QLatin1String("human"))
        return QStringLiteral("Human");
    if (kind == QLatin1String("face"))
        return QStringLiteral("Face");
    if (kind == QLatin1String("other"))
        return QStringLiteral("Other");
    if (kind == QLatin1String("event"))
        return QStringLiteral("Event");
    return QStringLiteral("Vehicle");
}

} // namespace

void HikvisionISAPI::searchSmartTargets(const QVariantMap &recorderInfo, const QVariantList &channels,
                                        const QDateTime &start, const QDateTime &end,
                                        bool human, bool vehicle, bool face, bool other,
                                        bool line, bool intrusion, bool entrance, int token)
{
    QThread *worker = QThread::create([this, recorderInfo, channels, start, end, human, vehicle, face, other, line, intrusion, entrance, token]() {
        QVariantList hits;
        QString note;
        const QString ip = recorderInfo.value(QStringLiteral("ip")).toString();
        int httpPort = recorderInfo.value(QStringLiteral("httpPort")).toInt();
        if (httpPort <= 0)
            httpPort = 80;
        QString user = recorderInfo.value(QStringLiteral("username")).toString();
        QString pass = recorderInfo.value(QStringLiteral("password")).toString();
        const QString configFile = Context::config() ? Context::config()->fileName() : QString();
        // The playback list can hand the search a recorder with no username. The saved
        // login is the one playback itself uses.
        RecorderSecrets::fillLogin(configFile, ip, &user, &pass);
        // Each search writes its own folder. The previous folder stays until the
        // picture list has let go of it; deleting it here made the next search
        // unable to save, so the list came back empty.
        const QString dirPath = QDir::tempPath() + QStringLiteral("/kvision-smart-%1").arg(token);
        QDir().mkpath(dirPath);
        {
            const QString keep = QStringLiteral("kvision-smart-%1").arg(token);
            const QString previous = QStringLiteral("kvision-smart-%1").arg(qMax(0, token - 1));
            const QDir tempDir(QDir::tempPath());
            const QStringList old = tempDir.entryList({QStringLiteral("kvision-smart*")}, QDir::Dirs | QDir::NoDotAndDotDot);
            for (const QString &name : old) {
                if (name == keep || name == previous)
                    continue;
                QDir(tempDir.filePath(name)).removeRecursively();
            }
        }

        auto cameraNameFor = [&](int channel) {
            for (const QVariant &item : channels) {
                const QVariantMap cam = item.toMap();
                if (cam.value(QStringLiteral("channelId")).toInt() == channel) {
                    const QString name = cam.value(QStringLiteral("name")).toString();
                    if (!name.isEmpty())
                        return name;
                }
            }
            return QString();
        };

        auto addHit = [&](const QString &image, const QDateTime &when, const QString &kind, int channel, const QString &cameraName, const QString &detail = QString()) {
            if (!when.isValid() || (image.isEmpty() && kind != QLatin1String("event")))
                return;
            const QString shownName = !cameraName.isEmpty() ? cameraName : cameraNameFor(channel);
            QVariantMap hit;
            hit.insert(QStringLiteral("image"), image);
            hit.insert(QStringLiteral("timeMs"), when.toMSecsSinceEpoch());
            hit.insert(QStringLiteral("kind"), kind);
            hit.insert(QStringLiteral("channelId"), channel);
            hit.insert(QStringLiteral("cameraName"), shownName);
            hit.insert(QStringLiteral("detail"), detail);
            const QString who = shownName.isEmpty() ? kindLabel(kind) : (shownName + QStringLiteral("  ") + kindLabel(kind));
            const QString withDetail = detail.isEmpty() ? who : (who + QStringLiteral("  ") + detail);
            hit.insert(QStringLiteral("label"), withDetail + QLatin1Char(' ') + when.toLocalTime().toString(QStringLiteral("h:mm:ss AP")));
            hits.append(hit);
        };

        // A chosen camera is sent as choiceChannel. The whole recorder is one search, and a channel
        // is sent for each camera only when that recorder refuses an all-camera search.
        enum class Ask { None, Answered, Unsupported };
        bool sawSupport = false;
        bool sawUnsupported = false;
        auto searchVehicles = [&](int onlyChannel) -> Ask {
            const QString searchId = QUuid::createUuid().toString(QUuid::WithoutBraces);
            int position = 0;
            bool answered = false;
            while (hits.size() < 48) {
                QJsonObject body{
                    {QStringLiteral("searchID"), searchId},
                    {QStringLiteral("searchResultPosition"), position},
                    {QStringLiteral("maxResults"), 24},
                    {QStringLiteral("startTime"), start.toOffsetFromUtc(start.offsetFromUtc()).toString(Qt::ISODate)},
                    {QStringLiteral("endTime"), end.toOffsetFromUtc(end.offsetFromUtc()).toString(Qt::ISODate)},
                    {QStringLiteral("targetType"), QStringLiteral("vehicle")}
                };
                if (onlyChannel > 0) {
                    body.insert(QStringLiteral("choiceChannel"),
                                QJsonArray{QJsonObject{{QStringLiteral("channelID"), QString::number(onlyChannel)}}});
                }
                const QByteArray raw = curlExchange(user, pass,
                    QStringLiteral("http://%1:%2/ISAPI/SDT/Management/IntelligentSearch?format=json").arg(ip).arg(httpPort),
                    QJsonDocument(body).toJson(QJsonDocument::Compact), 25);
                const QJsonObject doc = QJsonDocument::fromJson(raw).object();
                if (doc.isEmpty() || !doc.contains(QStringLiteral("responseStatusStrg"))) {
                    const QString body = QString::fromUtf8(raw);
                    if (body.contains(QLatin1String("notSupport"), Qt::CaseInsensitive)
                            || body.contains(QLatin1String("Not Found"))
                            || body.contains(QLatin1String("Invalid Operation")))
                        return Ask::Unsupported;
                    break;
                }
                answered = true;
                const QString status = doc.value(QStringLiteral("responseStatusStrg")).toString();
                const QJsonArray infos = doc.value(QStringLiteral("targetInfo")).toArray();
                for (const QJsonValue &value : infos) {
                    if (hits.size() >= 48)
                        break;
                    const QJsonObject info = value.toObject();
                    const QString picUrl = info.value(QStringLiteral("picUrl")).toString();
                    if (picUrl.isEmpty())
                        continue;
                    const QByteArray jpeg = curlExchange(user, pass, picUrl, QByteArray(), 15);
                    const QJsonObject rect = info.value(QStringLiteral("targetRect")).toObject();
                    const QString path = saveSmartCrop(jpeg,
                        rect.value(QStringLiteral("x")).toDouble(),
                        rect.value(QStringLiteral("y")).toDouble(),
                        rect.value(QStringLiteral("width")).toDouble(),
                        rect.value(QStringLiteral("height")).toDouble(),
                        dirPath, hits.size());
                    const QDateTime when = QDateTime::fromString(info.value(QStringLiteral("captureTime")).toString(), Qt::ISODate);
                    const int channel = info.value(QStringLiteral("channelID")).toString().toInt();
                    if (onlyChannel > 0 && channel > 0 && channel != onlyChannel)
                        continue;
                    addHit(path, when, QStringLiteral("vehicle"), channel > 0 ? channel : onlyChannel,
                           info.value(QStringLiteral("channelName")).toString());
                }
                const int got = doc.value(QStringLiteral("numOfMatches")).toInt();
                position += qMax(1, got);
                if (status != QLatin1String("MORE") || infos.isEmpty())
                    break;
            }
            return answered ? Ask::Answered : Ask::None;
        };

        auto take = [&](Ask answer) {
            if (answer == Ask::Answered)
                sawSupport = true;
            else if (answer == Ask::Unsupported)
                sawUnsupported = true;
            return answer == Ask::Answered;
        };

        auto addLogged = [&](const QString &word, const QString &kind, int cap, int indexBase) -> int {
            const QString configFile = Context::config() ? Context::config()->fileName() : QSettings().fileName();
            const QString configDir = QFileInfo(configFile).absolutePath();
            QFile log(configDir + QStringLiteral("/logs/Detection.log"));
            if (!log.open(QIODevice::ReadOnly))
                return 0;
            struct LoggedPic { QString path; QDateTime when; int channel; QString name; QString detail; double x, y, w, h; };
            QVector<LoggedPic> logged;
            const QRegularExpression boxRx(QStringLiteral("box ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)"));
            const QString needle = word + QStringLiteral(" detected");
            const QList<QByteArray> lines = log.readAll().split('\n');
            for (const QByteArray &rawLine : lines) {
                const QString text = QString::fromUtf8(rawLine).trimmed();
                if (!text.contains(needle))
                    continue;
                QStringList parts = text.split(QStringLiteral(", "));
                if (!parts.isEmpty() && parts.last().startsWith(QStringLiteral("via ")))
                    parts.removeLast();
                while (!parts.isEmpty() && (parts.last().startsWith(QStringLiteral("box "))
                                            || parts.last().startsWith(QStringLiteral("zone "))
                                            || parts.last().startsWith(QStringLiteral("poly "))
                                            || parts.last().startsWith(QStringLiteral("received "))))
                    parts.removeLast();
                if (parts.size() < 6 || !parts.at(1).startsWith(word))
                    continue;
                const QString recorderClause = parts.last();
                bool mine = false;
                int logical = 0;
                for (const QVariant &item : channels) {
                    const int channel = item.toMap().value(QStringLiteral("channelId")).toInt();
                    if (channel <= 0)
                        continue;
                    if (recorderClause == QStringLiteral("recorder %1 ch %2").arg(ip).arg(channel)) {
                        mine = true;
                        logical = channel;
                        break;
                    }
                }
                if (!mine)
                    continue;
                QDateTime when = QLocale::c().toDateTime(parts.at(0), QStringLiteral("dd MMM yyyy HH:mm:ss"));
                when.setTimeSpec(Qt::LocalTime);
                if (!when.isValid() || when.toMSecsSinceEpoch() < start.toMSecsSinceEpoch()
                        || when.toMSecsSinceEpoch() > end.toMSecsSinceEpoch())
                    continue;
                const QString detail = parts.at(2);
                // A ticked event keeps only that event. No event ticked keeps every event for the chosen targets.
                const bool narrowEvents = line || intrusion || entrance;
                if (narrowEvents) {
                    const bool keep = (line && detail == QLatin1String("Line crossing"))
                            || (intrusion && detail == QLatin1String("Intrusion"))
                            || (entrance && detail == QLatin1String("Region entrance"));
                    if (!keep)
                        continue;
                }
                const QString address = parts.at(parts.size() - 2);
                QString key = address;
                key.replace(QRegularExpression(QStringLiteral("[^0-9A-Za-z.-]")), QStringLiteral("_"));
                QString slug;
                for (const QChar ch : parts.at(2).toLower()) {
                    if (ch.isLetterOrNumber() && ch.unicode() < 128)
                        slug += ch;
                }
                const QString secs = QString::number(when.toSecsSinceEpoch());
                const QString dirPics = configDir + QStringLiteral("/logs/pictures/");
                const QStringList tries = {
                    dirPics + key + QLatin1Char('_') + secs + QLatin1Char('-') + slug + QStringLiteral(".jpg"),
                    dirPics + key + QStringLiteral("_ch") + QString::number(logical) + QLatin1Char('_') + secs + QLatin1Char('-') + slug + QStringLiteral(".jpg")
                };
                QString path;
                for (const QString &tryPath : tries) {
                    if (QFile::exists(tryPath)) {
                        path = tryPath;
                        break;
                    }
                }
                if (path.isEmpty())
                    continue;
                const QRegularExpressionMatch box = boxRx.match(text);
                LoggedPic row;
                row.path = path;
                row.when = when;
                row.channel = logical;
                row.name = parts.at(3);
                row.detail = detail;
                row.x = box.hasMatch() ? box.captured(1).toDouble() : 0;
                row.y = box.hasMatch() ? box.captured(2).toDouble() : 0;
                row.w = box.hasMatch() ? box.captured(3).toDouble() : 0;
                row.h = box.hasMatch() ? box.captured(4).toDouble() : 0;
                logged.append(row);
            }
            std::sort(logged.begin(), logged.end(), [](const LoggedPic &a, const LoggedPic &b) {
                return a.when > b.when;
            });
            int added = 0;
            for (const LoggedPic &row : logged) {
                if (added >= cap)
                    break;
                QFile pic(row.path);
                if (!pic.open(QIODevice::ReadOnly))
                    continue;
                const QString saved = saveSmartCrop(pic.readAll(), row.x, row.y, row.w, row.h, dirPath, indexBase + added);
                addHit(saved.isEmpty() ? row.path : saved, row.when, kind, row.channel, row.name, row.detail);
                ++added;
            }
            return added;
        };

        const bool narrowEvents = line || intrusion || entrance;
        const bool eventsOnly = narrowEvents && !human && !vehicle && !face && !other;
        const int vehiclesFromLog = ((vehicle || eventsOnly) && !ip.isEmpty())
                ? addLogged(QStringLiteral("Vehicle"), QStringLiteral("vehicle"), 400, 4000) : 0;
        if ((human || eventsOnly) && !ip.isEmpty())
            addLogged(QStringLiteral("Human"), QStringLiteral("human"), 200, 3000);
        if ((other || eventsOnly) && !ip.isEmpty())
            addLogged(QStringLiteral("Other"), QStringLiteral("other"), 400, 5000);

        // The recorder's own vehicle search is a short sample. When Detection events already
        // has the vehicle pictures, those are the full set and the sample is left out.
        // A chosen event (line crossing, intrusion, or region entrance) uses the tagged pictures only.
        if (vehicle && vehiclesFromLog == 0 && !narrowEvents && !ip.isEmpty()) {
            QList<int> wanted;
            for (const QVariant &item : channels) {
                const int channel = item.toMap().value(QStringLiteral("channelId")).toInt();
                if (channel > 0)
                    wanted.append(channel);
            }
            if (wanted.size() == 1) {
                take(searchVehicles(wanted.first()));
            } else if (!take(searchVehicles(-1))) {
                for (int channel : wanted) {
                    if (hits.size() >= 48)
                        break;
                    if (take(searchVehicles(channel)))
                        sawSupport = true;
                }
            }
            if (!sawSupport && !sawUnsupported)
                note = QStringLiteral("The recorder did not answer the vehicle search.");
        }

        // Face pictures on this recorder are the face-comparison captures. The SDK picture
        // search signs in again and, when that sign-in fails, reports it without looking.
        if (face && !narrowEvents && !ip.isEmpty()) {
            const QString windowStart = start.toOffsetFromUtc(start.offsetFromUtc()).toString(Qt::ISODate);
            const QString windowEnd = end.toOffsetFromUtc(end.offsetFromUtc()).toString(Qt::ISODate);
            QList<int> faceChannels;
            for (const QVariant &item : channels) {
                const int channel = item.toMap().value(QStringLiteral("channelId")).toInt();
                if (channel > 0)
                    faceChannels.append(channel);
            }
            int faceKept = 0;
            bool faceAnswered = false;
            QByteArray faceReply;
            auto searchFaces = [&](int onlyChannel) {
                if (faceKept >= 40 || hits.size() >= 48)
                    return;
                const QString searchId = QUuid::createUuid().toString(QUuid::WithoutBraces);
                int position = 0;
                for (int page = 0; page < 6 && faceKept < 40 && hits.size() < 48; ++page) {
                    QString xml = QStringLiteral(
                        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                        "<FCSearchDescription version=\"2.0\" xmlns=\"http://www.isapi.org/ver20/XMLSchema\">"
                        "<searchID>%1</searchID>"
                        "<searchResultPosition>%2</searchResultPosition>"
                        "<maxResults>20</maxResults>"
                        "<snapStartTime>%3</snapStartTime>"
                        "<snapEndTime>%4</snapEndTime>"
                        "<eventType>unlimit</eventType>")
                        .arg(searchId)
                        .arg(position)
                        .arg(windowStart)
                        .arg(windowEnd);
                    if (onlyChannel > 0)
                        xml += QStringLiteral("<channelID>%1</channelID>").arg(onlyChannel);
                    xml += QStringLiteral("</FCSearchDescription>");
                    const QByteArray raw = curlExchange(user, pass,
                        QStringLiteral("http://%1:%2/ISAPI/Intelligent/FDLib/FCSearch").arg(ip).arg(httpPort),
                        xml.toUtf8(), 25, QByteArray("application/xml"));
                    if (!raw.contains("FCSearchResult")) {
                        faceReply = raw;
                        return;
                    }
                    faceAnswered = true;
                    QString status;
                    int matched = 0;
                    int added = 0;
                    QXmlStreamReader reader(raw);
                    while (!reader.atEnd()) {
                        reader.readNext();
                        if (!reader.isStartElement())
                            continue;
                        if (reader.name() == QLatin1String("responseStatusStrg")) {
                            status = reader.readElementText();
                        } else if (reader.name() == QLatin1String("numOfMatches")) {
                            matched = reader.readElementText().toInt();
                        } else if (reader.name() == QLatin1String("MatchElement")) {
                            QString faceUrl;
                            QString sceneUrl;
                            QString whenText;
                            int channel = onlyChannel;
                            double rx = 0, ry = 0, rw = 0, rh = 0;
                            while (!reader.atEnd() && !(reader.isEndElement() && reader.name() == QLatin1String("MatchElement"))) {
                                reader.readNext();
                                if (!reader.isStartElement())
                                    continue;
                                const QStringRef tag = reader.name();
                                if (tag == QLatin1String("facePicURL"))
                                    faceUrl = reader.readElementText();
                                else if (tag == QLatin1String("snapPicURL"))
                                    sceneUrl = reader.readElementText();
                                else if (tag == QLatin1String("snapTime"))
                                    whenText = reader.readElementText();
                                else if (tag == QLatin1String("channelID"))
                                    channel = reader.readElementText().toInt();
                                else if (tag == QLatin1String("x"))
                                    rx = reader.readElementText().toDouble();
                                else if (tag == QLatin1String("y"))
                                    ry = reader.readElementText().toDouble();
                                else if (tag == QLatin1String("width"))
                                    rw = reader.readElementText().toDouble();
                                else if (tag == QLatin1String("height"))
                                    rh = reader.readElementText().toDouble();
                            }
                            if (faceKept >= 40 || hits.size() >= 48)
                                break;
                            if (channel > 0 && !faceChannels.isEmpty() && !faceChannels.contains(channel))
                                continue;
                            const QDateTime when = QDateTime::fromString(whenText, Qt::ISODate);
                            QByteArray jpeg;
                            if (!faceUrl.isEmpty())
                                jpeg = curlExchange(user, pass, faceUrl, QByteArray(), 15);
                            QString path;
                            if (jpeg.startsWith("\xff\xd8\xff"))
                                path = saveSmartCrop(jpeg, 0, 0, 0, 0, dirPath, 1000 + faceKept);
                            if (path.isEmpty() && !sceneUrl.isEmpty()) {
                                jpeg = curlExchange(user, pass, sceneUrl, QByteArray(), 15);
                                if (jpeg.startsWith("\xff\xd8\xff"))
                                    path = saveSmartCrop(jpeg, rx, ry, rw, rh, dirPath, 1000 + faceKept);
                            }
                            addHit(path, when, QStringLiteral("face"), channel > 0 ? channel : onlyChannel, QString());
                            ++faceKept;
                            ++added;
                        }
                    }
                    position += qMax(1, matched > 0 ? matched : added);
                    if (status != QLatin1String("MORE") || added == 0)
                        return;
                }
            };
            auto runFaceSearch = [&]() {
                faceAnswered = false;
                if (faceChannels.size() == 1)
                    searchFaces(faceChannels.first());
                else
                    searchFaces(0);
                if (!faceAnswered && faceChannels.size() != 1) {
                    for (int channel : faceChannels) {
                        if (faceKept >= 40 || hits.size() >= 48)
                            break;
                        searchFaces(channel);
                    }
                }
            };
            runFaceSearch();
            if (!faceAnswered) {
                const QString saved = RecorderSecrets::passwordFor(configFile, ip, user);
                if (!saved.isEmpty() && saved != pass) {
                    pass = saved;
                    faceKept = 0;
                    runFaceSearch();
                }
            }
            if (faceAnswered)
                sawSupport = true;
            else if (note.isEmpty()) {
                const QString text = QString::fromUtf8(faceReply);
                const int statusAt = text.indexOf(QStringLiteral("<statusString>"));
                QString status;
                if (statusAt >= 0) {
                    const int end = text.indexOf(QStringLiteral("</statusString>"), statusAt);
                    if (end > statusAt)
                        status = text.mid(statusAt + 14, end - (statusAt + 14));
                }
                if (status.isEmpty() && text.contains(QStringLiteral("Unauthorized"), Qt::CaseInsensitive))
                    status = QStringLiteral("login refused");
                note = status.isEmpty()
                    ? QStringLiteral("The recorder did not answer the face search.")
                    : QStringLiteral("The recorder refused the face search (%1).").arg(status);
                qWarning() << "[SmartSearch] face search failed for" << ip << "port" << httpPort
                           << "userLen" << user.size() << "passLen" << pass.size()
                           << "bytes" << faceReply.size() << faceReply.left(160);
            }
        }

        if (human && !narrowEvents && !ip.isEmpty()) {
            const int port = recorderInfo.value(QStringLiteral("sdkPort")).toInt() > 0
                ? recorderInfo.value(QStringLiteral("sdkPort")).toInt()
                : recorderInfo.value(QStringLiteral("port")).toInt();
            NET_DVR_DEVICEINFO_V40 sharedInfo;
            std::memset(&sharedInfo, 0, sizeof(sharedInfo));
            // The shared sign-in is only so the SDK is up. Picture search on that
            // same sign-in works once; the next search is refused until playback
            // logs out. A separate sign-in is closed before this search returns.
            const LONG sharedId = HikvisionManager::instance()->loginShared(ip, port > 0 ? port : 8000, user, pass, sharedInfo);
            LONG userId = sharedId;
            bool privateLogin = false;
            NET_DVR_DEVICEINFO_V40 deviceInfo = sharedInfo;
            if (sharedId >= 0) {
                const QByteArray host = ip.toUtf8();
                const QByteArray userBytes = user.toUtf8();
                const QByteArray passBytes = pass.toUtf8();
                HikvisionManager::instance()->withSdkLock([&]() {
                    NET_DVR_USER_LOGIN_INFO loginInfo;
                    std::memset(&loginInfo, 0, sizeof(loginInfo));
                    std::strncpy(loginInfo.sDeviceAddress, host.constData(), sizeof(loginInfo.sDeviceAddress) - 1);
                    loginInfo.wPort = static_cast<WORD>(port > 0 ? port : 8000);
                    std::strncpy(loginInfo.sUserName, userBytes.constData(), sizeof(loginInfo.sUserName) - 1);
                    std::strncpy(loginInfo.sPassword, passBytes.constData(), sizeof(loginInfo.sPassword) - 1);
                    loginInfo.bUseAsynLogin = FALSE;
                    NET_DVR_DEVICEINFO_V40 privInfo;
                    std::memset(&privInfo, 0, sizeof(privInfo));
                    const LONG priv = NET_DVR_Login_V40(&loginInfo, &privInfo);
                    if (priv >= 0) {
                        userId = priv;
                        deviceInfo = privInfo;
                        privateLogin = true;
                    }
                });
            }
            if (userId < 0) {
                // Log pictures are already in the list. A recorder sign-in failure is a second
                // search, so it only becomes the note when this search found nothing else.
                if (note.isEmpty() && hits.isEmpty())
                    note = QStringLiteral("Could not sign in to the recorder for human pictures.");
            } else {
                const auto &info = deviceInfo.struDeviceV30;
                const QDateTime startLocal = start.toLocalTime();
                const QDateTime endLocal = end.toLocalTime();
                auto sdkChannel = [&](int logical) {
                    if (info.byChanNum == 0 && info.byIPChanNum > 0)
                        return logical + info.byStartDChan - 1;
                    if (info.byChanNum > 0 && logical > info.byChanNum)
                        return info.byStartDChan + (logical - info.byChanNum) - 1;
                    if (info.byChanNum > 0)
                        return logical + info.byStartChan - 1;
                    return logical;
                };
                // Human pictures are the human-recognition captures (file type 0x2f). The behaviour
                // search on this recorder is vehicle pictures, so it is not used for Human.
                int humanKept = 0;
                if (human && !narrowEvents) {
                    for (const QVariant &item : channels) {
                        if (humanKept >= 100)
                            break;
                        const int logical = item.toMap().value(QStringLiteral("channelId")).toInt();
                        if (logical <= 0)
                            continue;
                        NET_DVR_FIND_PICTURE_PARAM para;
                        std::memset(&para, 0, sizeof(para));
                        para.dwSize = sizeof(para);
                        para.lChannel = sdkChannel(logical);
                        para.byFileType = 0x2f;
                        para.struStartTime.dwYear = static_cast<DWORD>(startLocal.date().year());
                        para.struStartTime.dwMonth = static_cast<DWORD>(startLocal.date().month());
                        para.struStartTime.dwDay = static_cast<DWORD>(startLocal.date().day());
                        para.struStartTime.dwHour = static_cast<DWORD>(startLocal.time().hour());
                        para.struStartTime.dwMinute = static_cast<DWORD>(startLocal.time().minute());
                        para.struStartTime.dwSecond = static_cast<DWORD>(startLocal.time().second());
                        para.struStopTime.dwYear = static_cast<DWORD>(endLocal.date().year());
                        para.struStopTime.dwMonth = static_cast<DWORD>(endLocal.date().month());
                        para.struStopTime.dwDay = static_cast<DWORD>(endLocal.date().day());
                        para.struStopTime.dwHour = static_cast<DWORD>(endLocal.time().hour());
                        para.struStopTime.dwMinute = static_cast<DWORD>(endLocal.time().minute());
                        para.struStopTime.dwSecond = static_cast<DWORD>(endLocal.time().second());
                        const LONG find = NET_DVR_FindPicture(userId, &para);
                        if (find < 0) {
                            if (NET_DVR_GetLastError() == NET_DVR_NOSUPPORT)
                                sawUnsupported = true;
                            continue;
                        }
                        sawSupport = true;
                        int guard = 0;
                        while (guard++ < 200 && humanKept < 100) {
                            NET_DVR_FIND_PICTURE_V40 ret;
                            std::memset(&ret, 0, sizeof(ret));
                            const LONG state = NET_DVR_FindNextPicture_V40(find, &ret);
                            if (state == NET_DVR_ISFINDING)
                                continue;
                            if (state != NET_DVR_FILE_SUCCESS)
                                break;
                            if (ret.byFileType != 0 && ret.byFileType != 0x2f)
                                continue;
                            if (ret.dwFileSize == 0 || ret.dwFileSize > 8 * 1024 * 1024)
                                continue;
                            QByteArray jpeg(int(ret.dwFileSize) + 64, 0);
                            DWORD got = 0;
                            if (!NET_DVR_GetPicture_V30(userId, ret.sFileName, jpeg.data(), DWORD(jpeg.size()), &got) || got < 32)
                                continue;
                            jpeg.truncate(int(got));
                            const QString path = saveSmartCrop(jpeg, 0, 0, 0, 0, dirPath, 6000 + humanKept);
                            const QDateTime when(QDate(int(ret.struTime.dwYear), int(ret.struTime.dwMonth), int(ret.struTime.dwDay)),
                                                 QTime(int(ret.struTime.dwHour), int(ret.struTime.dwMinute), int(ret.struTime.dwSecond)),
                                                 Qt::LocalTime);
                            addHit(path, when, QStringLiteral("human"), logical, QString());
                            ++humanKept;
                        }
                        NET_DVR_CloseFindPicture(find);
                    }
                }
            }
            if (privateLogin) {
                const LONG priv = userId;
                HikvisionManager::instance()->withSdkLock([priv]() {
                    NET_DVR_Logout(priv);
                });
            }
            if (sharedId >= 0)
                HikvisionManager::instance()->logoutShared(ip);
        }

        // The event-recording list is for a camera on its own card. A camera on a recorder keeps
        // the recorder's own picture search, so one channel of that recorder does not get this note.
        const int recorderCameras = recorderInfo.value(QStringLiteral("cameras")).toList().size();
        const bool ownCamera = recorderCameras > 0 && recorderCameras <= 2;
        if (hits.isEmpty() && !sawSupport && sawUnsupported && ownCamera) {
            const QString windowStart = start.toOffsetFromUtc(start.offsetFromUtc()).toString(Qt::ISODate);
            const QString windowEnd = end.toOffsetFromUtc(end.offsetFromUtc()).toString(Qt::ISODate);
            for (const QVariant &item : channels) {
                if (hits.size() >= 80)
                    break;
                const QVariantMap cam = item.toMap();
                const int logical = cam.value(QStringLiteral("channelId")).toInt();
                if (logical <= 0)
                    continue;
                const QString searchId = QUuid::createUuid().toString(QUuid::WithoutBraces);
                int position = 0;
                for (int page = 0; page < 8 && hits.size() < 80; ++page) {
                    const QByteArray xml = QString(
                        "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                        "<CMSearchDescription xmlns=\"http://www.hikvision.com/ver20/XMLSchema\">"
                        "<searchID>%1</searchID>"
                        "<trackList><trackID>%2</trackID></trackList>"
                        "<timeSpanList><timeSpan><startTime>%3</startTime><endTime>%4</endTime></timeSpan></timeSpanList>"
                        "<maxResults>40</maxResults>"
                        "<searchResultPostion>%5</searchResultPostion>"
                        "<metadataList><metadataDescriptor>//recordType.meta.hikvision.com/AllEvent</metadataDescriptor></metadataList>"
                        "</CMSearchDescription>")
                        .arg(searchId)
                        .arg(logical * 100 + 1)
                        .arg(windowStart, windowEnd)
                        .arg(position)
                        .toUtf8();
                    const QByteArray raw = curlExchange(user, pass,
                        QStringLiteral("http://%1:%2/ISAPI/ContentMgmt/search").arg(ip).arg(httpPort),
                        xml, 25, QByteArray("application/xml"));
                    QXmlStreamReader reader(raw);
                    QString status;
                    int matched = 0;
                    int added = 0;
                    while (!reader.atEnd()) {
                        reader.readNext();
                        if (!reader.isStartElement())
                            continue;
                        if (reader.name() == QLatin1String("responseStatusStrg")) {
                            status = reader.readElementText();
                        } else if (reader.name() == QLatin1String("numOfMatches")) {
                            matched = reader.readElementText().toInt();
                        } else if (reader.name() == QLatin1String("searchMatchItem")) {
                            QString startText;
                            while (!reader.atEnd() && !(reader.isEndElement() && reader.name() == QLatin1String("searchMatchItem"))) {
                                reader.readNext();
                                if (reader.isStartElement() && reader.name() == QLatin1String("startTime") && startText.isEmpty())
                                    startText = reader.readElementText();
                            }
                            const QDateTime when = QDateTime::fromString(startText, Qt::ISODate);
                            if (!when.isValid() || hits.size() >= 80)
                                continue;
                            addHit(QString(), when, QStringLiteral("event"), logical, cam.value(QStringLiteral("name")).toString());
                            ++added;
                        }
                    }
                    if (added == 0)
                        break;
                    position += qMax(1, matched > 0 ? matched : added);
                    if (status != QLatin1String("MORE"))
                        break;
                }
            }
            std::sort(hits.begin(), hits.end(), [](const QVariant &a, const QVariant &b) {
                return a.toMap().value(QStringLiteral("timeMs")).toLongLong()
                     > b.toMap().value(QStringLiteral("timeMs")).toLongLong();
            });
            if (hits.isEmpty())
                note = QStringLiteral("Smart-search pictures are not stored on this camera, and it has no event recordings for this day. KVision's Detection events may have the properly tagged event for the video timestamp.");
            else
                note = QStringLiteral("Smart-search pictures are not stored on this camera. %1 event recordings. Click one to play from that time. KVision's Detection events may have the properly tagged event for the video timestamp.").arg(hits.size());
        } else if (note.isEmpty()) {
            int humans = 0;
            for (const QVariant &hit : hits) {
                if (hit.toMap().value(QStringLiteral("kind")).toString() == QLatin1String("human"))
                    ++humans;
            }
            if (human && humans == 0)
                note = hits.isEmpty()
                    ? QStringLiteral("No human pictures for this day.")
                    : QStringLiteral("No human pictures for this day. %1 other pictures are listed.").arg(hits.size());
            else if (hits.isEmpty())
                note = QStringLiteral("No pictures for this day.");
            else
                note = QStringLiteral("%1 pictures. Click one to play from that time.").arg(hits.size());
        }

        QMetaObject::invokeMethod(this, [this, token, hits, note]() {
            emit smartSearchFinished(token, hits, note);
        }, Qt::QueuedConnection);
    });
    connect(worker, &QThread::finished, worker, &QThread::deleteLater);
    worker->start();
}

void HikvisionISAPI::cancelAllSearches()
{
    qDebug() << "[ISAPI] cancelAllSearches called. Cancelling" << m_sessions.size() << "active search sessions.";
    m_sessions.clear();
    
    // Copy the replies to a local list first to avoid iterator invalidation when they are aborted/deleted
    QList<QNetworkReply*> repliesToAbort = m_activeReplies.values();
    m_activeReplies.clear();

    for (auto* reply : repliesToAbort) {
        if (reply) {
            // Disconnect all signals to prevent onReplyFinished or authentication requests
            // from being triggered synchronously during reply->abort()
            reply->disconnect(this);
            reply->abort();
            reply->deleteLater();
        }
    }
}

