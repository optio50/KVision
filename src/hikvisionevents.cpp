#include "hikvisionevents.h"

#include <QAuthenticator>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QLocale>
#include <QTextStream>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>

namespace {
const int kMaxFailures = 3;       // after this many failed attempts in a row, stop trying
const int kRetryMs = 15000;       // wait between attempts
const int kMaxBuffer = 256 * 1024; // pictures can ride along in an event; never keep more than this

// Smart (VCA) event types a camera can stream, and the words used for them in the detection log.
QString vcaKind(const QString &type)
{
    static const QHash<QString, QString> kinds = {
        { QStringLiteral("linedetection"), QStringLiteral("Line crossing") },
        { QStringLiteral("fielddetection"), QStringLiteral("Intrusion") },
        { QStringLiteral("regionEntrance"), QStringLiteral("Region entrance") },
        { QStringLiteral("regionExiting"), QStringLiteral("Region exit") },
        { QStringLiteral("loitering"), QStringLiteral("Loitering") },
        { QStringLiteral("group"), QStringLiteral("People gathering") },
        { QStringLiteral("rapidMove"), QStringLiteral("Rapid movement") },
        { QStringLiteral("parking"), QStringLiteral("Parking") },
        { QStringLiteral("unattendedBaggage"), QStringLiteral("Unattended object") },
        { QStringLiteral("attendedBaggage"), QStringLiteral("Object removed") },
    };
    return kinds.value(type);
}

// The short word shown after the target on a tile, for example "HUMAN - LINE".
QString vcaShort(const QString &type)
{
    if (type == QLatin1String("linedetection"))
        return QStringLiteral("LINE");
    if (type == QLatin1String("fielddetection"))
        return QStringLiteral("INTRUSION");
    if (type == QLatin1String("regionEntrance"))
        return QStringLiteral("ENTER");
    if (type == QLatin1String("regionExiting"))
        return QStringLiteral("EXIT");
    return QStringLiteral("SMART");
}
}

HikvisionEvents::HikvisionEvents(QObject *parent)
    : QObject(parent)
{
    m_net = new QNetworkAccessManager(this);
    connect(m_net, &QNetworkAccessManager::authenticationRequired, this,
            [](QNetworkReply *reply, QAuthenticator *auth) {
        // One attempt only: when the stored password is wrong, a second try could lock the camera.
        if (reply->property("authTried").toBool()) {
            reply->abort();
            return;
        }
        reply->setProperty("authTried", true);
        auth->setUser(reply->property("evUser").toString());
        auth->setPassword(reply->property("evPass").toString());
    });
}

HikvisionEvents::~HikvisionEvents()
{
    const auto ips = m_conns.keys();
    for (const QString &ip : ips)
        close(ip);
}

void HikvisionEvents::watch(const QString &ip, int httpPort, const QString &user, const QString &pass,
                            const QString &name, const QString &configDir,
                            const QString &recorderIp, int recorderChannel)
{
    if (ip.isEmpty() || user.isEmpty() || pass.isEmpty())
        return; // never send a login we know is incomplete: a wrong login counts toward a camera lockout
    if (m_logDir.isEmpty() && !configDir.isEmpty())
        m_logDir = configDir + QStringLiteral("/logs");
    Conn *c = m_conns.value(ip, nullptr);
    if (!c) {
        c = new Conn;
        c->ip = ip;
        c->httpPort = httpPort > 0 ? httpPort : 80;
        c->user = user;
        c->pass = pass;
        c->name = name;
        c->recIp = recorderIp;
        c->recChannel = recorderChannel;
        c->retry = new QTimer(this);
        c->retry->setSingleShot(true);
        c->retry->setInterval(kRetryMs);
        connect(c->retry, &QTimer::timeout, this, [this, ip]() {
            if (m_conns.contains(ip))
                open(ip);
        });
        m_conns.insert(ip, c);
    }
    ++c->watchers;
    if (c->name.isEmpty() && !name.isEmpty())
        c->name = name;
    if (c->recIp.isEmpty() && !recorderIp.isEmpty()) {
        c->recIp = recorderIp;
        c->recChannel = recorderChannel;
    }
    if (!c->reply && !c->retry->isActive() && c->failures < kMaxFailures && !c->authFailed)
        open(ip);
}

void HikvisionEvents::unwatch(const QString &ip)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c)
        return;
    if (--c->watchers <= 0)
        close(ip);
}

void HikvisionEvents::close(const QString &ip)
{
    Conn *c = m_conns.take(ip);
    if (!c)
        return;
    if (c->retry) {
        c->retry->stop();
        c->retry->deleteLater();
    }
    if (c->reply) {
        c->reply->disconnect(this);
        c->reply->abort();
        c->reply->deleteLater();
    }
    delete c;
}

void HikvisionEvents::open(const QString &ip)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->reply)
        return;
    QUrl url;
    url.setScheme(QStringLiteral("http"));
    url.setHost(ip.section(QLatin1Char(':'), 0, 0).trimmed());
    url.setPort(c->httpPort);
    url.setPath(QStringLiteral("/ISAPI/Event/notification/alertStream"));
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
    c->buffer.clear();
    qDebug() << "[Events] opening the detection stream for" << ip;
    c->reply = m_net->get(req);
    c->reply->setProperty("evUser", c->user);
    c->reply->setProperty("evPass", c->pass);
    connect(c->reply, &QIODevice::readyRead, this, [this, ip]() { onReadyRead(ip); });
    QNetworkReply *reply = c->reply;
    connect(reply, &QNetworkReply::finished, this, [this, ip, reply]() { onFinished(ip, reply); });
}

void HikvisionEvents::onReadyRead(const QString &ip)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || !c->reply)
        return;
    c->failures = 0; // data is arriving, so the login worked
    c->buffer += c->reply->readAll();
    if (c->buffer.size() > kMaxBuffer)
        c->buffer = c->buffer.right(kMaxBuffer / 2);

    static const QRegularExpression eventRx(
        QStringLiteral("<EventNotificationAlert.*?</EventNotificationAlert>"),
        QRegularExpression::DotMatchesEverythingOption);
    static const QRegularExpression typeRx(QStringLiteral("<eventType>([^<]*)</eventType>"));
    static const QRegularExpression targetRx(QStringLiteral("<targetType>([^<]*)</targetType>"));
    static const QRegularExpression timeRx(QStringLiteral("<dateTime>([^<]*)</dateTime>"));
    static const QRegularExpression chanRx(QStringLiteral("<channelID>(\\d+)</channelID>"));
    static const QRegularExpression stateRx(QStringLiteral("<eventState>([^<]*)</eventState>"));
    static const QRegularExpression vcaTargetRx(QStringLiteral("<detectionTarget>([^<]*)</detectionTarget>"));

    int consumed = 0;
    const QString text = QString::fromLatin1(c->buffer);
    QRegularExpressionMatchIterator it = eventRx.globalMatch(text);
    while (it.hasNext()) {
        const QRegularExpressionMatch m = it.next();
        consumed = m.capturedEnd();
        const QString body = m.captured(0);
        const QString type = typeRx.match(body).captured(1);
        const QString camTime = timeRx.match(body).captured(1);
        const int camChannel = chanRx.match(body).captured(1).toInt();
        if (type != QLatin1String("VMD")) {
            // A smart event (line crossing, intrusion, region entrance or exit...). The camera names
            // the target inside the rule. All of them go to the detection log and show the tile's
            // detection frame with that target, like a labelled motion report.
            const QString kind = vcaKind(type);
            if (!kind.isEmpty() && stateRx.match(body).captured(1) == QLatin1String("active")) {
                QString t = vcaTargetRx.match(body).captured(1).trimmed().toLower();
                if (!t.isEmpty() && t != QLatin1String("human") && t != QLatin1String("vehicle") && t != QLatin1String("animal"))
                    t = QStringLiteral("other");
                logDetection(c, t, kind, camTime, camChannel);
                if (t.isEmpty())
                    t = QStringLiteral("other");
                qDebug() << "[Events]" << kind << "from" << ip << ":" << t;
                emit targetDetected(ip, t, vcaShort(type));
            }
            continue;
        }
        QString target = targetRx.match(body).captured(1).trimmed().toLower();
        if (target.isEmpty()) {
            emit motionDetected(ip);
            continue;
        }
        if (target != QLatin1String("human") && target != QLatin1String("vehicle") && target != QLatin1String("animal"))
            target = QStringLiteral("other");
        qDebug() << "[Events] report from" << ip << ":" << target;
        logDetection(c, target, QStringLiteral("Motion"), camTime, camChannel);
        emit targetDetected(ip, target, QStringLiteral("MOTION"));
    }
    if (consumed > 0)
        c->buffer.remove(0, consumed);
}

void HikvisionEvents::onFinished(const QString &ip, QNetworkReply *reply)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->reply != reply) {
        reply->deleteLater();
        return;
    }
    const QNetworkReply::NetworkError err = reply->error();
    const int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QString errText = reply->errorString();
    const bool triedLogin = reply->property("authTried").toBool();
    c->reply = nullptr;
    reply->deleteLater();
    if (err == QNetworkReply::OperationCanceledError && c->watchers <= 0)
        return;
    qDebug() << "[Events]" << ip << "stream ended: HTTP" << httpStatus << "error" << int(err) << errText
            << "loginSent" << triedLogin << "gotData" << (c->buffer.size() > 0 || c->failures == 0 ? "maybe" : "no");
    // Only a real 401 or 403 means the camera refused our password. Anything else (a dropped
    // connection, a timeout) is retried a few times, because a wrong guess could lock the camera.
    if (httpStatus == 401 || httpStatus == 403 || err == QNetworkReply::AuthenticationRequiredError) {
        c->authFailed = true;
        qWarning() << "[Events]" << ip << "refused the login (HTTP" << httpStatus << "). Not trying again.";
        emit listenFailed(ip, tr("The camera refused the login. Check its password."));
        return;
    }
    // The camera closed the stream or the network dropped; try again a few times.
    ++c->failures;
    if (c->failures >= kMaxFailures) {
        qWarning() << "[Events] Giving up on" << ip << "after" << c->failures << "failed attempts";
        emit listenFailed(ip, tr("Could not listen to this camera's detection events."));
        return;
    }
    c->retry->start();
}

// One line per labelled report, in the order they arrive:
//   10 Nov 2026 08:52:24, Human detected, Motion, Camera_Name, 192.0.0.3, recorder 192.0.0.99 ch 17
//   10 Nov 2026 08:53:10, Vehicle detected, Line crossing, Camera_Name, 192.0.0.3, recorder 192.0.0.99 ch 17
// The time is the camera's own time for the event, shown in this computer's time zone. When KVision
// only read the report 10 seconds or more after the camera made it (for example after a stall), the
// line ends with ", received HH:mm:ss". Plain motion reports carry no target type and are not logged.
void HikvisionEvents::logDetection(const Conn *c, const QString &target, const QString &kind, const QString &cameraTime, int eventChannel)
{
    if (m_logDir.isEmpty())
        return;
    QDir().mkpath(m_logDir);
    QFile f(m_logDir + QStringLiteral("/Detection.log"));
    if (!f.open(QIODevice::Append | QIODevice::Text)) {
        qWarning() << "[Events] cannot write" << f.fileName() << f.errorString();
        return;
    }
    const QString what = target.isEmpty() ? QStringLiteral("Object") : target.left(1).toUpper() + target.mid(1);
    const QDateTime now = QDateTime::currentDateTime();
    QDateTime eventTime = QDateTime::fromString(cameraTime, Qt::ISODate);
    QString late;
    if (eventTime.isValid()) {
        eventTime = eventTime.toLocalTime();
        if (eventTime.secsTo(now) >= 10)
            late = QStringLiteral(", received ") + QLocale::c().toString(now, QStringLiteral("HH:mm:ss"));
    } else {
        eventTime = now;
    }
    const QString when = QLocale::c().toString(eventTime, QStringLiteral("dd MMM yyyy HH:mm:ss"));
    // Where to play this back from. A standalone camera is its own recorder, and its report names the
    // channel; a camera behind a recorder reports channel 1 of itself, so the tile's channel is used.
    QString recorder;
    if (!c->recIp.isEmpty()) {
        const int ch = (c->recIp == c->ip && eventChannel > 0) ? eventChannel : c->recChannel;
        if (ch > 0)
            recorder = QStringLiteral(", recorder ") + c->recIp + QStringLiteral(" ch ") + QString::number(ch);
    }
    QTextStream(&f) << when << ", " << what << " detected, " << kind << ", " << (c->name.isEmpty() ? c->ip : c->name) << ", " << c->ip << recorder << late << "\n";
}

// One line each time a tile shows a detection frame (a camera shown on two tiles gives two lines):
//   10 Nov 2026 08:52:24, Frame shown, HUMAN - LINE, tile 19, Camera_Name, 192.0.0.3
void HikvisionEvents::logFrame(const QString &ip, const QString &text, int tile)
{
    if (m_logDir.isEmpty())
        return;
    QDir().mkpath(m_logDir);
    QFile f(m_logDir + QStringLiteral("/Frames.log"));
    if (!f.open(QIODevice::Append | QIODevice::Text))
        return;
    const Conn *c = m_conns.value(ip, nullptr);
    const QString when = QLocale::c().toString(QDateTime::currentDateTime(), QStringLiteral("dd MMM yyyy HH:mm:ss"));
    QTextStream(&f) << when << ", Frame shown, " << text << ", tile " << tile << ", " << (c && !c->name.isEmpty() ? c->name : ip) << ", " << ip << "\n";
}

QVariantMap HikvisionEvents::readDetections(int skip, int count, const QString &configDir, const QString &filterIp) const
{
    QVariantMap result;
    QVariantList entries;
    bool more = false;
    QFile f(configDir + QStringLiteral("/logs/Detection.log"));
    if (skip < 0)
        skip = 0;
    if (count < 1)
        count = 1;
    if (f.open(QIODevice::ReadOnly)) {
        // Walk backwards in blocks until enough complete lines are in hand (or the start is reached).
        const qint64 size = f.size();
        const qint64 block = 64 * 1024;
        qint64 pos = size;
        QByteArray data;
        const int need = skip + count + 1; // one extra line tells us whether older entries remain
        // With a camera filter any part of the file may hold matches, so read it all.
        while (pos > 0 && (!filterIp.isEmpty() || data.count('\n') <= need)) {
            const qint64 start = qMax<qint64>(0, pos - block);
            f.seek(start);
            data.prepend(f.read(pos - start));
            pos = start;
        }
        QList<QByteArray> lines = data.split('\n');
        if (pos > 0 && !lines.isEmpty())
            lines.removeFirst(); // the first line may be cut in half
        for (int i = lines.size() - 1; i >= 0; --i) {
            const QString line = QString::fromUtf8(lines.at(i)).trimmed();
            if (line.isEmpty())
                continue;
            // time, "<Target> detected", [kind,] camera, ip [, received HH:mm:ss]. Older lines have no kind.
            QStringList parts = line.split(QStringLiteral(", "));
            QVariantMap e;
            e.insert(QStringLiteral("raw"), line);
            QString received;
            if (!parts.isEmpty() && parts.last().startsWith(QStringLiteral("received "))) {
                received = parts.takeLast().mid(9);
            }
            QString recorderIp;
            int channel = 0;
            if (!parts.isEmpty() && parts.last().startsWith(QStringLiteral("recorder "))) {
                const QStringList r = parts.takeLast().mid(9).split(QLatin1Char(' ')); // "<ip> ch <n>"
                if (r.size() == 3 && r.at(1) == QLatin1String("ch")) {
                    recorderIp = r.at(0);
                    channel = r.at(2).toInt();
                }
            }
            if (parts.size() >= 4) {
                e.insert(QStringLiteral("time"), parts.at(0));
                e.insert(QStringLiteral("target"), parts.at(1).section(QLatin1Char(' '), 0, 0));
                const bool hasKind = parts.size() >= 5;
                e.insert(QStringLiteral("kind"), hasKind ? parts.at(2) : QString());
                e.insert(QStringLiteral("camera"), parts.mid(hasKind ? 3 : 2, parts.size() - (hasKind ? 4 : 3)).join(QStringLiteral(", ")));
                e.insert(QStringLiteral("ip"), parts.last());
            } else {
                e.insert(QStringLiteral("time"), QString());
                e.insert(QStringLiteral("target"), QString());
                e.insert(QStringLiteral("kind"), QString());
                e.insert(QStringLiteral("camera"), line);
                e.insert(QStringLiteral("ip"), QString());
            }
            e.insert(QStringLiteral("received"), received);
            e.insert(QStringLiteral("recorderIp"), recorderIp);
            e.insert(QStringLiteral("channel"), channel);
            const QDateTime when = QLocale::c().toDateTime(e.value(QStringLiteral("time")).toString(), QStringLiteral("dd MMM yyyy HH:mm:ss"));
            e.insert(QStringLiteral("epochMs"), when.isValid() ? when.toMSecsSinceEpoch() : qint64(0));
            if (!filterIp.isEmpty() && e.value(QStringLiteral("ip")).toString() != filterIp)
                continue;
            if (skip > 0) {
                --skip;
                continue;
            }
            if (entries.size() >= count) {
                more = true;
                break;
            }
            entries.append(e);
        }
    }
    result.insert(QStringLiteral("entries"), entries);
    result.insert(QStringLiteral("more"), more);
    return result;
}
