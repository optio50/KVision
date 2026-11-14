#include "hikvisionbackup.h"

#include "hikvisionmanager.h"
#include "offlinerecorders.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QMap>
#include <QMetaObject>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QSettings>
#include <QThread>

namespace {
// The key every export uses. Never change it: a backup can only be read back with the key that made it.
const char *kBackupKey = "KVisionBackup1";
const char *kLoginGroup = "CameraLogins";

QString hostOf(const QString &address)
{
    return address.section(QLatin1Char(':'), 0, 0).trimmed();
}

QString safeName(const QString &s)
{
    QString r = s;
    r.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]+")), QStringLiteral("_"));
    return r.left(60);
}

// GET a URL with curl (the same way the rest of the program talks to cameras). The body goes to outFile when
// given, otherwise it is returned in *body. Returns the HTTP status (0 when curl could not connect at all).
int curlGet(const QString &url, const QString &user, const QString &pass, int maxSeconds, const QString &outFile,
            QByteArray *body)
{
    QStringList args;
    args << QStringLiteral("-s") << QStringLiteral("-k") << QStringLiteral("--anyauth") << QStringLiteral("-u")
         << QStringLiteral("%1:%2").arg(user, pass) << QStringLiteral("--max-time") << QString::number(maxSeconds)
         << QStringLiteral("-w") << QStringLiteral("%{http_code}");
    if (!outFile.isEmpty())
        args << QStringLiteral("-o") << outFile;
    args << url;
    QProcess p;
    p.start(QStringLiteral("curl"), args);
    if (!p.waitForFinished((maxSeconds + 5) * 1000)) {
        p.kill();
        return 0;
    }
    const QByteArray out = p.readAllStandardOutput();
    if (outFile.isEmpty()) {
        // The status code is the last three characters; everything before it is the body.
        if (body)
            *body = out.left(qMax(0, int(out.size()) - 3));
        return out.right(3).toInt();
    }
    return out.trimmed().toInt();
}

// PUT a small JSON text to a camera with curl. Returns the HTTP status (0 when it could not connect).
int curlPutJson(const QString &url, const QString &user, const QString &pass, int maxSeconds, const QByteArray &json,
                QByteArray *body)
{
    QStringList args;
    args << QStringLiteral("-s") << QStringLiteral("-k") << QStringLiteral("--anyauth") << QStringLiteral("-u")
         << QStringLiteral("%1:%2").arg(user, pass) << QStringLiteral("--max-time") << QString::number(maxSeconds)
         << QStringLiteral("-X") << QStringLiteral("PUT") << QStringLiteral("-d") << QString::fromUtf8(json)
         << QStringLiteral("-H") << QStringLiteral("Content-Type: application/json")
         << QStringLiteral("-w") << QStringLiteral("%{http_code}") << url;
    QProcess p;
    p.start(QStringLiteral("curl"), args);
    if (!p.waitForFinished((maxSeconds + 5) * 1000)) {
        p.kill();
        return 0;
    }
    const QByteArray out = p.readAllStandardOutput();
    if (body)
        *body = out.left(qMax(0, int(out.size()) - 3));
    return out.right(3).toInt();
}

struct RuleLinesAnswer {
    QString state;   // "on", "off", "unavailable" or "error"
    QString message;
    bool refused = false; // the camera refused the login
};

// The camera's own switch for drawing the VCA rule lines and targets on the video stream (the web page's
// VCA > Smart Event > General Settings > Metadata > "Enable Stream Rule" and "Sub-Stream", which work as a pair).
// Read: GET /ISAPI/Streaming/channels/1/smartOverlap?format=json
//   {"SmartOverlap": {"enabled": bool, "streamType": 0 or 2, "bkgImageOverlapEnabled": bool}}
// On is enabled=true with streamType=2; off is enabled=false with streamType=0. bkgImageOverlapEnabled is a different
// switch (the rule frame on the picture a camera saves) and is always written back exactly as it was read.
// mode: 0 only read, 1 turn on, 2 turn off. A refused login is never retried.
RuleLinesAnswer ruleLinesOne(const HikvisionBackup::Cam &cam, int mode)
{
    RuleLinesAnswer a;
    a.state = QStringLiteral("error");
    if (cam.user.isEmpty() || cam.pass.isEmpty()) {
        a.message = QStringLiteral("no login saved for this camera (a blank password is never sent)");
        return a;
    }
    const QString url = QStringLiteral("http://%1:%2/ISAPI/Streaming/channels/1/smartOverlap?format=json").arg(cam.ip).arg(cam.httpPort);
    auto explain = [&](int code) -> bool {
        if (code == 0)
            a.message = QStringLiteral("could not connect");
        else if (code == 401) {
            a.refused = true;
            a.message = QStringLiteral("the camera refused the login (not tried again, so it cannot lock the camera)");
        }
        else if (code == 404 || code == 403 || code == 501) {
            a.state = QStringLiteral("unavailable");
            a.message = QStringLiteral("this camera has no switch for rule lines on the stream");
        } else
            a.message = QStringLiteral("the camera answered HTTP %1").arg(code);
        return code != 200;
    };
    auto readState = [&](QJsonObject *so, QString *why) -> bool {
        QByteArray body;
        const int code = curlGet(url, cam.user, cam.pass, 8, QString(), &body);
        if (explain(code)) {
            *why = a.message;
            return false;
        }
        const QJsonObject o = QJsonDocument::fromJson(body).object().value(QStringLiteral("SmartOverlap")).toObject();
        if (!o.contains(QStringLiteral("enabled"))) {
            a.state = QStringLiteral("error");
            *why = QStringLiteral("the camera's answer was not understood");
            return false;
        }
        *so = o;
        return true;
    };

    QJsonObject so;
    QString why;
    if (!readState(&so, &why)) {
        a.message = why;
        return a;
    }
    const bool nowOn = so.value(QStringLiteral("enabled")).toBool();
    auto stateText = [](bool on) { return on ? QStringLiteral("on") : QStringLiteral("off"); };
    if (mode == 0) {
        a.state = stateText(nowOn);
        a.message = QStringLiteral("rule lines on the stream are %1").arg(a.state);
        return a;
    }
    const bool want = (mode == 1);
    const int wantType = want ? 2 : 0;
    if (nowOn == want && so.value(QStringLiteral("streamType")).toInt() == wantType) {
        a.state = stateText(want);
        a.message = QStringLiteral("already %1, nothing changed").arg(a.state);
        return a;
    }
    QJsonObject out = so; // every other field goes back as it was read
    out.insert(QStringLiteral("enabled"), want);
    out.insert(QStringLiteral("streamType"), wantType);
    QByteArray reply;
    const int putCode = curlPutJson(url, cam.user, cam.pass, 10,
                                    QJsonDocument(QJsonObject{{QStringLiteral("SmartOverlap"), out}}).toJson(QJsonDocument::Compact), &reply);
    if (putCode != 200 || QJsonDocument::fromJson(reply).object().value(QStringLiteral("statusCode")).toInt() != 1) {
        a.state = QStringLiteral("error");
        a.message = putCode == 200 ? QStringLiteral("the camera did not accept the change")
                                   : (explain(putCode), a.message);
        return a;
    }
    // Read it back: only report success for what the camera now says.
    QJsonObject after;
    if (!readState(&after, &why)) {
        a.state = QStringLiteral("error");
        a.message = QStringLiteral("changed, but could not read it back: %1").arg(why);
        return a;
    }
    const bool isOn = after.value(QStringLiteral("enabled")).toBool();
    a.state = stateText(isOn);
    a.message = isOn == want ? QStringLiteral("rule lines on the stream are now %1").arg(a.state)
                             : QStringLiteral("the camera still says %1").arg(a.state);
    return a;
}

QString tag(const QString &xml, const QString &name)
{
    const QRegularExpression rx(QStringLiteral("<%1>([^<]*)</%1>").arg(name));
    return rx.match(xml).captured(1).trimmed();
}
}

HikvisionBackup::HikvisionBackup(QObject *parent) : QObject(parent) {}

HikvisionBackup::~HikvisionBackup()
{
    for (QThread *t : {m_worker, m_loader, m_ruleWorker}) {
        if (t) {
            t->disconnect(this);
            t->wait();
        }
    }
}

QString HikvisionBackup::backupDir() const
{
    const QString base = m_configPath.isEmpty() ? QSettings().fileName() : m_configPath;
    return QDir::fromNativeSeparators(QFileInfo(base).absolutePath()) + QStringLiteral("/backups");
}

void HikvisionBackup::loadCameras(const QString &recordersJson, const QString &configPath)
{
    m_configPath = configPath;
    // A recorder the user set Offline is not contacted at all, so its cameras are not listed.
    const QByteArray json = OfflineRecorders::withoutOffline(recordersJson, OfflineRecorders::readNames(configPath)).toUtf8();
    if (m_loader && m_loader->isRunning()) {
        m_hasPending = true; // the answer being worked out may already be out of date: run again when it is done
        m_pendingJson = json;
        m_pendingPath = configPath;
        return;
    }
    startLoad(json, configPath);
}

void HikvisionBackup::startLoad(const QByteArray &json, const QString &configPath)
{
    if (m_loader) {
        m_loader->wait();
        m_loader->deleteLater();
    }
    m_loader = QThread::create([this, json, configPath]() {
        QSettings saved(configPath, QSettings::IniFormat);
        saved.beginGroup(QLatin1String(kLoginGroup));
        auto login = [&](const QString &ip, QString &user, QString &pass) {
            const QJsonObject o = QJsonDocument::fromJson(saved.value(ip).toString().toUtf8()).object();
            if (o.value(QStringLiteral("user")).toString().isEmpty() || o.value(QStringLiteral("pass")).toString().isEmpty())
                return false;
            user = o.value(QStringLiteral("user")).toString();
            pass = o.value(QStringLiteral("pass")).toString();
            return true;
        };

        QMap<QString, Cam> byIp; // one entry per device, in address order
        const QJsonArray list = QJsonDocument::fromJson(json).array();
        for (const QJsonValue &rv : list) {
            const QJsonObject rec = rv.toObject();
            const QString recIp = hostOf(rec.value(QStringLiteral("ip")).toString());
            const QString recUser = rec.value(QStringLiteral("username")).toString();
            const QString recPass = rec.value(QStringLiteral("password")).toString();
            int http = rec.value(QStringLiteral("httpPort")).toVariant().toInt();
            if (http <= 0)
                http = 80;
            QString recName = rec.value(QStringLiteral("name")).toString();
            if (recName.isEmpty())
                recName = recIp;
            const QJsonArray cams = rec.value(QStringLiteral("cameras")).toArray();
            if (recIp.isEmpty())
                continue;

            auto add = [&](const QString &ip, int port, const QString &name) {
                if (ip.isEmpty() || byIp.contains(ip))
                    return;
                Cam c;
                c.name = name;
                c.ip = ip;
                c.httpPort = port;
                c.user = recUser;
                c.pass = recPass;
                c.ownLogin = login(ip, c.user, c.pass);
                byIp.insert(ip, c);
            };

            if (cams.size() <= 2) {
                add(recIp, http, recName); // a camera (or a dual-lens one): the recorder entry is the device
                continue;
            }
            // A recorder: each channel is a camera on its own address. The recorder is only asked for the list.
            const QHash<int, QVariantMap> proxy = HikvisionManager::fetchProxyChannels(recIp, http, recUser, recPass);
            for (const QJsonValue &cv : cams) {
                const QJsonObject cam = cv.toObject();
                const int ch = cam.value(QStringLiteral("channelId")).toVariant().toInt();
                const QString ip = proxy.value(ch).value(QStringLiteral("ip")).toString();
                QString nm = cam.value(QStringLiteral("customName")).toString();
                if (nm.isEmpty())
                    nm = cam.value(QStringLiteral("name")).toString();
                if (nm.isEmpty())
                    nm = QStringLiteral("Camera %1").arg(ch);
                add(ip, 80, QStringLiteral("%1 Ch.%2 %3").arg(recName).arg(ch).arg(nm));
            }
        }

        const QList<Cam> found = byIp.values();
        QVariantList out;
        for (const Cam &c : found) {
            out.append(QVariantMap{{QStringLiteral("name"), c.name},
                                   {QStringLiteral("ip"), c.ip},
                                   {QStringLiteral("login"), c.ownLogin ? QStringLiteral("own") : QStringLiteral("recorder")},
                                   {QStringLiteral("user"), c.user}});
        }
        QMetaObject::invokeMethod(this, [this, found, out]() {
            qInfo() << "[Backup] found" << found.size() << "camera(s)";
            m_cams = found;
            emit camerasLoaded(out);
        }, Qt::QueuedConnection);
    });
    connect(m_loader, &QThread::finished, this, [this]() {
        if (!m_hasPending)
            return;
        m_hasPending = false;
        startLoad(m_pendingJson, m_pendingPath);
    });
    m_loader->start();
}

// Backs up one camera. Never retries a login: a refused login is reported and left alone.
HikvisionBackup::Result HikvisionBackup::backupOne(const Cam &cam, const QString &dir)
{
    Result r;
    if (cam.user.isEmpty() || cam.pass.isEmpty()) {
        r.message = QStringLiteral("no login saved for this camera (a blank password is never sent)");
        return r;
    }
    const QString base = QStringLiteral("http://%1:%2").arg(cam.ip).arg(cam.httpPort);

    // 1. Who is this? Also the one place a refused login shows up, so it is asked only once.
    QByteArray info;
    const int infoCode = curlGet(base + QStringLiteral("/ISAPI/System/deviceInfo"), cam.user, cam.pass, 8, QString(), &info);
    if (infoCode == 401) {
        r.message = QStringLiteral("login refused: enter this camera's own username and password");
        return r;
    }
    if (infoCode == 0) {
        r.message = QStringLiteral("cannot reach the camera");
        return r;
    }
    const QString infoXml = QString::fromUtf8(info);
    const QString model = tag(infoXml, QStringLiteral("model"));
    const QString firmware = tag(infoXml, QStringLiteral("firmwareVersion"));
    const QString serial = tag(infoXml, QStringLiteral("serialNumber"));
    if (infoCode != 200 || model.isEmpty()) {
        r.kind = Result::Skipped;
        r.message = QStringLiteral("this camera does not report its details, so it cannot be backed up (HTTP %1)").arg(infoCode);
        return r;
    }

    // 2. Download into a temporary file, so a failed or partial download never looks like a backup.
    QDir().mkpath(dir);
    QFile::setPermissions(dir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    const QDateTime now = QDateTime::currentDateTime();
    const QString stem = QStringLiteral("%1_%2_%3").arg(safeName(cam.name), cam.ip, now.toString(QStringLiteral("yyyy-MM-dd_HHmmss")));
    const QString tmp = dir + QLatin1Char('/') + stem + QStringLiteral(".cfg.part");
    const QString finalPath = dir + QLatin1Char('/') + stem + QStringLiteral(".cfg");
    const int code = curlGet(base + QStringLiteral("/ISAPI/System/configurationData?secretkey=") + QLatin1String(kBackupKey),
                             cam.user, cam.pass, 90, tmp, nullptr);
    QFile f(tmp);
    const qint64 size = f.size();
    if (code != 200 || size < 1024) {
        // A rejected request comes back as a small XML message instead of a file.
        QString why = QStringLiteral("the camera answered HTTP %1").arg(code);
        if (f.open(QIODevice::ReadOnly)) {
            const QString sub = tag(QString::fromUtf8(f.read(2048)), QStringLiteral("subStatusCode"));
            if (!sub.isEmpty())
                why += QStringLiteral(" (%1)").arg(sub);
            f.close();
        }
        QFile::remove(tmp);
        r.message = QStringLiteral("export failed: ") + why;
        return r;
    }
    if (!QFile::rename(tmp, finalPath)) {
        QFile::remove(tmp);
        r.message = QStringLiteral("could not save the file in ") + dir;
        return r;
    }
    QFile::setPermissions(finalPath, QFileDevice::ReadOwner | QFileDevice::WriteOwner);

    // 3. A small description next to it, so a backup can later be matched to the camera it came from.
    QFile meta(dir + QLatin1Char('/') + stem + QStringLiteral(".json"));
    if (meta.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        const QJsonObject o{{QStringLiteral("name"), cam.name}, {QStringLiteral("ip"), cam.ip}, {QStringLiteral("model"), model},
                            {QStringLiteral("firmware"), firmware}, {QStringLiteral("serial"), serial},
                            {QStringLiteral("file"), QFileInfo(finalPath).fileName()}, {QStringLiteral("bytes"), double(size)},
                            {QStringLiteral("saved"), now.toString(Qt::ISODate)}};
        meta.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
        meta.close();
        QFile::setPermissions(meta.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    }
    r.kind = Result::Saved;
    r.message = QStringLiteral("saved %1 KB").arg(size / 1024);
    return r;
}

void HikvisionBackup::backupCamera(const QString &ip, const QString &user, const QString &password)
{
    if (m_busy)
        return;
    for (const Cam &c : m_cams) {
        if (c.ip == ip) {
            start({c}, true, user.trimmed(), password);
            return;
        }
    }
    emit finished(QStringLiteral("That camera is not in the list. Refresh the list and try again."), false);
}

void HikvisionBackup::checkRuleLines(const QString &ip)
{
    runRuleLines(ip, 0);
}

void HikvisionBackup::setRuleLines(const QString &ip, bool on)
{
    runRuleLines(ip, on ? 1 : 2);
}

void HikvisionBackup::runRuleLines(const QString &ip, int mode)
{
    if (m_ruleBusy)
        return;
    Cam found;
    bool have = false;
    for (const Cam &c : m_cams) {
        if (c.ip == ip) {
            found = c;
            have = true;
            break;
        }
    }
    if (!have) {
        emit ruleLinesResult(ip, QStringLiteral("error"), QStringLiteral("That camera is not in the list. Refresh the list and try again."));
        return;
    }
    m_ruleBusy = true;
    emit ruleBusyChanged();
    if (m_ruleWorker) {
        m_ruleWorker->wait();
        m_ruleWorker->deleteLater();
    }
    m_ruleWorker = QThread::create([this, found, mode]() {
        const RuleLinesAnswer a = ruleLinesOne(found, mode);
        QMetaObject::invokeMethod(this, [this, found, mode, a]() {
            qInfo() << "[RuleLines]" << found.ip << (mode == 0 ? "read:" : (mode == 1 ? "turn on:" : "turn off:")) << a.state << "-" << a.message;
            m_ruleBusy = false;
            emit ruleBusyChanged();
            emit ruleLinesResult(found.ip, a.state, a.message);
        }, Qt::QueuedConnection);
    });
    m_ruleWorker->start();
}

void HikvisionBackup::checkRuleLinesAll()
{
    runRuleLinesAll(0);
}

void HikvisionBackup::setRuleLinesAll(bool on)
{
    runRuleLinesAll(on ? 1 : 2);
}

// Goes through every camera of the loaded list, one after the other, one request set each. A camera that cannot take the
// switch (no switch, no saved login, not reachable) is reported and skipped. A login the camera refused is never sent to
// another camera either, so one wrong password cannot be tried again and again.
void HikvisionBackup::runRuleLinesAll(int mode)
{
    if (m_ruleBusy)
        return;
    if (m_cams.isEmpty()) {
        emit ruleLinesAllFinished(QStringLiteral("No cameras found. Refresh the list first."), false);
        return;
    }
    m_ruleBusy = true;
    emit ruleBusyChanged();
    const QList<Cam> cams = m_cams;
    if (m_ruleWorker) {
        m_ruleWorker->wait();
        m_ruleWorker->deleteLater();
    }
    m_ruleWorker = QThread::create([this, cams, mode]() {
        int on = 0, off = 0, unchanged = 0, unavailable = 0, failed = 0;
        QStringList problems;
        QSet<QString> refusedLogins;
        int n = 0;
        for (const Cam &cam : cams) {
            ++n;
            const QString login = cam.user + QLatin1Char('\n') + cam.pass;
            RuleLinesAnswer a;
            if (refusedLogins.contains(login)) {
                a.state = QStringLiteral("error");
                a.message = QStringLiteral("skipped: this login was already refused by another camera");
            } else {
                QMetaObject::invokeMethod(this, [this, cam, n, total = int(cams.size())]() {
                    emit ruleLinesAllProgress(cam.name, n, total);
                }, Qt::QueuedConnection);
                a = ruleLinesOne(cam, mode);
                if (a.refused && !login.isEmpty())
                    refusedLogins.insert(login);
            }
            qInfo() << "[RuleLines]" << cam.ip << cam.name << a.state << "-" << a.message;
            if (a.state == QLatin1String("unavailable"))
                ++unavailable;
            else if (a.state == QLatin1String("error")) {
                ++failed;
                problems << QStringLiteral("%1: %2").arg(cam.name, a.message);
            } else if (a.message.startsWith(QLatin1String("already")))
                ++unchanged;
            else if (a.state == QLatin1String("on"))
                ++on;
            else
                ++off;
        }
        QString summary;
        if (mode == 0) {
            summary = QStringLiteral("Read %1 camera(s): %2 on or off as listed, %3 without the switch, %4 could not be read.")
                          .arg(cams.size()).arg(on + off + unchanged).arg(unavailable).arg(failed);
        } else {
            summary = QStringLiteral("Rule lines %1: %2 camera(s) changed, %3 already that way, %4 without the switch, %5 failed.")
                          .arg(mode == 1 ? QStringLiteral("turned on") : QStringLiteral("turned off"))
                          .arg(mode == 1 ? on : off).arg(unchanged).arg(unavailable).arg(failed);
        }
        if (!problems.isEmpty())
            summary += QStringLiteral("\n") + problems.join(QLatin1Char('\n'));
        const bool ok = failed == 0;
        QMetaObject::invokeMethod(this, [this, summary, ok]() {
            m_ruleBusy = false;
            emit ruleBusyChanged();
            emit ruleLinesAllFinished(summary, ok);
        }, Qt::QueuedConnection);
    });
    m_ruleWorker->start();
}

void HikvisionBackup::backupAll()
{
    if (m_busy)
        return;
    if (m_cams.isEmpty()) {
        emit finished(QStringLiteral("No cameras found. Refresh the list first."), false);
        return;
    }
    start(m_cams, false, QString(), QString());
}

void HikvisionBackup::start(const QList<Cam> &cams, bool single, const QString &overrideUser, const QString &overridePass)
{
    m_busy = true;
    emit busyChanged();
    const QString dir = backupDir();
    const QString configPath = m_configPath;
    if (m_worker) {
        m_worker->wait();
        m_worker->deleteLater();
    }
    m_worker = QThread::create([this, cams, single, overrideUser, overridePass, dir, configPath]() {
        int saved = 0, skipped = 0, failed = 0;
        QStringList problems;
        int n = 0;
        for (Cam cam : cams) {
            ++n;
            bool usedOverride = false;
            if (single && !overrideUser.isEmpty() && !overridePass.isEmpty()) {
                cam.user = overrideUser; // this camera's own login, typed just now
                cam.pass = overridePass;
                usedOverride = true;
            }
            QMetaObject::invokeMethod(this, [this, cam, n, total = cams.size()]() {
                emit progress(cam.name, QStringLiteral("Backing up %1 of %2 (%3)...").arg(n).arg(total).arg(cam.ip));
            }, Qt::QueuedConnection);

            const Result res = backupOne(cam, dir);
            if (res.kind == Result::Saved) {
                ++saved;
                if (usedOverride) {
                    // The camera accepted this login: keep it for this camera from now on.
                    QSettings s(configPath, QSettings::IniFormat);
                    s.beginGroup(QLatin1String(kLoginGroup));
                    s.setValue(cam.ip, QString::fromUtf8(QJsonDocument(QJsonObject{{QStringLiteral("user"), cam.user},
                                                                                  {QStringLiteral("pass"), cam.pass}}).toJson(QJsonDocument::Compact)));
                }
            } else if (res.kind == Result::Skipped) {
                ++skipped;
                problems << QStringLiteral("%1: %2").arg(cam.name, res.message);
            } else {
                ++failed;
                problems << QStringLiteral("%1: %2").arg(cam.name, res.message);
            }
            qInfo() << "[Backup]" << cam.name << cam.ip << res.message;
        }

        QString summary;
        if (single) {
            summary = problems.isEmpty() ? QStringLiteral("%1 backed up to %2").arg(cams.first().name, dir)
                                         : problems.first();
        } else {
            summary = QStringLiteral("Backed up %1 of %2 cameras to %3").arg(saved).arg(cams.size()).arg(dir);
            if (skipped > 0)
                summary += QStringLiteral("; %1 skipped").arg(skipped);
            if (failed > 0)
                summary += QStringLiteral("; %1 failed").arg(failed);
            if (!problems.isEmpty())
                summary += QStringLiteral("\n") + problems.mid(0, 6).join(QStringLiteral("\n"));
        }
        const bool ok = failed == 0 && (saved > 0 || skipped == 0);
        QMetaObject::invokeMethod(this, [this, summary, ok]() {
            m_busy = false;
            emit busyChanged();
            emit finished(summary, ok);
        }, Qt::QueuedConnection);
    });
    m_worker->start();
}

namespace {
// PUT a file to a camera with curl. Returns the HTTP status (0 when it could not connect); the answer goes to *body.
int curlPut(const QString &url, const QString &user, const QString &pass, int maxSeconds, const QString &file,
            QByteArray *body)
{
    QStringList args;
    args << QStringLiteral("-s") << QStringLiteral("-k") << QStringLiteral("--anyauth") << QStringLiteral("-u")
         << QStringLiteral("%1:%2").arg(user, pass) << QStringLiteral("--max-time") << QString::number(maxSeconds)
         << QStringLiteral("-X") << QStringLiteral("PUT") << QStringLiteral("--data-binary") << QStringLiteral("@") + file
         << QStringLiteral("-H") << QStringLiteral("Content-Type: application/octet-stream")
         << QStringLiteral("-w") << QStringLiteral("%{http_code}") << url;
    QProcess p;
    p.start(QStringLiteral("curl"), args);
    if (!p.waitForFinished((maxSeconds + 10) * 1000)) {
        p.kill();
        return 0;
    }
    const QByteArray out = p.readAllStandardOutput();
    if (body)
        *body = out.left(qMax(0, int(out.size()) - 3));
    return out.right(3).toInt();
}

// PUT with no body (the restart request). Returns the HTTP status, 0 when it could not connect.
int curlPutEmpty(const QString &url, const QString &user, const QString &pass, int maxSeconds, QByteArray *body)
{
    QProcess p;
    p.start(QStringLiteral("curl"), {QStringLiteral("-s"), QStringLiteral("-k"), QStringLiteral("--anyauth"), QStringLiteral("-u"),
                                     QStringLiteral("%1:%2").arg(user, pass), QStringLiteral("--max-time"), QString::number(maxSeconds),
                                     QStringLiteral("-X"), QStringLiteral("PUT"), QStringLiteral("-w"), QStringLiteral("%{http_code}"), url});
    if (!p.waitForFinished((maxSeconds + 5) * 1000)) {
        p.kill();
        return 0;
    }
    const QByteArray out = p.readAllStandardOutput();
    if (body)
        *body = out.left(qMax(0, int(out.size()) - 3));
    return out.right(3).toInt();
}

// Is the camera answering at all? No login is sent, so this can never count as a failed login. 0 = no answer;
// any HTTP status (a 401 included) means the camera's web server is up.
int probeUp(const QString &ip, int port)
{
    QProcess p;
    p.start(QStringLiteral("curl"), {QStringLiteral("-s"), QStringLiteral("-k"), QStringLiteral("--max-time"), QStringLiteral("3"),
                                     QStringLiteral("-o"), QStringLiteral("/dev/null"), QStringLiteral("-w"), QStringLiteral("%{http_code}"),
                                     QStringLiteral("http://%1:%2/ISAPI/System/deviceInfo").arg(ip).arg(port)});
    if (!p.waitForFinished(6000)) {
        p.kill();
        return 0;
    }
    return p.readAllStandardOutput().trimmed().toInt();
}
}


// Restores one camera from a backup file made earlier. Result::Saved means the camera took the file and came back.
HikvisionBackup::Result HikvisionBackup::restoreOne(const Cam &cam, const QString &dir, const QString &fileName,
                                                    const std::function<void(const QString &)> &say)
{
    Result r;
    if (cam.user.isEmpty() || cam.pass.isEmpty()) {
        r.message = QStringLiteral("no login saved for this camera (a blank password is never sent)");
        return r;
    }

    // 1. The file must be one of ours: in the backups folder, a .cfg, with its description beside it.
    const QFileInfo cfg(dir + QLatin1Char('/') + QFileInfo(fileName).fileName());
    if (cfg.suffix() != QLatin1String("cfg") || !cfg.exists()) {
        r.message = QStringLiteral("that backup file was not found in ") + dir;
        return r;
    }
    QFile metaFile(cfg.absolutePath() + QLatin1Char('/') + cfg.completeBaseName() + QStringLiteral(".json"));
    if (!metaFile.open(QIODevice::ReadOnly)) {
        r.message = QStringLiteral("the description file beside the backup is missing, so it cannot be matched to a camera");
        return r;
    }
    const QJsonObject meta = QJsonDocument::fromJson(metaFile.readAll()).object();
    const QString wantSerial = meta.value(QStringLiteral("serial")).toString();
    if (wantSerial.isEmpty() || meta.value(QStringLiteral("ip")).toString() != cam.ip) {
        r.message = QStringLiteral("this backup does not belong to this camera");
        return r;
    }

    // 2. The camera in front of us must be the camera the backup came from.
    say(QStringLiteral("Checking the camera..."));
    const QString base = QStringLiteral("http://%1:%2").arg(cam.ip).arg(cam.httpPort);
    QByteArray info;
    const int infoCode = curlGet(base + QStringLiteral("/ISAPI/System/deviceInfo"), cam.user, cam.pass, 8, QString(), &info);
    if (infoCode == 401) {
        r.message = QStringLiteral("login refused: enter this camera's own username and password");
        return r;
    }
    if (infoCode != 200) {
        r.message = QStringLiteral("cannot read the camera (HTTP %1)").arg(infoCode);
        return r;
    }
    const QString haveSerial = tag(QString::fromUtf8(info), QStringLiteral("serialNumber"));
    if (haveSerial != wantSerial) {
        r.message = QStringLiteral("the camera's serial number (%1) does not match the backup (%2)").arg(haveSerial, wantSerial);
        return r;
    }

    // 3. A fresh backup of the camera as it is now, so a bad restore can be undone. If this fails, nothing is sent.
    say(QStringLiteral("Saving a safety backup of the current settings first..."));
    const Result safety = backupOne(cam, dir);
    if (safety.kind != Result::Saved) {
        r.message = QStringLiteral("could not take the safety backup first (%1); nothing was changed").arg(safety.message);
        return r;
    }

    // 4. Send the file.
    say(QStringLiteral("Uploading the backup..."));
    QByteArray answer;
    const int putCode = curlPut(base + QStringLiteral("/ISAPI/System/configurationData?secretkey=") + QLatin1String(kBackupKey),
                                cam.user, cam.pass, 120, cfg.absoluteFilePath(), &answer);
    const QString answerText = QString::fromUtf8(answer);
    const QString statusCode = tag(answerText, QStringLiteral("statusCode"));
    // 1 = OK, 7 = OK and a reboot is needed.
    const bool accepted = putCode == 200 && (statusCode.isEmpty() || statusCode == QLatin1String("1") || statusCode == QLatin1String("7"));
    const QString statusString = tag(answerText, QStringLiteral("statusString"));
    qInfo() << "[Restore]" << cam.ip << "upload answered HTTP" << putCode << "statusCode" << statusCode << statusString;
    if (!accepted) {
        QString why = QStringLiteral("the camera answered HTTP %1").arg(putCode);
        const QString sub = tag(answerText, QStringLiteral("subStatusCode"));
        if (!sub.isEmpty())
            why += QStringLiteral(" (%1)").arg(sub);
        r.message = why + QStringLiteral("; the safety backup was saved in ") + dir;
        return r;
    }

    // 5. Some cameras apply the file at once; others accept it and say a restart is needed (status 7). Then the
    // settings only take effect after a restart, so it is asked for here, as the confirmation said.
    const bool needsRestart = statusCode == QLatin1String("7");
    if (needsRestart) {
        say(QStringLiteral("The camera accepted the file and asks for a restart. Restarting it..."));
        QByteArray rebootAnswer;
        const int rebootCode = curlPutEmpty(base + QStringLiteral("/ISAPI/System/reboot"), cam.user, cam.pass, 15, &rebootAnswer);
        qInfo() << "[Restore]" << cam.ip << "restart request answered HTTP" << rebootCode
                << tag(QString::fromUtf8(rebootAnswer), QStringLiteral("statusString"));
        if (rebootCode != 200) {
            r.message = QStringLiteral("the camera accepted the file but needs a restart, and the restart request failed (HTTP %1); "
                                       "restart it by hand for the settings to apply").arg(rebootCode);
            return r;
        }
    }
    say(QStringLiteral("Uploaded. Waiting for the camera to restart..."));
    bool wentDown = false;
    qint64 waited = 0;
    for (; waited < 60 && !wentDown; waited += 2) {
        QThread::sleep(2);
        wentDown = probeUp(cam.ip, cam.httpPort) == 0;
    }
    bool back = !wentDown && probeUp(cam.ip, cam.httpPort) != 0;
    for (waited = 0; wentDown && waited < 240 && !back; waited += 3) {
        QThread::sleep(3);
        back = probeUp(cam.ip, cam.httpPort) != 0;
        if (!back && waited % 15 == 0)
            say(QStringLiteral("Waiting for the camera to restart... (%1 s)").arg(waited));
    }
    if (!back) {
        r.message = QStringLiteral("the file was sent, but the camera has not answered for 4 minutes; check it");
        return r;
    }
    QThread::sleep(3); // let its services come up

    // 6. One login to confirm it is healthy. The restored settings include the password from the backup.
    QByteArray after;
    const int afterCode = curlGet(base + QStringLiteral("/ISAPI/System/deviceInfo"), cam.user, cam.pass, 8, QString(), &after);
    r.kind = Result::Saved;
    if (afterCode == 401)
        r.message = QStringLiteral("restored and back online, but it now refuses the saved login: the backup's own password applies");
    else if (afterCode != 200)
        r.message = QStringLiteral("restored; the camera is answering but not fully up yet (HTTP %1)").arg(afterCode);
    else if (wentDown)
        r.message = needsRestart ? QStringLiteral("restored; the camera needed a restart, which was done, and it is back online")
                                 : QStringLiteral("restored and back online");
    else
        r.message = QStringLiteral("the camera accepted the file (answer: %1) and stayed online; it did not restart on its own")
                        .arg(statusString.isEmpty() ? QStringLiteral("status ") + statusCode : statusString);
    return r;
}

QVariantList HikvisionBackup::listBackups(const QString &ip) const
{
    QVariantList out;
    const QString dir = backupDir();
    const QFileInfoList files = QDir(dir).entryInfoList({QStringLiteral("*.json")}, QDir::Files, QDir::Name | QDir::Reversed);
    for (const QFileInfo &fi : files) {
        QFile f(fi.absoluteFilePath());
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        const QString cfg = o.value(QStringLiteral("file")).toString();
        if (o.value(QStringLiteral("ip")).toString() != ip || cfg.isEmpty() || !QFileInfo::exists(dir + QLatin1Char('/') + cfg))
            continue;
        const QDateTime when = QDateTime::fromString(o.value(QStringLiteral("saved")).toString(), Qt::ISODate);
        out.append(QVariantMap{{QStringLiteral("file"), cfg},
                               {QStringLiteral("label"), QStringLiteral("%1  (firmware %2, %3 KB)")
                                    .arg(QLocale::c().toString(when, QStringLiteral("d MMM yyyy HH:mm")),
                                         o.value(QStringLiteral("firmware")).toString())
                                    .arg(qint64(o.value(QStringLiteral("bytes")).toDouble()) / 1024)}});
    }
    return out;
}

void HikvisionBackup::restoreCamera(const QString &ip, const QString &file, const QString &user, const QString &password)
{
    if (m_busy)
        return;
    const Cam *found = nullptr;
    for (const Cam &c : m_cams) {
        if (c.ip == ip)
            found = &c;
    }
    if (!found) {
        emit finished(QStringLiteral("That camera is not in the list. Refresh the list and try again."), false);
        return;
    }
    Cam cam = *found;
    if (!user.trimmed().isEmpty() && !password.isEmpty()) {
        cam.user = user.trimmed();
        cam.pass = password;
    }
    m_busy = true;
    emit busyChanged();
    const QString dir = backupDir();
    if (m_worker) {
        m_worker->wait();
        m_worker->deleteLater();
    }
    m_worker = QThread::create([this, cam, file, dir]() {
        auto say = [this, cam](const QString &text) {
            QMetaObject::invokeMethod(this, [this, cam, text]() { emit progress(cam.name, text); }, Qt::QueuedConnection);
        };
        const Result res = restoreOne(cam, dir, file, say);
        qInfo() << "[Restore]" << cam.name << cam.ip << res.message;
        const bool ok = res.kind == Result::Saved;
        const QString summary = ok ? QStringLiteral("%1: %2").arg(cam.name, res.message)
                                   : QStringLiteral("%1 was NOT restored: %2").arg(cam.name, res.message);
        QMetaObject::invokeMethod(this, [this, summary, ok]() {
            m_busy = false;
            emit busyChanged();
            emit finished(summary, ok);
        }, Qt::QueuedConnection);
    });
    m_worker->start();
}
