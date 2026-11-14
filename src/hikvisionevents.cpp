#include "hikvisionevents.h"

#include <QAuthenticator>
#include <QDateTime>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDir>
#include <QImage>
#include <QFile>
#include <QFileInfo>
#include <QLocale>
#include <QTextStream>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>

namespace {
const int kMaxFailures = 3;       // after this many failed attempts in a row, tell the user once (it keeps trying)
const int kRetryBaseMs = 2000;    // first wait before reopening a lost stream; doubles each time
const int kRetryMaxMs = 30000;    // and never waits longer than this
const int kHealthyMs = 10000;     // a stream that has stayed up this long counts as working
const int kStallMs = 40000;       // a camera sends a heartbeat about every 10 s: this long with no data means the stream is dead
const int kMaxBuffer = 1024 * 1024; // pictures can ride along in an event; never keep more than this

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

// Splits a comma list into its non-empty items (the flag moved from QString to Qt in Qt 5.14).
QStringList splitList(const QString &list)
{
#if QT_VERSION >= QT_VERSION_CHECK(5, 14, 0)
    return list.split(QLatin1Char(','), Qt::SkipEmptyParts);
#else
    return list.split(QLatin1Char(','), QString::SkipEmptyParts);
#endif
}

// How long to wait before reopening a stream that has failed `failures` times in a row.
int retryDelayMs(int failures)
{
    int ms = kRetryBaseMs;
    for (int i = 1; i < failures && ms < kRetryMaxMs; ++i)
        ms *= 2;
    return qMin(ms, kRetryMaxMs);
}

// The key the filter setting uses for a kind of report.
QString vcaKey(const QString &type)
{
    if (type == QLatin1String("linedetection"))
        return QStringLiteral("line");
    if (type == QLatin1String("fielddetection"))
        return QStringLiteral("intrusion");
    if (type == QLatin1String("regionEntrance"))
        return QStringLiteral("enter");
    if (type == QLatin1String("regionExiting"))
        return QStringLiteral("exit");
    return QStringLiteral("other");
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
                            const QString &recorderIp, int recorderChannel, bool recorderMode)
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
        c->recorderMode = recorderMode;
        c->retry = new QTimer(this);
        c->retry->setSingleShot(true);
        connect(c->retry, &QTimer::timeout, this, [this, ip]() {
            if (m_conns.contains(ip))
                open(ip);
        });
        c->watchdog = new QTimer(this);
        c->watchdog->setSingleShot(true);
        c->watchdog->setInterval(kStallMs);
        connect(c->watchdog, &QTimer::timeout, this, [this, ip]() {
            Conn *conn = m_conns.value(ip, nullptr);
            if (!conn || !conn->reply)
                return;
            qWarning() << "[Events]" << ip << "sent nothing for" << kStallMs / 1000 << "seconds. Reopening the detection stream.";
            conn->reply->abort(); // finished() follows and the normal retry takes over
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
    if (!c->reply && !c->retry->isActive() && !c->authFailed && !c->unsupported)
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
    if (c->watchdog) {
        c->watchdog->stop();
        c->watchdog->deleteLater();
    }
    if (c->reply) {
        c->reply->disconnect(this);
        c->reply->abort();
        c->reply->deleteLater();
    }
    delete c;
}

QVariantList HikvisionEvents::connectionStates() const
{
    QVariantList out;
    for (auto it = m_conns.constBegin(); it != m_conns.constEnd(); ++it) {
        const Conn *c = it.value();
        QVariantMap m;
        m.insert(QStringLiteral("ip"), c->ip);
        m.insert(QStringLiteral("name"), c->name.isEmpty() ? c->ip : c->name);
        m.insert(QStringLiteral("open"), c->reply != nullptr && c->lastDataMs >= c->openedMs && c->lastDataMs > 0);
        m.insert(QStringLiteral("lastDataMs"), c->lastDataMs);
        m.insert(QStringLiteral("openedMs"), c->openedMs);
        m.insert(QStringLiteral("failures"), c->failures);
        m.insert(QStringLiteral("authFailed"), c->authFailed);
        m.insert(QStringLiteral("unsupported"), c->unsupported);
        out.append(m);
    }
    return out;
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
    c->openedMs = QDateTime::currentMSecsSinceEpoch();
    c->watchdog->start();
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
    // Data is arriving, so the login worked. The failure count only starts again once the stream has stayed up
    // for a while, so a camera that connects and drops at once is not asked again every two seconds.
    if (QDateTime::currentMSecsSinceEpoch() - c->openedMs >= kHealthyMs)
        c->failures = 0;
    c->watchdog->start(); // and the stream is alive: start the stall timer again
    c->lastDataMs = QDateTime::currentMSecsSinceEpoch();
    c->buffer += c->reply->readAll();
    if (c->buffer.size() > kMaxBuffer) {
        c->buffer = c->buffer.right(kMaxBuffer / 2);
        c->jsonScanned = 0;
    }

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
    // Pictures ride in the same stream and contain zero bytes. QString::fromLatin1(QByteArray) stops at the first one,
    // which hid every event that came after a picture, so the length is given explicitly.
    const QString text = QString::fromLatin1(c->buffer.constData(), c->buffer.size());
    QRegularExpressionMatchIterator it = eventRx.globalMatch(text);
    while (it.hasNext()) {
        const QRegularExpressionMatch m = it.next();
        if (c->pendingValid && m.capturedStart() > consumed)
            judgePicture(c, c->buffer.mid(consumed, m.capturedStart() - consumed)); // a picture that rode in before this event
        c->pendingValid = false; // each event brings its own picture, or none
        consumed = m.capturedEnd();
        const QString body = m.captured(0);
        const QString type = typeRx.match(body).captured(1);
        const QString camTime = timeRx.match(body).captured(1);
        const int camChannel = chanRx.match(body).captured(1).toInt();
        if (!sourceAllowed(c, camChannel))
            continue; // this camera's reports are taken from the other connection (the camera's own, or the recorder's)
        if (type != QLatin1String("VMD")) {
            // A smart event (line crossing, intrusion, region entrance or exit...). The camera names
            // the target inside the rule. All of them go to the detection log and show the tile's
            // detection frame with that target, like a labelled motion report.
            const QString kind = vcaKind(type);
            if (kind.isEmpty()) {
                logOtherEvent(c, type, stateRx.match(body).captured(1), camTime, camChannel, body);
                continue;
            }
            if (!kind.isEmpty() && stateRx.match(body).captured(1) == QLatin1String("active")) {
                QString t = vcaTargetRx.match(body).captured(1).trimmed().toLower();
                if (!t.isEmpty() && t != QLatin1String("human") && t != QLatin1String("vehicle") && t != QLatin1String("animal"))
                    t = QStringLiteral("other");
                logDetection(c, t, kind, camTime, camChannel, eventWhere(body)); // the log keeps every labelled report
                notePictureRect(c, body, camChannel, camTime, kind);
                if (t.isEmpty())
                    t = QStringLiteral("other");
                // The settings can switch kinds and targets off for the screen: no frame for those.
                if (!m_allowedKinds.contains(vcaKey(type)) || !m_allowedTargets.contains(t))
                    continue;
                qDebug() << "[Events]" << kind << "from" << ip << "channel" << camChannel << ":" << t;
                emit targetDetected(ip, t, vcaShort(type), camChannel);
            }
            continue;
        }
        QString target = targetRx.match(body).captured(1).trimmed().toLower();
        if (target.isEmpty()) {
            // Plain motion: the camera says something moved, not what. A recorder repeats it about once a second while
            // the movement goes on, so one line is written when a movement starts, and the next only after it has been
            // still for kMotionQuietMs.
            const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
            const QString motionKey = ip + QLatin1Char('|') + QString::number(camChannel);
            const qint64 lastMs = m_motionSeen.value(motionKey, 0);
            m_motionSeen.insert(motionKey, nowMs);
            if (m_logUnlabelledMotion && nowMs - lastMs >= kMotionQuietMs)
                logDetection(c, QString(), QStringLiteral("Motion"), camTime, camChannel);
            if (m_allowedKinds.contains(QStringLiteral("motion"))) {
                if (m_frameUnlabelledMotion && m_allowedTargets.contains(QStringLiteral("other")))
                    emit targetDetected(ip, QStringLiteral("other"), QStringLiteral("MOTION"), camChannel); // shows "MOTION"
                else
                    emit motionDetected(ip, camChannel); // only keeps a frame that is already shown
            }
            continue;
        }
        if (target != QLatin1String("human") && target != QLatin1String("vehicle") && target != QLatin1String("animal"))
            target = QStringLiteral("other");
        logDetection(c, target, QStringLiteral("Motion"), camTime, camChannel); // the log keeps every labelled report
        {
            // Motion is not a smart event and brings no picture of its own, so a still is asked for from the camera.
            const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
            const QString picKey = ip + QLatin1Char('|') + QString::number(camChannel);
            if (nowMs - m_motionPictureAt.value(picKey, 0) >= kMotionPictureGapMs) {
                m_motionPictureAt.insert(picKey, nowMs);
                QDateTime when = QDateTime::fromString(camTime, Qt::ISODate);
                if (!when.isValid())
                    when = QDateTime::currentDateTime();
                takeSnapshot(ip, camChannel > 0 ? camChannel : 1, when.toSecsSinceEpoch(), QStringLiteral("Motion"));
            }
        }
        if (!m_allowedKinds.contains(QStringLiteral("motion")) || !m_allowedTargets.contains(target))
            continue; // motion, or this target, is switched off for the screen
        qDebug() << "[Events] report from" << ip << "channel" << camChannel << ":" << target;
        emit targetDetected(ip, target, QStringLiteral("MOTION"), camChannel);
    }
    // A PTZ camera also sends JSON messages in the same stream. Two of them say it is following a target: it "leaves"
    // its park preset, then reports where it points about once a second, then is back ("inPointion"). The same message
    // may be seen again on the next read; the state they set is the same each time, so that does no harm.
    static const QRegularExpression presetRx(QStringLiteral(
        "\"channelID\":\\s*(\\d+),[\\s\\S]{0,160}?\"eventType\":\\s*\"presetSwitchingInformation\"[\\s\\S]{0,260}?\"switchStatus\":\\s*\"([^\"]*)\""));
    static const QRegularExpression gisRx(QStringLiteral(
        "\"channelID\":\\s*(\\d+),[\\s\\S]{0,160}?\"eventType\":\\s*\"GISInfo\""));
    if (text.contains(QLatin1String("presetSwitchingInformation")) || text.contains(QLatin1String("GISInfo"))) {
        // Each message is acted on once: only matches that end after what was searched before count.
        int scannedTo = c->jsonScanned;
        QRegularExpressionMatchIterator pi = presetRx.globalMatch(text, qMax(0, c->jsonScanned - 300));
        while (pi.hasNext()) {
            const QRegularExpressionMatch pm = pi.next();
            if (pm.capturedEnd() <= c->jsonScanned)
                continue;
            scannedTo = qMax(scannedTo, int(pm.capturedEnd()));
            emit trackingChanged(ip, pm.captured(1).toInt(), pm.captured(2) == QLatin1String("leave"));
        }
        QRegularExpressionMatchIterator gi = gisRx.globalMatch(text, qMax(0, c->jsonScanned - 300));
        while (gi.hasNext()) {
            const QRegularExpressionMatch gm = gi.next();
            if (gm.capturedEnd() <= c->jsonScanned)
                continue;
            scannedTo = qMax(scannedTo, int(gm.capturedEnd()));
            emit ptzMoved(ip, gm.captured(1).toInt());
        }
        c->jsonScanned = scannedTo;
    }
    if (consumed > 0) {
        c->buffer.remove(0, consumed);
        c->jsonScanned = qMax(0, c->jsonScanned - consumed);
    }
    judgePicture(c, c->buffer);
}

void HikvisionEvents::notePictureRect(Conn *c, const QString &body, int eventChannel, const QString &cameraTime, const QString &kind)
{
    static const QRegularExpression rectRx(QStringLiteral(
        "<TargetRect>\\s*<X>([\\d.]+)</X>\\s*<Y>([\\d.]+)</Y>\\s*<width>([\\d.]+)</width>\\s*<height>([\\d.]+)</height>"));
    static const QRegularExpression picRx(QStringLiteral("<detectionPicturesNumber>(\\d+)</detectionPicturesNumber>"));
    c->pendingValid = false;
    c->pendingHasRect = false;
    if (picRx.match(body).captured(1).toInt() < 1)
        return; // this event brings no picture
    QDateTime when = QDateTime::fromString(cameraTime, Qt::ISODate);
    if (!when.isValid())
        when = QDateTime::currentDateTime();
    c->pendingSecs = when.toSecsSinceEpoch();
    c->pendingAddress = cameraAddress(c, eventChannel);
    c->pendingLens = pictureLens(c, eventChannel);
    c->pendingKind = kind;
    const QRegularExpressionMatch m = rectRx.match(body);
    if (m.hasMatch()) {
        c->pendingRect = QRectF(m.captured(1).toDouble(), m.captured(2).toDouble(), m.captured(3).toDouble(), m.captured(4).toDouble());
        c->pendingHasRect = true;
    }
    // A recorder sends a link (bkgUrl) in place of the picture; a camera attaches the picture to the stream.
    static const QRegularExpression urlRx(QStringLiteral("<bkgUrl>([^<]*)</bkgUrl>"));
    const QString link = urlRx.match(body).captured(1).replace(QStringLiteral("&amp;"), QStringLiteral("&")).trimmed();
    if (!link.isEmpty()) {
        fetchPicture(c->ip, QUrl(link), c->pendingAddress, c->pendingLens, c->pendingKind, c->pendingSecs, c->pendingHasRect, c->pendingRect);
        return; // nothing will follow on the stream
    }
    c->pendingValid = true;
}

QString HikvisionEvents::cameraAddress(const Conn *c, int eventChannel) const
{
    if (c->recorderMode) {
        const auto it = c->chanInfo.constFind(eventChannel);
        if (it != c->chanInfo.constEnd() && !it->ip.isEmpty())
            return it->ip;
    }
    return c->ip;
}

namespace {
// A pixel of the red the camera draws its target frame in.
inline bool frameRed(QRgb p)
{
    return qRed(p) > 150 && qRed(p) - qGreen(p) > 90 && qRed(p) - qBlue(p) > 90;
}
// The share of one edge of a box that has frame red on it, allowing a few pixels of slack either way.
double edgeShare(const QImage &img, int x0, int y0, int x1, int y1, bool horizontal)
{
    const int n = horizontal ? x1 - x0 : y1 - y0;
    if (n <= 0)
        return 0;
    int hit = 0;
    for (int i = 0; i < n; ++i) {
        bool found = false;
        for (int d = -6; d <= 6 && !found; ++d) {
            const int x = qBound(0, horizontal ? x0 + i : x0 + d, img.width() - 1);
            const int y = qBound(0, horizontal ? y0 + d : y0 + i, img.height() - 1);
            found = frameRed(img.pixel(x, y));
        }
        if (found)
            ++hit;
    }
    return double(hit) / n;
}
}

bool HikvisionEvents::judgePicture(Conn *c, const QByteArray &data)
{
    if (!c->pendingValid)
        return false;
    const int start = data.indexOf("\xff\xd8\xff");
    if (start < 0)
        return false;
    const int end = data.indexOf("\xff\xd9", start + 2);
    if (end < 0)
        return false; // the rest of the picture is still on its way
    c->pendingValid = false;
    const QByteArray jpeg = data.mid(start, end + 2 - start);
    savePicture(c->pendingAddress, c->pendingLens, c->pendingKind, c->pendingSecs, jpeg);
    judgeJpeg(c->pendingAddress, c->pendingHasRect, c->pendingRect, jpeg);
    return true;
}

// 1 when the picture has the camera's red outline on the rectangle, 0 when it has none, -1 when it cannot be told.
static int frameVerdict(const QImage &image, const QRectF &r)
{
    if (image.isNull())
        return -1;
    const QImage img = image.convertToFormat(QImage::Format_RGB32);
    const int x0 = int(r.x() * img.width()), y0 = int(r.y() * img.height());
    const int x1 = int((r.x() + r.width()) * img.width()), y1 = int((r.y() + r.height()) * img.height());
    if (x1 - x0 < 16 || y1 - y0 < 16)
        return -1;
    const double sides[4] = { edgeShare(img, x0, y0, x1, y1, true), edgeShare(img, x0, y1, x1, y1, true),
                              edgeShare(img, x0, y0, x1, y1, false), edgeShare(img, x1, y0, x1, y1, false) };
    int strong = 0, none = 0;
    for (double s : sides) {
        if (s >= 0.8)
            ++strong;
        if (s < 0.2)
            ++none;
    }
    return strong >= 3 ? 1 : (none == 4 ? 0 : -1);
}

int HikvisionEvents::pictureHasFrame(const QString &path, double x, double y, double w, double h) const
{
    QImage img;
    if (path.isEmpty() || !img.load(path))
        return -1;
    return frameVerdict(img, QRectF(x, y, w, h));
}

void HikvisionEvents::judgeJpeg(const QString &address, bool hasRect, const QRectF &r, const QByteArray &jpeg)
{
    if (address.isEmpty())
        return;
    if (!hasRect)
        return;
    QImage img;
    if (!img.loadFromData(jpeg, "JPG") || img.isNull())
        return;
    img = img.convertToFormat(QImage::Format_RGB32);
    const int x0 = int(r.x() * img.width()), y0 = int(r.y() * img.height());
    const int x1 = int((r.x() + r.width()) * img.width()), y1 = int((r.y() + r.height()) * img.height());
    if (x1 - x0 < 16 || y1 - y0 < 16)
        return; // too small to tell apart from the scene
    // The frame is a thin red outline on the rectangle the report names. Three sides are enough, because
    // the camera can draw part of an edge outside the picture.
    const double sides[4] = { edgeShare(img, x0, y0, x1, y1, true), edgeShare(img, x0, y1, x1, y1, true),
                              edgeShare(img, x0, y0, x1, y1, false), edgeShare(img, x1, y0, x1, y1, false) };
    int strong = 0, none = 0;
    for (double s : sides) {
        if (s >= 0.8)
            ++strong;
        if (s < 0.2)
            ++none;
    }
    if (strong >= 3 || none == 4) {
        PictureVerdict v;
        v.on = strong >= 3;
        v.when = QDateTime::currentDateTime();
        m_pictures.insert(address, v);
    }
}

void HikvisionEvents::fetchPicture(const QString &ip, const QUrl &url, const QString &address, int lens, const QString &kind, qint64 secs, bool hasRect, const QRectF &rect)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->pictureRefused || c->pictureFetches >= 2 || address.isEmpty())
        return;
    // Only ever send the login to the device this connection belongs to.
    if (url.scheme() != QLatin1String("http") || url.host() != c->ip.section(QLatin1Char(':'), 0, 0).trimmed())
        return;
    if (QFile::exists(picturePath(QFileInfo(m_logDir).absolutePath(), address, secs, lens, kind)) && !m_logDir.isEmpty())
        return; // already have this one
    ++c->pictureFetches;
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
    QNetworkReply *reply = m_net->get(req);
    reply->setProperty("evUser", c->user);
    reply->setProperty("evPass", c->pass);
    connect(reply, &QNetworkReply::finished, this, [this, ip, reply, address, lens, kind, secs, hasRect, rect]() {
        reply->deleteLater();
        Conn *conn = m_conns.value(ip, nullptr);
        if (conn && conn->pictureFetches > 0)
            --conn->pictureFetches;
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 401 || status == 403 || reply->error() == QNetworkReply::AuthenticationRequiredError) {
            if (conn)
                conn->pictureRefused = true; // one refused login is enough: a wrong password could lock the recorder
            qWarning() << "[Events]" << ip << "refused the login for an event picture. Not asking again.";
            return;
        }
        if (reply->error() != QNetworkReply::NoError)
            return;
        const QByteArray jpeg = reply->readAll();
        if (jpeg.size() < 1000 || jpeg.left(3) != QByteArray("\xff\xd8\xff", 3))
            return;
        savePicture(address, lens, kind, secs, jpeg);
        judgeJpeg(address, hasRect, rect, jpeg);
    });
}

QString HikvisionEvents::pictureKey(const QString &address, int lens)
{
    QString a = address;
    a.replace(QRegularExpression(QStringLiteral("[^0-9A-Za-z.-]")), QStringLiteral("_"));
    if (lens > 0)
        a += QStringLiteral("_ch") + QString::number(lens);
    return a;
}

QString HikvisionEvents::picturePath(const QString &configDir, const QString &address, qint64 secs, int lens, const QString &kind)
{
    QString slug;
    for (const QChar ch : kind.toLower())
        if (ch.isLetterOrNumber() && ch.unicode() < 128)
            slug += ch;
    return configDir + QStringLiteral("/logs/pictures/") + pictureKey(address, lens) + QLatin1Char('_') + QString::number(secs)
           + (slug.isEmpty() ? QString() : QLatin1Char('-') + slug) + QStringLiteral(".jpg");
}

// The lens this event came from, as the recorder channel of that lens, when the camera has more than one lens at
// one address (a PTZ with a close-up and a wide view); 0 for an ordinary camera. Both lenses would otherwise share
// one picture name and could overwrite each other in the same second.
int HikvisionEvents::pictureLens(const Conn *c, int eventChannel) const
{
    if (c->recorderMode) {
        const auto it = c->chanInfo.constFind(eventChannel);
        if (it == c->chanInfo.constEnd() || it->ip.isEmpty())
            return 0;
        int same = 0;
        for (auto i = c->chanInfo.constBegin(); i != c->chanInfo.constEnd(); ++i)
            if (i->ip == it->ip)
                ++same;
        return same > 1 ? eventChannel : 0;
    }
    if (c->lens.size() > 1) {
        const auto it = c->lens.constFind(eventChannel);
        if (it != c->lens.constEnd() && it->channel > 0)
            return it->channel;
    }
    return 0;
}

void HikvisionEvents::savePicture(const QString &address, int lens, const QString &kind, qint64 secs, const QByteArray &jpeg)
{
    if (m_logDir.isEmpty() || address.isEmpty() || jpeg.size() < 1000)
        return;
    const QString dirPath = m_logDir + QStringLiteral("/pictures");
    QDir().mkpath(dirPath);
    QFile f(picturePath(QFileInfo(m_logDir).absolutePath(), address, secs, lens, kind));
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning() << "[Events] cannot write" << f.fileName() << f.errorString();
        return;
    }
    f.write(jpeg);
    f.close();
    prunePictures(dirPath, pictureKey(address, lens));
}

// Keeps the newest m_maxPictures pictures of each camera (or lens) - all of them when key is empty - and deletes the
// older ones, so a busy camera cannot push out the pictures of a quiet one and the folder cannot grow without end.
void HikvisionEvents::prunePictures(const QString &dirPath, const QString &key)
{
    const QFileInfoList files = QDir(dirPath).entryInfoList(QStringList() << QStringLiteral("*.jpg"), QDir::Files, QDir::Time);
    QHash<QString, int> seen;
    for (const QFileInfo &fi : files) {
        const QString name = fi.completeBaseName();
        const int us = name.lastIndexOf(QLatin1Char('_'));
        if (us <= 0)
            continue;
        const QString cam = name.left(us);
        if (!key.isEmpty() && cam != key)
            continue;
        // Motion pictures are counted apart from the smart-event ones, and kept fewer.
        const bool motion = name.endsWith(QLatin1String("-motion"));
        const int limit = motion ? qMax(10, m_maxPictures / 4) : m_maxPictures;
        if (++seen[motion ? cam + QLatin1String("|motion") : cam] > limit)
            QFile::remove(fi.absoluteFilePath());
    }
}

void HikvisionEvents::setMaxPictures(int count)
{
    m_maxPictures = qBound(10, count, 10000);
    if (!m_logDir.isEmpty())
        prunePictures(m_logDir + QStringLiteral("/pictures"), QString());
}

QVariantMap HikvisionEvents::pictureFrames(const QString &address) const
{
    QVariantMap m;
    const auto it = m_pictures.constFind(address);
    if (it == m_pictures.constEnd())
        return m;
    m.insert(QStringLiteral("state"), it->on ? QStringLiteral("on") : QStringLiteral("off"));
    m.insert(QStringLiteral("time"), QLocale::c().toString(it->when, QStringLiteral("HH:mm:ss")));
    return m;
}

QVariantMap HikvisionEvents::savedPictureFrames(const QString &address, const QString &configDir) const
{
    QVariantMap m;
    if (address.isEmpty() || configDir.isEmpty())
        return m;
    QFile f(configDir + QStringLiteral("/logs/Detection.log"));
    if (!f.open(QIODevice::ReadOnly))
        return m;
    // Only the end of the log is needed: the newest pictures.
    const qint64 tail = 4 * 1024 * 1024;
    if (f.size() > tail)
        f.seek(f.size() - tail);
    const QList<QByteArray> lines = f.readAll().split('\n');
    static const QRegularExpression boxRx(QStringLiteral("\\bbox ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)"));
    static const QRegularExpression recRx(QStringLiteral("\\brecorder \\S+ ch (\\d+)"));
    const QString needle = QStringLiteral(", ") + address + QStringLiteral(", ");
    int judged = 0;
    for (int i = lines.size() - 1; i >= 0 && judged < 40; --i) {
        const QString line = QString::fromUtf8(lines.at(i));
        if (!line.contains(needle))
            continue;
        const QStringList parts = line.split(QStringLiteral(", "));
        if (parts.size() < 5)
            continue;
        const QString kind = parts.at(2);
        if (kind == QLatin1String("Motion") || kind == QLatin1String("Tracking"))
            continue; // plain motion has no rule frame, and Tracking shows the camera's own box
        const QRegularExpressionMatch bm = boxRx.match(line);
        if (!bm.hasMatch())
            continue; // nothing to look for
        const QDateTime when = QLocale::c().toDateTime(parts.at(0), QStringLiteral("dd MMM yyyy HH:mm:ss"));
        if (!when.isValid())
            continue;
        const qint64 secs = when.toMSecsSinceEpoch() / 1000;
        const QRegularExpressionMatch rm = recRx.match(line);
        const int channel = rm.hasMatch() ? rm.captured(1).toInt() : 0;
        const QString tries[4] = { picturePath(configDir, address, secs, channel, kind), picturePath(configDir, address, secs, 0, kind),
                                   picturePath(configDir, address, secs, channel), picturePath(configDir, address, secs) };
        QString pic;
        for (const QString &t : tries) {
            if (QFile::exists(t)) {
                pic = t;
                break;
            }
        }
        if (pic.isEmpty())
            continue;
        ++judged;
        const int v = pictureHasFrame(pic, bm.captured(1).toDouble(), bm.captured(2).toDouble(), bm.captured(3).toDouble(), bm.captured(4).toDouble());
        if (v < 0)
            continue;
        m.insert(QStringLiteral("state"), v == 1 ? QStringLiteral("on") : QStringLiteral("off"));
        m.insert(QStringLiteral("time"), QLocale::c().toString(when, QStringLiteral("d MMM yyyy HH:mm:ss")));
        return m;
    }
    return m;
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
    c->watchdog->stop();
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
    // This device has no event stream at all (a doorbell, for example): asking again will never help.
    if (httpStatus == 404 || httpStatus == 405 || httpStatus == 501) {
        c->unsupported = true;
        qWarning() << "[Events]" << ip << "has no detection stream (HTTP" << httpStatus << "). Not trying again.";
        emit listenFailed(ip, tr("This device does not offer detection events."));
        return;
    }
    // The camera closed the stream, the network dropped or it went quiet: reopen it, waiting a little longer each
    // time (2, 4, 8, 16, then 30 seconds) for as long as a tile watches. A lost login is the only thing that stops
    // this, because a wrong password is what can lock a camera.
    ++c->failures;
    if (c->failures == kMaxFailures) {
        qWarning() << "[Events]" << ip << "has failed" << c->failures << "times in a row. It will keep trying.";
        emit listenFailed(ip, tr("Could not listen to this camera's detection events."));
    }
    c->retry->start(retryDelayMs(c->failures));
}

// One line per labelled report, in the order they arrive:
//   10 Nov 2026 08:52:24, Human detected, Motion, Camera_Name, 192.0.0.3, recorder 192.0.0.99 ch 17
//   10 Nov 2026 08:53:10, Vehicle detected, Line crossing, Camera_Name, 192.0.0.3, recorder 192.0.0.99 ch 17
// The time is the camera's own time for the event, shown in this computer's time zone. When KVision
// only read the report 10 seconds or more after the camera made it (for example after a stall), the
// line ends with ", received HH:mm:ss". Plain motion reports carry no target type and are not logged.
QString HikvisionEvents::eventWhere(const QString &body)
{
    static const QRegularExpression rectRx(QStringLiteral(
        "<TargetRect>\\s*<X>([\\d.]+)</X>\\s*<Y>([\\d.]+)</Y>\\s*<width>([\\d.]+)</width>\\s*<height>([\\d.]+)</height>"));
    static const QRegularExpression zoneRx(QStringLiteral("<regionID>(\\d+)</regionID>"));
    static const QRegularExpression listRx(QStringLiteral("<RegionCoordinatesList>(.*?)</RegionCoordinatesList>"),
                                           QRegularExpression::DotMatchesEverythingOption);
    static const QRegularExpression ptRx(QStringLiteral("<positionX>(\\d+)</positionX>\\s*<positionY>(\\d+)</positionY>"));
    QStringList out;
    const QRegularExpressionMatch r = rectRx.match(body);
    if (r.hasMatch())
        out << QStringLiteral("box %1/%2/%3/%4").arg(r.captured(1), r.captured(2), r.captured(3), r.captured(4));
    const QRegularExpressionMatch z = zoneRx.match(body);
    if (z.hasMatch())
        out << QStringLiteral("zone %1").arg(z.captured(1));
    const QRegularExpressionMatch l = listRx.match(body);
    if (l.hasMatch()) {
        // The zone's corners are given on a 0..1000 scale; they are kept as 0..1 of the picture.
        QStringList pts;
        QRegularExpressionMatchIterator it = ptRx.globalMatch(l.captured(1));
        while (it.hasNext()) {
            const QRegularExpressionMatch m = it.next();
            pts << QString::number(m.captured(1).toInt() / 1000.0, 'f', 3) << QString::number(m.captured(2).toInt() / 1000.0, 'f', 3);
        }
        if (pts.size() >= 4)
            out << QStringLiteral("poly %1").arg(pts.join(QLatin1Char('/')));
    }
    return out.join(QLatin1Char(' '));
}

void HikvisionEvents::logDetection(const Conn *c, const QString &target, const QString &kind, const QString &cameraTime, int eventChannel,
                                   const QString &where)
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
        const int ch = ((c->recIp == c->ip || c->recorderMode) && eventChannel > 0) ? eventChannel : c->recChannel;
        if (ch > 0)
            recorder = QStringLiteral(", recorder ") + c->recIp + QStringLiteral(" ch ") + QString::number(ch);
    }
    QString name = c->name.isEmpty() ? c->ip : c->name;
    QString address = c->ip;
    if (!c->recorderMode) {
        // A camera with several lenses reports each lens as its own channel on the one stream.
        const auto lens = c->lens.constFind(eventChannel);
        if (lens != c->lens.constEnd()) {
            if (!lens->name.isEmpty())
                name = lens->name;
            if (lens->channel > 0 && !c->recIp.isEmpty())
                recorder = QStringLiteral(", recorder ") + c->recIp + QStringLiteral(" ch ") + QString::number(lens->channel);
        }
    }
    if (c->recorderMode) {
        // One connection serves every camera behind the recorder, so the report's channel says which one.
        const auto it = c->chanInfo.constFind(eventChannel);
        name = (it != c->chanInfo.constEnd() && !it->name.isEmpty()) ? it->name : QStringLiteral("%1 Ch. %2").arg(c->ip).arg(eventChannel);
        if (it != c->chanInfo.constEnd() && !it->ip.isEmpty())
            address = it->ip;
    }
    // The last item says which device this report, and the picture that goes with it, came from: the camera's own connection,
    // or the recorder's (a recorder's picture is fetched from the recorder).
    const QString via = c->recorderMode ? QStringLiteral(", via NVR") : QStringLiteral(", via camera");
    QTextStream(&f) << when << ", " << what << " detected, " << kind << ", " << name << ", " << address << recorder << late << (where.isEmpty() ? QString() : QStringLiteral(", ") + where) << via << "\n";
}

void HikvisionEvents::logOtherEvent(const Conn *c, const QString &type, const QString &state, const QString &cameraTime,
                                    int eventChannel, const QString &body)
{
    if (m_logDir.isEmpty() || type.isEmpty())
        return;
    // A camera's heartbeat is a "videoloss" report that says inactive, every ten seconds or so. It is not an event.
    if (type.compare(QLatin1String("heartBeat"), Qt::CaseInsensitive) == 0
        || (type == QLatin1String("videoloss") && state != QLatin1String("active")))
        return;
    // Types that are seen all the time and tell nothing new: "IO" (an input port changed) and "duration" (the follow-up
    // to a field detection that is already logged). Add a type here to leave it out of the log.
    static const QStringList ignored = {QStringLiteral("IO"), QStringLiteral("duration")};
    for (const QString &skip : ignored) {
        if (type.compare(skip, Qt::CaseInsensitive) == 0)
            return;
    }

    const QString key = c->ip + QLatin1Char('|') + QString::number(eventChannel) + QLatin1Char('|') + type;
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const auto seen = m_otherSeen.constFind(key);
    if (seen != m_otherSeen.constEnd() && seen->first == state && nowMs - seen->second < 600000)
        return;
    m_otherSeen.insert(key, qMakePair(state, nowMs));

    QString name = c->name.isEmpty() ? c->ip : c->name;
    if (c->recorderMode) {
        const auto it = c->chanInfo.constFind(eventChannel);
        name = (it != c->chanInfo.constEnd() && !it->name.isEmpty()) ? it->name : QStringLiteral("%1 Ch. %2").arg(c->ip).arg(eventChannel);
    } else {
        const auto lens = c->lens.constFind(eventChannel);
        if (lens != c->lens.constEnd() && !lens->name.isEmpty())
            name = lens->name;
    }

    QDir().mkpath(m_logDir);
    const QString path = m_logDir + QStringLiteral("/OtherEvents.log");
    if (QFileInfo(path).size() > 2 * 1024 * 1024) { // keep it small: one older copy
        QFile::remove(m_logDir + QStringLiteral("/OtherEvents.old.log"));
        QFile::rename(path, m_logDir + QStringLiteral("/OtherEvents.old.log"));
    }
    QFile f(path);
    if (!f.open(QIODevice::Append | QIODevice::Text))
        return;
    const QString when = QLocale::c().toString(QDateTime::currentDateTime(), QStringLiteral("dd MMM yyyy HH:mm:ss"));
    QTextStream(&f) << when << ", Unrecognised event, " << type << " (" << (state.isEmpty() ? QStringLiteral("no state") : state)
                    << "), " << name << ", " << c->ip << ", channel " << eventChannel
                    << (cameraTime.isEmpty() ? QString() : QStringLiteral(", camera time ") + cameraTime)
                    << ", message: " << body.simplified().left(700) << "\n";
}

// One line each time a tile shows a detection frame (a camera shown on two tiles gives two lines):
//   10 Nov 2026 08:52:24, Frame shown, HUMAN - LINE, tile 19, Camera_Name, 192.0.0.3
void HikvisionEvents::logFrame(const QString &ip, const QString &text, int tile, const QString &name)
{
    if (m_logDir.isEmpty())
        return;
    QDir().mkpath(m_logDir);
    QFile f(m_logDir + QStringLiteral("/Frames.log"));
    if (!f.open(QIODevice::Append | QIODevice::Text))
        return;
    const Conn *c = m_conns.value(ip, nullptr);
    const QString when = QLocale::c().toString(QDateTime::currentDateTime(), QStringLiteral("dd MMM yyyy HH:mm:ss"));
    QTextStream(&f) << when << ", Frame shown, " << text << ", tile " << tile << ", " << (!name.isEmpty() ? name : (c && !c->name.isEmpty() ? c->name : ip)) << ", " << ip << "\n";
}

QVariantMap HikvisionEvents::readDetections(int skip, int count, const QString &configDir, const QString &filterIp,
                                            qint64 fromMs, qint64 toMs, const QString &target, const QString &kinds,
                                            bool hideUnlabelledMotion) const
{
    QVariantMap result;
    QVariantList entries;
    bool more = false;
    const QString wantTarget = target.trimmed().toLower();
    // No type chosen means every kind of event, including plain labelled motion (motion has no picture).
    // Choosing "Motion" lists only those.
    const QStringList wantKinds = splitList(kinds);
    const bool filtering = true;
    int total = 0;
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
        while (pos > 0 && (filtering || data.count('\n') <= need)) {
            const qint64 start = qMax<qint64>(0, pos - block);
            f.seek(start);
            data.prepend(f.read(pos - start));
            pos = start;
            if (fromMs > 0 && pos > 0) {
                // The log is in time order: once its oldest complete line is before the range, nothing older is wanted.
                const int nl = data.indexOf('\n');
                if (nl >= 0) {
                    const QDateTime first = QLocale::c().toDateTime(QString::fromUtf8(data.mid(nl + 1, 20)), QStringLiteral("dd MMM yyyy HH:mm:ss"));
                    if (first.isValid() && first.toMSecsSinceEpoch() < fromMs)
                        break;
                }
            }
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
            QString source; // "camera" or "NVR": where the picture came from (lines written before this was recorded have none)
            if (!parts.isEmpty() && parts.last().startsWith(QStringLiteral("via "))) {
                source = parts.takeLast().mid(4);
                if (source != QLatin1String("camera") && source != QLatin1String("NVR"))
                    source.clear();
            }
            QString where;
            if (!parts.isEmpty() && (parts.last().startsWith(QStringLiteral("box ")) || parts.last().startsWith(QStringLiteral("zone ")) || parts.last().startsWith(QStringLiteral("poly "))))
                where = parts.takeLast();
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
            e.insert(QStringLiteral("source"), source);
            {
                // "box x/y/w/h zone N poly x/y/..." as lists the window can use (all 0..1 of the picture)
                QVariantList box, poly;
                int zone = 0;
                QStringList tok;
                for (const QString &item : where.split(QLatin1Char(' ')))
                    if (!item.isEmpty())
                        tok << item;
                for (int i = 0; i + 1 < tok.size(); i += 2) {
                    if (tok.at(i) == QLatin1String("zone")) {
                        zone = tok.at(i + 1).toInt();
                    } else if (tok.at(i) == QLatin1String("box") || tok.at(i) == QLatin1String("poly")) {
                        QVariantList &dst = tok.at(i) == QLatin1String("box") ? box : poly;
                        for (const QString &n : tok.at(i + 1).split(QLatin1Char('/')))
                            dst.append(n.toDouble());
                    }
                }
                e.insert(QStringLiteral("box"), box);
                e.insert(QStringLiteral("poly"), poly);
                e.insert(QStringLiteral("zone"), zone);
            }
            e.insert(QStringLiteral("recorderIp"), recorderIp);
            e.insert(QStringLiteral("channel"), channel);
            const QDateTime when = QLocale::c().toDateTime(e.value(QStringLiteral("time")).toString(), QStringLiteral("dd MMM yyyy HH:mm:ss"));
            e.insert(QStringLiteral("epochMs"), when.isValid() ? when.toMSecsSinceEpoch() : qint64(0));
            if (when.isValid()) // shown as "9 Nov 2026 08:52:24"; the log file itself keeps its own format
                e.insert(QStringLiteral("time"), QLocale::c().toString(when, QStringLiteral("d MMM yyyy HH:mm:ss")));
            if (!filterIp.isEmpty() && e.value(QStringLiteral("ip")).toString() != filterIp)
                continue;
            {
                const qint64 when2 = e.value(QStringLiteral("epochMs")).toLongLong();
                if ((fromMs > 0 && when2 < fromMs) || (toMs > 0 && when2 > toMs))
                    continue;
                const QString kindNow = e.value(QStringLiteral("kind")).toString();
                if (!wantKinds.isEmpty() && !wantKinds.contains(kindNow))
                    continue;
                if (hideUnlabelledMotion && kindNow == QLatin1String("Motion")
                    && e.value(QStringLiteral("target")).toString().compare(QLatin1String("Object"), Qt::CaseInsensitive) == 0)
                    continue;
                if (!wantTarget.isEmpty()) {
                    QString tg = e.value(QStringLiteral("target")).toString().toLower();
                    if (tg == QLatin1String("object"))
                        tg = QStringLiteral("other");
                    if (tg != wantTarget)
                        continue;
                }
            }
            ++total;
            if (skip > 0) {
                --skip;
                continue;
            }
            if (entries.size() >= count) {
                more = true;
                if (filtering)
                    continue; // keep counting for the total, without looking for pictures
                break;
            }
            {
                const qint64 ms = e.value(QStringLiteral("epochMs")).toLongLong();
                const QString picIp = e.value(QStringLiteral("ip")).toString();
                const QString kindText = e.value(QStringLiteral("kind")).toString();
                QString pic;
                if (ms > 0) {
                    // This event's own picture first (named with its kind), then the older names without it.
                    const QString tries[4] = { picturePath(configDir, picIp, ms / 1000, channel > 0 ? channel : 0, kindText),
                                               picturePath(configDir, picIp, ms / 1000, 0, kindText),
                                               picturePath(configDir, picIp, ms / 1000, channel > 0 ? channel : 0),
                                               picturePath(configDir, picIp, ms / 1000) };
                    for (const QString &t : tries) {
                        if (QFile::exists(t)) {
                            pic = t;
                            break;
                        }
                    }
                }
                QStringList all;
                if (e.value(QStringLiteral("kind")).toString() == QLatin1String("Tracking") && ms > 0) {
                    // The snapshots are named by the seconds from the line's own second to three seconds after it.
                    for (qint64 sec = ms / 1000; sec <= ms / 1000 + 3; ++sec) {
                        const QString one = picturePath(configDir, picIp, sec, channel > 0 ? channel : 0);
                        if (QFile::exists(one))
                            all << one;
                    }
                    if (!all.isEmpty())
                        pic = all.first();
                }
                if (all.isEmpty() && !pic.isEmpty() && QFile::exists(pic))
                    all << pic;
                e.insert(QStringLiteral("pictures"), all);
                e.insert(QStringLiteral("picture"), (!pic.isEmpty() && QFile::exists(pic)) ? pic : QString());
            }
            entries.append(e);
        }
    }
    result.insert(QStringLiteral("total"), filtering ? total : -1);
    result.insert(QStringLiteral("entries"), entries);
    result.insert(QStringLiteral("more"), more);
    return result;
}

void HikvisionEvents::setAllowedKinds(const QString &kinds)
{
    m_allowedKinds.clear();
    const QStringList parts = splitList(kinds);
    for (const QString &p : parts)
        m_allowedKinds.insert(p.trimmed().toLower());
}

bool HikvisionEvents::sourceAllowed(const Conn *c, int eventChannel) const
{
    // A camera with its own address (a standalone camera, or one called without recorder details): its own stream is the only one.
    if (!c->recorderMode && (c->recIp.isEmpty() || c->recIp == c->ip))
        return true;
    int channel = eventChannel; // on a recorder's connection the report names the recorder channel
    if (!c->recorderMode) {
        // On a camera's own connection the camera is always channel 1 (or a lens number): the recorder channel is looked up.
        const auto lens = c->lens.constFind(eventChannel);
        channel = (lens != c->lens.constEnd() && lens->channel > 0) ? lens->channel : c->recChannel;
    }
    const QString key = c->recIp + QLatin1Char('#') + QString::number(channel);
    const QString wanted = m_sourceOverrides.value(key, m_defaultSource);
    return c->recorderMode ? wanted == QLatin1String("recorder") : wanted != QLatin1String("recorder");
}

void HikvisionEvents::setChannelSources(const QString &overridesJson, const QString &defaultSource)
{
    m_sourceOverrides.clear();
    const QJsonObject o = QJsonDocument::fromJson(overridesJson.toUtf8()).object();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        const QString v = it.value().toString();
        if (v == QLatin1String("camera") || v == QLatin1String("recorder"))
            m_sourceOverrides.insert(it.key(), v);
    }
    m_defaultSource = defaultSource == QLatin1String("recorder") ? defaultSource : QStringLiteral("camera");
}

void HikvisionEvents::setUnlabelledMotion(bool log, bool frame)
{
    m_logUnlabelledMotion = log;
    m_frameUnlabelledMotion = frame;
}

void HikvisionEvents::setAllowedTargets(const QString &targets)
{
    m_allowedTargets.clear();
    const QStringList parts = splitList(targets);
    for (const QString &p : parts)
        m_allowedTargets.insert(p.trimmed().toLower());
}

void HikvisionEvents::setChannelInfo(const QString &ip, const QString &json)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c)
        return;
    const QJsonObject o = QJsonDocument::fromJson(json.toUtf8()).object();
    c->chanInfo.clear();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        const QJsonObject v = it.value().toObject();
        c->chanInfo.insert(it.key().toInt(), { v.value(QStringLiteral("name")).toString(), v.value(QStringLiteral("ip")).toString() });
    }
}

void HikvisionEvents::setLensInfo(const QString &ip, const QString &json)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c)
        return;
    const QJsonObject o = QJsonDocument::fromJson(json.toUtf8()).object();
    c->lens.clear();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        const QJsonObject v = it.value().toObject();
        Conn::Lens l;
        l.name = v.value(QStringLiteral("name")).toString();
        l.channel = v.value(QStringLiteral("channel")).toInt();
        c->lens.insert(it.key().toInt(), l);
    }
}

void HikvisionEvents::logTracking(const QString &ip, const QString &target, int lensChannel)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->recorderMode || lensChannel <= 0 || m_logDir.isEmpty())
        return;
    const QString key = ip + QLatin1Char('#') + QString::number(lensChannel);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - m_lastTrack.value(key, 0) < 10000)
        return;
    m_lastTrack.insert(key, now);
    const QDateTime start = QDateTime::currentDateTime();
    logDetection(c, target.isEmpty() ? QStringLiteral("other") : target, QStringLiteral("Tracking"),
                 start.toString(Qt::ISODate), lensChannel);
    // Four snapshots: the first at once, then one a second apart. Each is named by the second it was asked for (the
    // second of the log line, then the next ones), so a slow reply cannot make two of them share a name.
    const qint64 base = start.toSecsSinceEpoch();
    for (int n = 0; n < 4; ++n) {
        if (n == 0)
            takeSnapshot(ip, lensChannel, base);
        else
            QTimer::singleShot(n * 1000, this, [this, ip, lensChannel, base, n]() { takeSnapshot(ip, lensChannel, base + n); });
    }
}

// A still picture of one lens of the camera, from the camera's own picture address (main stream of that channel,
// channel 1 = 101, channel 2 = 201). One request with the connection's login; a refused login stops all picture
// requests for this camera, like the event pictures.
void HikvisionEvents::takeSnapshot(const QString &ip, int cameraChannel, qint64 secs, const QString &kind)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->pictureRefused || c->pictureFetches >= 2 || m_logDir.isEmpty())
        return;
    QUrl url;
    url.setScheme(QStringLiteral("http"));
    url.setHost(ip.section(QLatin1Char(':'), 0, 0).trimmed());
    url.setPort(c->httpPort);
    url.setPath(QStringLiteral("/ISAPI/Streaming/channels/%1/picture").arg(cameraChannel * 100 + 1));
    ++c->pictureFetches;
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
    QNetworkReply *reply = m_net->get(req);
    reply->setProperty("evUser", c->user);
    reply->setProperty("evPass", c->pass);
    connect(reply, &QNetworkReply::finished, this, [this, ip, reply, cameraChannel, secs, kind]() {
        reply->deleteLater();
        Conn *conn = m_conns.value(ip, nullptr);
        if (conn && conn->pictureFetches > 0)
            --conn->pictureFetches;
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 401 || status == 403 || reply->error() == QNetworkReply::AuthenticationRequiredError) {
            if (conn)
                conn->pictureRefused = true;
            qWarning() << "[Events]" << ip << "refused the login for a snapshot. Not asking again.";
            return;
        }
        if (!conn || reply->error() != QNetworkReply::NoError)
            return;
        const QByteArray jpeg = reply->readAll();
        if (jpeg.size() < 1000 || jpeg.left(3) != QByteArray("\xff\xd8\xff", 3))
            return;
        savePicture(cameraAddress(conn, cameraChannel), pictureLens(conn, cameraChannel), kind, secs, jpeg);
    });
}

QVariantList HikvisionEvents::logEventsBetween(const QString &recorderIp, int channel, qint64 startMs, qint64 endMs, const QString &configDir) const
{
    QVariantList out;
    QFile f(configDir + QStringLiteral("/logs/Detection.log"));
    if (recorderIp.isEmpty() || channel <= 0 || !f.open(QIODevice::ReadOnly))
        return out;
    // Walk backwards in blocks until the oldest complete line in hand is older than the start.
    const qint64 block = 256 * 1024;
    qint64 pos = f.size();
    QByteArray data;
    while (pos > 0) {
        const qint64 from = qMax<qint64>(0, pos - block);
        f.seek(from);
        data.prepend(f.read(pos - from));
        pos = from;
        const int nl = data.indexOf('\n');
        if (pos > 0 && nl >= 0) {
            const QDateTime first = QLocale::c().toDateTime(QString::fromUtf8(data.mid(nl + 1, 20)), QStringLiteral("dd MMM yyyy HH:mm:ss"));
            if (first.isValid() && first.toMSecsSinceEpoch() < startMs)
                break;
        }
    }
    const QString want = QStringLiteral("recorder ") + recorderIp + QStringLiteral(" ch ") + QString::number(channel);
    const QList<QByteArray> lines = data.split('\n');
    for (const QByteArray &raw : lines) {
        if (raw.size() < 24)
            continue;
        const QString line = QString::fromUtf8(raw).trimmed();
        if (!line.contains(want))
            continue;
        QStringList parts = line.split(QStringLiteral(", "));
        if (!parts.isEmpty() && parts.last().startsWith(QStringLiteral("via ")))
            parts.removeLast();
        if (!parts.isEmpty() && (parts.last().startsWith(QStringLiteral("box ")) || parts.last().startsWith(QStringLiteral("zone ")) || parts.last().startsWith(QStringLiteral("poly "))))
            parts.removeLast();
        if (!parts.isEmpty() && parts.last().startsWith(QStringLiteral("received ")))
            parts.removeLast();
        if (parts.size() < 5 || parts.last() != want)
            continue;
        const QString kindText = parts.at(2);
        QString kind;
        if (kindText == QLatin1String("Line crossing")) kind = QStringLiteral("line");
        else if (kindText == QLatin1String("Intrusion")) kind = QStringLiteral("intrusion");
        else if (kindText == QLatin1String("Region entrance")) kind = QStringLiteral("enter");
        else if (kindText == QLatin1String("Region exit")) kind = QStringLiteral("exit");
        else if (kindText == QLatin1String("Motion") || kindText == QLatin1String("Tracking")) continue;
        else kind = QStringLiteral("other");
        const QDateTime when = QLocale::c().toDateTime(parts.at(0), QStringLiteral("dd MMM yyyy HH:mm:ss"));
        if (!when.isValid())
            continue;
        const qint64 ms = when.toMSecsSinceEpoch();
        if (ms < startMs || ms > endMs)
            continue;
        QVariantMap e;
        e.insert(QStringLiteral("startTime"), ms);
        e.insert(QStringLiteral("endTime"), ms + 5000);
        e.insert(QStringLiteral("kind"), kind);
        out.append(e);
    }
    return out;
}

bool HikvisionEvents::copyPicture(const QString &fromPath, const QString &toPath) const
{
    if (fromPath.isEmpty() || toPath.isEmpty() || !QFile::exists(fromPath))
        return false;
    QFile::remove(toPath);
    return QFile::copy(fromPath, toPath);
}
