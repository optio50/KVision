#include "hikvisionevents.h"
#include "eventalert.h"
#include "loginguard.h"

#include <QAuthenticator>
#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QEventLoop>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDir>
#include <QImage>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QLocale>
#include <QThread>
#include <QTextStream>
#include <QMutexLocker>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSet>
#include <QUrl>
#include <algorithm>
#include <cmath>

namespace {
const int kMaxFailures = 3;       // after this many failed attempts in a row, tell the user once (it keeps trying)
const int kRetryBaseMs = 2000;    // first wait before reopening a lost stream; doubles each time
const int kRetryMaxMs = 30000;    // and never waits longer than this
const int kUnsupportedRetryMs = 30 * 60 * 1000; // a device that said "no event stream" is asked again after this long (it may only have been starting up)
const int kHealthyMs = 10000;     // a stream that has stayed up this long counts as working
const int kStallMs = 40000;       // a camera sends a heartbeat about every 10 s: this long with no data means the stream is dead
const int kMaxBuffer = 1024 * 1024; // pictures can ride along in an event; never keep more than this

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

// A report this far behind the computer's clock is a replay after a stall or a reconnect, not something happening now.
// The same gap marks the log line "received HH:mm:ss" and keeps the tile from flashing.
bool reportIsLate(const QString &cameraTime)
{
    return eventReportIsLate(cameraTime, QDateTime::currentDateTime());
}
}

void EventParseWorker::ingest(const QString &ip, const QByteArray &chunk, qulonglong generation)
{
    if (m_owner)
        m_owner->parseIncoming(ip, chunk, generation);
}

HikvisionEvents::HikvisionEvents(QObject *parent)
    : QObject(parent)
{
    m_worker = new EventParseWorker(this);
    m_thread = new QThread(this);
    m_worker->moveToThread(m_thread);
    m_thread->start();
    m_net = new QNetworkAccessManager(this);
    // A follow writes its log line and then asks for the pictures. Closing the window used to exit while those
    // replies were still out, so the line stayed and the snapshots were never saved.
    connect(QCoreApplication::instance(), &QCoreApplication::aboutToQuit, this, [this]() { drainSnapshots(); });
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
    m_stopping.store(true);
    if (m_thread) {
        m_thread->quit();
        m_thread->wait();
    }
    QCoreApplication::removePostedEvents(this);
    delete m_worker;
    m_worker = nullptr;
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
    QMutexLocker lock(&m_mu);
    if (m_logDir.isEmpty() && !configDir.isEmpty())
        m_logDir = configDir + QStringLiteral("/logs");
    loadNoStreamNoted();
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
            Conn *conn = m_conns.value(ip, nullptr);
            if (!conn)
                return;
            if (conn->unsupported)
                m_noStreamUntil.remove(ip); // the quiet wait is over: one more try
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
    if (!c->reply && !c->retry->isActive() && !c->authFailed) {
        const qint64 until = m_noStreamUntil.value(ip, 0);
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        if (until > now) {
            c->unsupported = true; // still inside the quiet wait from an earlier answer
            c->retry->start(static_cast<int>(qMin<qint64>(until - now, kUnsupportedRetryMs)));
        } else if (!c->unsupported) {
            lock.unlock();
            open(ip);
        }
    }
}

void HikvisionEvents::unwatch(const QString &ip)
{
    QMutexLocker lock(&m_mu);
    Conn *c = m_conns.value(ip, nullptr);
    if (!c)
        return;
    if (--c->watchers <= 0) {
        lock.unlock();
        close(ip);
    }
}

void HikvisionEvents::close(const QString &ip)
{
    QMutexLocker lock(&m_mu);
    Conn *c = m_conns.take(ip);
    lock.unlock();
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
    QMutexLocker lock(&m_mu);
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

void HikvisionEvents::loadNoStreamNoted()
{
    if (m_noStreamLoaded || m_logDir.isEmpty())
        return;
    m_noStreamLoaded = true;
    QFile in(m_logDir + QStringLiteral("/no-event-stream"));
    if (!in.open(QIODevice::ReadOnly))
        return;
    while (!in.atEnd()) {
        const QString line = QString::fromUtf8(in.readLine()).trimmed();
        if (!line.isEmpty())
            m_noStreamNoted.insert(line);
    }
}

void HikvisionEvents::storeNoStreamNoted() const
{
    if (m_logDir.isEmpty())
        return;
    QDir().mkpath(m_logDir);
    QSaveFile out(m_logDir + QStringLiteral("/no-event-stream"));
    if (!out.open(QIODevice::WriteOnly))
        return;
    QStringList ips = m_noStreamNoted.values();
    ips.sort();
    for (const QString &ip : ips)
        out.write(ip.toUtf8() + '\n');
    out.commit();
}

void HikvisionEvents::open(const QString &ip)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->reply)
        return;
    if (m_noStreamUntil.value(ip, 0) > QDateTime::currentMSecsSinceEpoch())
        return;
    if (LoginGuard::instance().isRefused(ip, c->user, c->pass)) {
        c->authFailed = true;
        qWarning() << "[Events]" << ip << "login was already refused. Not opening the detection stream.";
        emit listenFailed(ip, tr("The camera refused the login. Check its password."));
        return;
    }
    {
        QMutexLocker lock(&m_mu);
        ++c->generation; // chunks already queued belong to the previous stream
    }
    QUrl url;
    url.setScheme(QStringLiteral("http"));
    url.setHost(ip.section(QLatin1Char(':'), 0, 0).trimmed());
    url.setPort(c->httpPort);
    url.setPath(QStringLiteral("/ISAPI/Event/notification/alertStream"));
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
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
    if (c->unsupported && c->reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200) {
        c->unsupported = false; // it does offer them after all
        m_noStreamUntil.remove(ip);
        if (m_noStreamNoted.remove(ip))
            storeNoStreamNoted();
        qInfo() << "[Events]" << ip << "now offers detection events";
    }
    c->watchdog->start(); // and the stream is alive: start the stall timer again
    c->lastDataMs = QDateTime::currentMSecsSinceEpoch();
    const QByteArray chunk = c->reply->readAll();
    if (chunk.isEmpty() || !m_worker)
        return;
    qulonglong gen;
    {
        QMutexLocker lock(&m_mu);
        gen = c->generation;
    }
    // The scan, the picture check and the log write happen off this thread. The bytes are only copied here.
    QMetaObject::invokeMethod(m_worker, "ingest", Qt::QueuedConnection,
                              Q_ARG(QString, ip), Q_ARG(QByteArray, chunk), Q_ARG(qulonglong, gen));
}

bool HikvisionEvents::loadSnap(const QString &ip, qulonglong generation, Conn *meta)
{
    QMutexLocker lock(&m_mu);
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->generation != generation)
        return false;
    meta->ip = c->ip;
    meta->httpPort = c->httpPort;
    meta->user = c->user;
    meta->pass = c->pass;
    meta->name = c->name;
    meta->recIp = c->recIp;
    meta->recChannel = c->recChannel;
    meta->recorderMode = c->recorderMode;
    meta->chanInfo = c->chanInfo;
    meta->lens = c->lens;
    meta->generation = c->generation;
    m_wKinds = m_allowedKinds;
    m_wTargets = m_allowedTargets;
    m_wOverrides = m_sourceOverrides;
    m_wDefaultSource = m_defaultSource;
    m_wLogMotion = m_logUnlabelledMotion;
    m_wFrameMotion = m_frameUnlabelledMotion;
    m_wFacePicture = m_pictureFaceDetection;
    m_wLogDir = m_logDir;
    m_wMaxPictures = m_maxPictures;
    return true;
}

QString HikvisionEvents::logDirectory() const
{
    QMutexLocker lock(&m_mu);
    return m_logDir;
}

void HikvisionEvents::parseIncoming(const QString &ip, const QByteArray &chunk, qulonglong generation)
{
    if (m_stopping.load())
        return;
    Conn meta;
    if (!loadSnap(ip, generation, &meta))
        return;
    Conn &slot = m_parse[ip];
    if (slot.generation != generation) {
        slot = Conn();
        slot.generation = generation;
    }
    slot.ip = meta.ip;
    slot.httpPort = meta.httpPort;
    slot.user = meta.user;
    slot.pass = meta.pass;
    slot.name = meta.name;
    slot.recIp = meta.recIp;
    slot.recChannel = meta.recChannel;
    slot.recorderMode = meta.recorderMode;
    slot.chanInfo = meta.chanInfo;
    slot.lens = meta.lens;
    slot.buffer += chunk;
    Conn *c = &slot;
    if (c->buffer.size() > kMaxBuffer) {
        c->buffer = c->buffer.right(kMaxBuffer / 2);
        c->jsonScanned = 0;
        c->faceJsonScanned = 0;
        c->facePicFrom = 0;
        c->pendingFace = false;
    }

    int consumed = 0;
    // Pictures ride in the same stream and contain zero bytes. QString::fromLatin1(QByteArray) stops at the first one,
    // which hid every event that came after a picture, so the length is given explicitly.
    const QString text = QString::fromLatin1(c->buffer.constData(), c->buffer.size());
    // A G3 with face detection on sends JSON faceCapture instead of the XML facedetection alert, then
    // the pictures. Line and intrusion stay on the XML path and are unchanged when the camera is switched back.
    const QVector<FaceCaptureEvent> faceCaptures = splitFaceCaptures(text);
    for (const FaceCaptureEvent &face : faceCaptures) {
        if (face.end <= c->faceJsonScanned)
            continue;
        c->faceJsonScanned = qMax(c->faceJsonScanned, face.end);
        if (!face.active || !sourceAllowed(c, face.channel))
            continue;
        handleFaceCapture(c, ip, face);
    }
    const QVector<EventAlertSpan> spans = splitEventAlerts(text);
    const QDateTime now = QDateTime::currentDateTime();
    for (const EventAlertSpan &span : spans) {
        if (c->pendingValid && span.start > consumed)
            judgePicture(c, c->buffer.mid(consumed, span.start - consumed)); // a picture that rode in before this event
        c->pendingValid = false; // each event brings its own picture, or none
        consumed = span.end;
        const QString body = span.body;
        const EventAlert alert = classifyEventAlert(body, m_wKinds, m_wTargets, m_wFrameMotion, now);
        const QString camTime = alert.cameraTime;
        const int camChannel = alert.channel;
        if (!sourceAllowed(c, camChannel))
            continue; // this camera's reports are taken from the other connection (the camera's own, or the recorder's)
        if (alert.action == EventAlert::Face) {
            handleFace(c, ip, body, camTime, camChannel);
            continue;
        }
        if (alert.action == EventAlert::Other) {
            logOtherEvent(c, alert.type, alert.state, camTime, camChannel, body);
            continue;
        }
        if (alert.action == EventAlert::Smart) {
            // A smart event (line crossing, intrusion, region entrance or exit...). The camera names
            // the target inside the rule. All of them go to the detection log and show the tile's
            // detection frame with that target, like a labelled motion report.
            if (alert.active) {
                const QString t = alert.target.isEmpty() ? QStringLiteral("other") : alert.target;
                logDetection(c, alert.target, alert.logKind, camTime, camChannel, eventWhere(body)); // the log keeps every labelled report
                if (!reportIsLate(camTime))
                    noteSiblingTarget(c, ip, camChannel, t);
                notePictureRect(c, body, camChannel, camTime, alert.logKind);
                // The settings can switch kinds and targets off for the screen: no frame for those.
                // A replayed report is still logged and its picture is still kept; it does not flash the tile.
                if (alert.frame == EventAlert::Flash) {
                    qDebug() << "[Events]" << alert.logKind << "from" << ip << "channel" << camChannel << ":" << t;
                    emit targetDetected(ip, t, alert.shortLabel, camChannel);
                }
            }
            continue;
        }
        if (alert.action == EventAlert::PlainMotion) {
            // Plain motion: the camera says something moved, not what. A recorder repeats it about once a second while
            // the movement goes on, so one line is written when a movement starts, and the next only after it has been
            // still for kMotionQuietMs.
            const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
            const QString motionKey = ip + QLatin1Char('|') + QString::number(camChannel);
            const qint64 lastMs = m_motionSeen.value(motionKey, 0);
            m_motionSeen.insert(motionKey, nowMs);
            if (m_wLogMotion && nowMs - lastMs >= kMotionQuietMs) {
                logDetection(c, QString(), QStringLiteral("Motion"), camTime, camChannel);
                if (!reportIsLate(camTime))
                    noteSiblingTarget(c, ip, camChannel, QStringLiteral("other"));
            }
            if (alert.frame == EventAlert::Flash)
                emit targetDetected(ip, QStringLiteral("other"), QStringLiteral("MOTION"), camChannel); // shows "MOTION"
            else if (alert.frame == EventAlert::Keep)
                emit motionDetected(ip, camChannel); // only keeps a frame that is already shown
            continue;
        }
        if (alert.action == EventAlert::LabelledMotion) {
            logDetection(c, alert.target, QStringLiteral("Motion"), camTime, camChannel); // the log keeps every labelled report
            if (!reportIsLate(camTime))
                noteSiblingTarget(c, ip, camChannel, alert.target);
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
            if (alert.frame != EventAlert::Flash)
                continue; // motion or this target is switched off, or the report is a replay: no frame
            qDebug() << "[Events] report from" << ip << "channel" << camChannel << ":" << alert.target;
            emit targetDetected(ip, alert.target, QStringLiteral("MOTION"), camChannel);
        }
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
            const int channel = pm.captured(1).toInt();
            const bool leave = pm.captured(2) == QLatin1String("leave");
            emit trackingChanged(ip, channel, leave);
            notePtzLeave(c, ip, channel, leave);
        }
        QRegularExpressionMatchIterator gi = gisRx.globalMatch(text, qMax(0, c->jsonScanned - 300));
        while (gi.hasNext()) {
            const QRegularExpressionMatch gm = gi.next();
            if (gm.capturedEnd() <= c->jsonScanned)
                continue;
            scannedTo = qMax(scannedTo, int(gm.capturedEnd()));
            const int channel = gm.captured(1).toInt();
            emit ptzMoved(ip, channel);
            notePtzMoved(c, ip, channel);
        }
        c->jsonScanned = scannedTo;
    }
    if (c->pendingFace)
        takeFaceCapturePictures(c, c->buffer.size());
    if (consumed > 0) {
        c->buffer.remove(0, consumed);
        c->jsonScanned = qMax(0, c->jsonScanned - consumed);
        c->faceJsonScanned = qMax(0, c->faceJsonScanned - consumed);
        c->facePicFrom = qMax(0, c->facePicFrom - consumed);
    }
    judgePicture(c, c->buffer);
}

// A camera with face detection on sends "facedetection" while a face is in view, about once a second. The report names no box and
// brings no picture, so there is nothing to frame. The first one of a run is written to the detection log (the next line only after
// kMotionQuietMs without one). sourceAllowed() has already dropped the copy from the other connection, the camera's or the
// recorder's, whichever is not the camera's chosen event source. When face pictures are on, a still is taken at that first report,
// then another from a report that arrives about one second later and another from one about three seconds later, only while the
// camera is still sending them. A report that arrives after the window has passed does not stand in for a missed one. The stills
// are named from the first report's second (that second, then +1 and +3) so the one log line finds all three. A late replay is
// logged and does not take a still: a picture asked for now would be the wrong moment. The tile's "FACE DETECTED" label follows
// the "Face detection" choice of the on-screen settings (on by default) and is separate from the stills. A face is not a target
// kind, so the target choices do not apply to it.
void HikvisionEvents::handleFace(Conn *c, const QString &ip, const QString &body, const QString &cameraTime, int eventChannel)
{
    static const QRegularExpression stateRx(QStringLiteral("<eventState>([^<]*)</eventState>"));
    if (stateRx.match(body).captured(1) != QLatin1String("active"))
        return;
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const QString key = ip + QStringLiteral("|face|") + QString::number(eventChannel);
    const qint64 lastMs = m_motionSeen.value(key, 0);
    m_motionSeen.insert(key, nowMs);
    const bool newRun = nowMs - lastMs >= kMotionQuietMs;
    if (newRun)
        logDetection(c, QStringLiteral("face"), QStringLiteral("Face detection"), cameraTime, eventChannel);
    if (!reportIsLate(cameraTime))
        noteSiblingTarget(c, ip, eventChannel, QStringLiteral("face"));
    // The later stills are taken here, on the reports that prove the face is still being sent. A timer would fire after the
    // face had gone, and m_motionSeen is only touched on this thread.
    if (m_wFacePicture && !reportIsLate(cameraTime)) {
        static constexpr qint64 kShot1Ms = 1000;
        static constexpr qint64 kShot3Ms = 3000;
        static constexpr qint64 kShot3LateMs = 4500; // a report much later than three seconds is not "still there at three seconds"
        const int channel = eventChannel > 0 ? eventChannel : 1;
        if (newRun) {
            QDateTime when = QDateTime::fromString(cameraTime, Qt::ISODate);
            if (!when.isValid())
                when = QDateTime::currentDateTime();
            const qint64 base = when.toSecsSinceEpoch();
            takeSnapshot(ip, channel, base, QStringLiteral("Face detection"));
            FaceRun run;
            run.startMs = nowMs;
            run.baseSecs = base;
            m_faceRuns.insert(key, run);
        } else {
            auto it = m_faceRuns.find(key);
            if (it != m_faceRuns.end()) {
                const qint64 elapsed = nowMs - it->startMs;
                // A report that arrives only once the three-second window has opened does not also count as the one-second still.
                if (!it->shot1 && elapsed >= kShot1Ms && elapsed < kShot3Ms) {
                    it->shot1 = true;
                    takeSnapshot(ip, channel, it->baseSecs + 1, QStringLiteral("Face detection"));
                }
                if (!it->shot3 && elapsed >= kShot3Ms && elapsed < kShot3LateMs) {
                    it->shot3 = true;
                    takeSnapshot(ip, channel, it->baseSecs + 3, QStringLiteral("Face detection"));
                }
            }
        }
    }
    if (!m_wKinds.contains(QStringLiteral("face")))
        return; // "Face detection" is switched off for the screen (the log and the stills are not affected)
    if (reportIsLate(cameraTime))
        return; // a replayed face report stays in the log and does not put the label back up
    qDebug() << "[Events] face from" << ip << "channel" << eventChannel;
    emit targetDetected(ip, QStringLiteral("face"), QStringLiteral("FACE"), eventChannel);
}

void HikvisionEvents::handleFaceCapture(Conn *c, const QString &ip, const FaceCaptureEvent &face)
{
    // Pictures of the previous capture sit in front of this one. Keep them before the index moves.
    if (c->pendingFace)
        takeFaceCapturePictures(c, face.start);
    // The camera repeats the same capture once for each attached picture. A new shot has a new time or a new box.
    const bool sameShot = c->pendingFace && face.channel == c->pendingFaceChannel && face.cameraTime == c->pendingFaceTime
        && face.hasRect == c->pendingHasRect
        && std::abs(face.x - c->pendingRect.x()) < 0.001 && std::abs(face.y - c->pendingRect.y()) < 0.001
        && std::abs(face.w - c->pendingRect.width()) < 0.001 && std::abs(face.h - c->pendingRect.height()) < 0.001;
    if (sameShot) {
        c->facePicFrom = qMax(c->facePicFrom, face.end);
        return;
    }
    QString where;
    if (face.hasRect) {
        where = QStringLiteral("box %1/%2/%3/%4")
                    .arg(face.x, 0, 'f', 3)
                    .arg(face.y, 0, 'f', 3)
                    .arg(face.w, 0, 'f', 3)
                    .arg(face.h, 0, 'f', 3);
    }
    logDetection(c, QStringLiteral("face"), QStringLiteral("Face detection"), face.cameraTime, face.channel, where);
    if (!reportIsLate(face.cameraTime))
        noteSiblingTarget(c, ip, face.channel, QStringLiteral("face"));
    QDateTime when = QDateTime::fromString(face.cameraTime, Qt::ISODate);
    if (!when.isValid())
        when = QDateTime::currentDateTime();
    c->pendingFace = true;
    c->pendingFaceTime = face.cameraTime;
    c->pendingFaceChannel = face.channel;
    c->faceSavedScene = false;
    c->faceSavedBody = false;
    c->facePicFrom = face.end;
    c->pendingSecs = when.toSecsSinceEpoch();
    c->pendingAddress = cameraAddress(c, face.channel);
    c->pendingLens = pictureLens(c, face.channel);
    c->pendingKind = QStringLiteral("Face detection");
    c->pendingHasRect = face.hasRect;
    c->pendingRect = QRectF(face.x, face.y, face.w, face.h);
    // An NVR names the pictures as links. A camera leaves the links empty and the JPEGs follow on the stream.
    if (!face.sceneUrl.isEmpty() || !face.faceUrl.isEmpty()) {
        if (!face.sceneUrl.isEmpty()) {
            fetchPicture(c->ip, QUrl(face.sceneUrl), c->pendingAddress, c->pendingLens, c->pendingKind, c->pendingSecs,
                         c->pendingHasRect, c->pendingRect);
            c->faceSavedScene = true;
        }
        if (!face.faceUrl.isEmpty()) {
            // The wide shot is the first picture on the log line. The face crop is the next one.
            fetchPicture(c->ip, QUrl(face.faceUrl), c->pendingAddress, c->pendingLens, c->pendingKind,
                         face.sceneUrl.isEmpty() ? c->pendingSecs : c->pendingSecs + 1, false, QRectF());
            c->faceSavedBody = true;
        }
        if (face.sceneUrl.isEmpty())
            c->faceSavedScene = true;
        if (face.faceUrl.isEmpty())
            c->faceSavedBody = true;
    }
    if (!m_wKinds.contains(QStringLiteral("face")) || reportIsLate(face.cameraTime))
        return; // the log and the pictures stay; the tile label follows the Face detection tick
    qDebug() << "[Events] face capture from" << ip << "channel" << face.channel;
    emit targetDetected(ip, QStringLiteral("face"), QStringLiteral("FACE"), face.channel);
}

void HikvisionEvents::takeFaceCapturePictures(Conn *c, int limit)
{
    if (!c->pendingFace || limit <= c->facePicFrom)
        return;
    const QByteArray slice = c->buffer.mid(c->facePicFrom, limit - c->facePicFrom);
    const QVector<FaceJpeg> pics = faceCaptureJpegs(slice);
    int used = 0;
    int unlabeled = 0;
    for (const FaceJpeg &pic : pics) {
        const QByteArray jpeg = slice.mid(pic.start, pic.end - pic.start);
        bool scene = pic.background;
        bool body = pic.face;
        if (!scene && !body) {
            // Without a content id the capture comes first and the wide shot second.
            if (unlabeled == 0)
                body = true;
            else
                scene = true;
            ++unlabeled;
        }
        if (scene && !c->faceSavedScene) {
            savePicture(c->pendingAddress, c->pendingLens, c->pendingKind, c->pendingSecs, jpeg);
            judgeJpeg(c->pendingAddress, c->pendingHasRect, c->pendingRect, jpeg);
            c->faceSavedScene = true;
        } else if (body && !c->faceSavedBody) {
            // The second picture on the log line. This is the camera's face or full-body shot.
            savePicture(c->pendingAddress, c->pendingLens, c->pendingKind, c->pendingSecs + 1, jpeg);
            c->faceSavedBody = true;
        }
        used = pic.end;
    }
    if (used > 0)
        c->facePicFrom += used;
    if (c->faceSavedScene && c->faceSavedBody) {
        c->pendingFace = false;
        return;
    }
    if (!c->faceSavedScene && !c->faceSavedBody)
        return;
    const QByteArray tail = slice.mid(used);
    if (tail.contains("\xff\xd8\xff"))
        return; // another picture is still arriving
    const QString tailText = QString::fromLatin1(tail);
    if (tailText.contains(QStringLiteral("EventNotificationAlert"))
        || tailText.contains(QStringLiteral("\"eventType\"")))
        c->pendingFace = false; // the next alert started, so no further picture belongs to this capture
}

void HikvisionEvents::notePictureRect(Conn *c, const QString &body, int eventChannel, const QString &cameraTime, const QString &kind)
{
    c->pendingFace = false; // a line or intrusion picture belongs to that event, not a face capture
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
    if (m_worker && QThread::currentThread() != m_worker->thread()) {
        QMetaObject::invokeMethod(m_worker, [this, address, hasRect, r, jpeg]() {
            judgeJpeg(address, hasRect, r, jpeg);
        }, Qt::QueuedConnection);
        return;
    }
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
        QMutexLocker lock(&m_pictureMu);
        m_pictures.insert(address, v);
    }
}

void HikvisionEvents::fetchPicture(const QString &ip, const QUrl &url, const QString &address, int lens, const QString &kind, qint64 secs, bool hasRect, const QRectF &rect)
{
    if (m_stopping.load())
        return;
    if (QThread::currentThread() != thread()) {
        QMetaObject::invokeMethod(this, [this, ip, url, address, lens, kind, secs, hasRect, rect]() {
            fetchPicture(ip, url, address, lens, kind, secs, hasRect, rect);
        }, Qt::QueuedConnection);
        return;
    }
    QMutexLocker lock(&m_mu);
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->pictureRefused || c->pictureFetches >= 2 || address.isEmpty())
        return;
    if (LoginGuard::instance().isRefused(ip, c->user, c->pass)) {
        c->pictureRefused = true;
        return;
    }
    // Only ever send the login to the device this connection belongs to.
    if (url.scheme() != QLatin1String("http") || url.host() != c->ip.section(QLatin1Char(':'), 0, 0).trimmed())
        return;
    const QString dir = m_logDir;
    if (!dir.isEmpty() && QFile::exists(picturePath(QFileInfo(dir).absolutePath(), address, secs, lens, kind)))
        return; // already have this one
    ++c->pictureFetches;
    const QString user = c->user;
    const QString pass = c->pass;
    lock.unlock();
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
    QNetworkReply *reply = m_net->get(req);
    reply->setProperty("evUser", user);
    reply->setProperty("evPass", pass);
    connect(reply, &QNetworkReply::finished, this, [this, ip, reply, address, lens, kind, secs, hasRect, rect]() {
        reply->deleteLater();
        // Unlock before this runs, so a tracking snapshot waiting on a free download can start.
        struct PumpLater {
            HikvisionEvents *self;
            ~PumpLater() { self->pumpSnapshotQueue(); }
        } later{this};
        QMutexLocker finishedLock(&m_mu);
        Conn *conn = m_conns.value(ip, nullptr);
        if (conn && conn->pictureFetches > 0)
            --conn->pictureFetches;
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (LoginGuard::isHttpAuthRefusal(status) || reply->error() == QNetworkReply::AuthenticationRequiredError) {
            if (conn) {
                conn->pictureRefused = true; // one refused login is enough: a wrong password could lock the recorder
                LoginGuard::instance().refuse(ip, conn->user, conn->pass);
            }
            qWarning() << "[Events]" << ip << "refused the login for an event picture. Not asking again.";
            return;
        }
        if (status == 403) {
            if (conn)
                conn->pictureRefused = true;
            qWarning() << "[Events]" << ip << "will not give an event picture (HTTP 403). The login is still valid.";
            return;
        }
        if (reply->error() != QNetworkReply::NoError)
            return;
        const QByteArray jpeg = reply->readAll();
        if (jpeg.size() < 1000 || jpeg.left(3) != QByteArray("\xff\xd8\xff", 3))
            return;
        finishedLock.unlock();
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
    // The file is written here, on the thread that has the JPEG. Queueing the write onto the worker lost it when the
    // window exited as soon as the reply came back: the process was gone before the worker ran. The folder trim is
    // still done on the worker (prunePictures sends itself there).
    const QString dir = logDirectory();
    if (dir.isEmpty() || address.isEmpty() || jpeg.size() < 1000)
        return;
    const QString dirPath = dir + QStringLiteral("/pictures");
    QDir().mkpath(dirPath);
    const QString path = picturePath(QFileInfo(dir).absolutePath(), address, secs, lens, kind);
    const QString part = path + QStringLiteral(".part");
    QFile f(part);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning() << "[Events] cannot write" << f.fileName() << f.errorString();
        return;
    }
    f.write(jpeg);
    f.close();
    QFile::remove(path);
    if (!QFile::rename(part, path)) {
        qWarning() << "[Events] cannot keep" << path;
        QFile::remove(part);
        return;
    }
    prunePictures(dirPath, pictureKey(address, lens));
}

// Keeps the newest m_maxPictures pictures of each camera (or lens) - all of them when key is empty - and deletes the
// older ones. Motion pictures and face stills are counted apart from the smart-event ones, and kept fewer.
//
// This used to list the whole folder with each file's modification time (QDir::entryInfoList sorted by time) on every save. With 5,655
// pictures that took about a second on the thread that draws the screen, and a burst of pictures froze the program for several
// seconds. Now:
//  * only the names are listed, and for one camera only (a name filter), about 10 ms;
//  * a picture's name holds the event time in seconds (<camera>_<seconds>[-<kind>].jpg), so name order is time order and no file
//    time is read (a name without the seconds, an old picture, is ordered by its file time as before, but only when one is met);
//  * the listing is skipped altogether until a camera has gone over its limit: a count of what was saved since the last trim,
//    started from the first listing, says whether it can have.
void HikvisionEvents::prunePictures(const QString &dirPath, const QString &key)
{
    if (m_worker && QThread::currentThread() != m_worker->thread()) {
        QMetaObject::invokeMethod(m_worker, [this, dirPath, key]() { prunePictures(dirPath, key); }, Qt::QueuedConnection);
        return;
    }
    {
        QMutexLocker lock(&m_mu);
        m_wMaxPictures = m_maxPictures;
    }
    // A whole-folder trim (the setting changed) lists everything, once, and trims every camera.
    if (key.isEmpty()) {
        const QStringList all = QDir(dirPath).entryList(QStringList() << QStringLiteral("*.jpg"), QDir::Files, QDir::NoSort);
        QSet<QString> cams;
        for (const QString &n : all) {
            const int us = n.lastIndexOf(QLatin1Char('_'));
            if (us > 0)
                cams.insert(n.left(us));
        }
        for (const QString &cam : qAsConst(cams))
            pruneCamera(dirPath, cam, true);
        return;
    }
    pruneCamera(dirPath, key, false);
}

// One camera (or lens). force lists the files whatever the count says.
void HikvisionEvents::pruneCamera(const QString &dirPath, const QString &key, bool force)
{
    // The count of pictures this camera has on disk, as far as is known: absent until the first listing, then kept up to date
    // by each save. It only decides whether to look, so a count that is a little off makes a trim a little early or late, and never
    // keeps or removes the wrong pictures: the listing below is what decides.
    auto it = m_pictureCount.find(key);
    if (!force && it != m_pictureCount.end()) {
        if (++it.value() <= m_wMaxPictures)
            return; // cannot be over the limit yet
    }
    const QStringList names = QDir(dirPath).entryList(QStringList() << key + QStringLiteral("_*.jpg"), QDir::Files, QDir::NoSort);
    struct Pic { QString name; qint64 secs; bool motion; };
    QList<Pic> pics;
    pics.reserve(names.size());
    int motionCount = 0, otherCount = 0;
    for (const QString &n : names) {
        // "<key>_<seconds>-<kind>.jpg" or "<key>_<seconds>.jpg": the key itself may hold an underscore (192.0.0.115_ch14), but a
        // seconds value follows the key and a "_" and holds digits only, so a name of a longer key (192.0.0.115_ch14 against
        // 192.0.0.115) does not count.
        const QString rest = n.mid(key.size() + 1, n.size() - key.size() - 5); // without the key, "_" and ".jpg"
        const int dash = rest.indexOf(QLatin1Char('-'));
        const QString secsText = dash < 0 ? rest : rest.left(dash);
        bool ok = false;
        const qint64 secs = secsText.toLongLong(&ok);
        if (!ok)
            continue; // another camera whose name starts the same
        // Face stills share the smaller cap. A face camera can save three pictures a visit, and that must not push
        // line and intrusion pictures out. About a quarter of the per-camera limit is about eight such visits.
        const bool motion = rest.endsWith(QLatin1String("-motion")) || rest.endsWith(QLatin1String("-facedetection"));
        pics.append({n, secs, motion});
        (motion ? motionCount : otherCount)++;
    }
    const int limitOther = m_wMaxPictures;
    const int limitMotion = qMax(10, m_wMaxPictures / 4);
    if (otherCount > limitOther || motionCount > limitMotion) {
        std::sort(pics.begin(), pics.end(), [](const Pic &a, const Pic &b) { return a.secs != b.secs ? a.secs > b.secs : a.name > b.name; }); // newest first
        int keptOther = 0, keptMotion = 0;
        for (const Pic &p : qAsConst(pics)) {
            int &kept = p.motion ? keptMotion : keptOther;
            if (++kept > (p.motion ? limitMotion : limitOther))
                QFile::remove(dirPath + QLatin1Char('/') + p.name);
        }
        otherCount = qMin(otherCount, limitOther);
        motionCount = qMin(motionCount, limitMotion);
    }
    m_pictureCount.insert(key, otherCount + motionCount);
}

void HikvisionEvents::setMaxPictures(int count)
{
    QString dir;
    {
        QMutexLocker lock(&m_mu);
        m_maxPictures = qBound(10, count, 10000);
        dir = m_logDir;
    }
    if (!dir.isEmpty())
        prunePictures(dir + QStringLiteral("/pictures"), QString());
}

QVariantMap HikvisionEvents::pictureFrames(const QString &address) const
{
    QMutexLocker lock(&m_pictureMu);
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
    QMutexLocker logLock(&m_logMu);
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
            << "loginSent" << triedLogin << "gotData" << (c->lastDataMs >= c->openedMs || c->failures == 0 ? "maybe" : "no");
    // Only HTTP 401 means the camera refused the password. HTTP 403 is one address this
    // device will not serve (common on a PTZ detection stream) while the live picture
    // and the SDK login still work, so it must not lock the password.
    if (LoginGuard::isHttpAuthRefusal(httpStatus) || err == QNetworkReply::AuthenticationRequiredError) {
        c->authFailed = true;
        LoginGuard::instance().refuse(ip, c->user, c->pass);
        qWarning() << "[Events]" << ip << "refused the login (HTTP" << httpStatus << "). Not trying again.";
        emit listenFailed(ip, tr("The camera refused the login. Check its password."));
        return;
    }
    // This device has no event stream (a doorbell, for example). One warning the first time, then a single
    // question every 30 minutes: a device that is still starting up can answer like this, and asking more
    // often never helps. The note is kept in the log folder, so a later start stays quiet. The quiet wait
    // is also remembered on the listener, so a connection that is closed and opened again does not ask at once.
    if (httpStatus == 403 || httpStatus == 404 || httpStatus == 405 || httpStatus == 501) {
        c->unsupported = true;
        m_noStreamUntil.insert(ip, QDateTime::currentMSecsSinceEpoch() + kUnsupportedRetryMs);
        loadNoStreamNoted();
        if (!m_noStreamNoted.contains(ip)) {
            m_noStreamNoted.insert(ip);
            storeNoStreamNoted();
            qWarning() << "[Events]" << ip
                       << QStringLiteral("has no detection stream (HTTP %1). Asking again in 30 minutes.").arg(httpStatus);
            emit listenFailed(ip, tr("This device does not offer detection events."));
        }
        c->retry->start(kUnsupportedRetryMs);
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
    const QString dir = logDirectory();
    if (dir.isEmpty())
        return;
    QMutexLocker lock(&m_logMu);
    QDir().mkpath(dir);
    QFile f(dir + QStringLiteral("/Detection.log"));
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
        if (reportIsLate(cameraTime))
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
    const QString dir = logDirectory();
    if (dir.isEmpty() || type.isEmpty())
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

    QMutexLocker lock(&m_logMu);
    QDir().mkpath(dir);
    const QString path = dir + QStringLiteral("/OtherEvents.log");
    if (QFileInfo(path).size() > 2 * 1024 * 1024) { // keep it small: one older copy
        QFile::remove(dir + QStringLiteral("/OtherEvents.old.log"));
        QFile::rename(path, dir + QStringLiteral("/OtherEvents.old.log"));
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
    const QString dir = logDirectory();
    if (dir.isEmpty())
        return;
    QString shown = name;
    if (shown.isEmpty()) {
        QMutexLocker lock(&m_mu);
        const Conn *c = m_conns.value(ip, nullptr);
        shown = (c && !c->name.isEmpty()) ? c->name : ip;
    }
    QMutexLocker lock(&m_logMu);
    QDir().mkpath(dir);
    QFile f(dir + QStringLiteral("/Frames.log"));
    if (!f.open(QIODevice::Append | QIODevice::Text))
        return;
    const QString when = QLocale::c().toString(QDateTime::currentDateTime(), QStringLiteral("dd MMM yyyy HH:mm:ss"));
    QTextStream(&f) << when << ", Frame shown, " << text << ", tile " << tile << ", " << shown << ", " << ip << "\n";
}

QVariantMap HikvisionEvents::readDetections(int skip, int count, const QString &configDir, const QString &filterIp,
                                            qint64 fromMs, qint64 toMs, const QString &target, const QString &kinds,
                                            const QString &hideTargets, const QString &hideKinds) const
{
    QMutexLocker logLock(&m_logMu);
    QVariantMap result;
    QVariantList entries;
    bool more = false;
    QStringList wantTargets;
    for (const QString &w : splitList(target))
        wantTargets << w.trimmed().toLower();
    // No type chosen means every kind of event, including plain labelled motion (motion has no picture).
    // Choosing "Motion" lists only those.
    const QStringList wantKinds = splitList(kinds);
    QStringList skipTargets;
    for (const QString &t : splitList(hideTargets))
        skipTargets << t.trimmed().toLower();
    const QStringList skipKinds = splitList(hideKinds);
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
                if (skipKinds.contains(kindNow))
                    continue;
                if (!skipTargets.isEmpty()) {
                    const QString raw = e.value(QStringLiteral("target")).toString().toLower();
                    if (skipTargets.contains(raw == QLatin1String("object") ? QStringLiteral("unnamed") : raw))
                        continue;
                }
                if (!wantTargets.isEmpty()) {
                    QString tg = e.value(QStringLiteral("target")).toString().toLower();
                    if (tg == QLatin1String("object"))
                        tg = QStringLiteral("other");
                    if (!wantTargets.contains(tg))
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
                } else if (kindText == QLatin1String("Face detection") && ms > 0) {
                    // One line at the start of a visit. The stills are that second, one second later and three seconds later.
                    const qint64 base = ms / 1000;
                    const int lens = channel > 0 ? channel : 0;
                    const qint64 offs[3] = {0, 1, 3};
                    for (qint64 off : offs) {
                        const QString tries[2] = { picturePath(configDir, picIp, base + off, lens, kindText),
                                                   picturePath(configDir, picIp, base + off, 0, kindText) };
                        for (const QString &t : tries) {
                            if (QFile::exists(t)) {
                                all << t;
                                break;
                            }
                        }
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
    QMutexLocker lock(&m_mu);
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
    const QString wanted = m_wOverrides.value(key, m_wDefaultSource);
    return c->recorderMode ? wanted == QLatin1String("recorder") : wanted != QLatin1String("recorder");
}

void HikvisionEvents::setChannelSources(const QString &overridesJson, const QString &defaultSource)
{
    QMutexLocker lock(&m_mu);
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
    QMutexLocker lock(&m_mu);
    m_logUnlabelledMotion = log;
    m_frameUnlabelledMotion = frame;
}

void HikvisionEvents::setFacePicture(bool save)
{
    QMutexLocker lock(&m_mu);
    m_pictureFaceDetection = save;
}

void HikvisionEvents::setAllowedTargets(const QString &targets)
{
    QMutexLocker lock(&m_mu);
    m_allowedTargets.clear();
    const QStringList parts = splitList(targets);
    for (const QString &p : parts)
        m_allowedTargets.insert(p.trimmed().toLower());
}

void HikvisionEvents::setChannelInfo(const QString &ip, const QString &json)
{
    QMutexLocker lock(&m_mu);
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
    QMutexLocker lock(&m_mu);
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

namespace {
constexpr qint64 kFollowStaleMs = 30000; // the lens stopped sending positions: the follow is over
constexpr qint64 kSiblingFreshMs = 15000; // the other lens's target is only used this long
constexpr qint64 kPtzMoveFreshMs = 5000;  // a position report this recent means the lens is moving
}

void HikvisionEvents::noteSiblingTarget(Conn *slot, const QString &ip, int channel, const QString &target)
{
    if (!slot || slot->lens.size() < 2 || channel <= 0)
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const QString type = target.isEmpty() ? QStringLiteral("other") : target;
    for (auto it = slot->lens.constBegin(); it != slot->lens.constEnd(); ++it) {
        if (it.key() == channel)
            continue; // the lens that saw the target is not the one that slews
        Conn::LensFollow &f = slot->follow[it.key()];
        f.siblingType = type;
        f.siblingAt = now;
        // Already off park and moving: there is no new "leave", so this target is the follow.
        // A target during the way home is not that. The other lens still sees it the whole way back.
        if (!f.returnSlew && !f.tracking && f.movedAt > f.parkedAt && now - f.movedAt <= kPtzMoveFreshMs)
            notePtzLeave(slot, ip, it.key(), true);
        else
            showFollow(slot, ip, it.key());
    }
}

void HikvisionEvents::notePtzLeave(Conn *slot, const QString &ip, int channel, bool leave)
{
    if (!slot || slot->lens.size() < 2 || channel <= 0 || !slot->lens.contains(channel))
        return;
    Conn::LensFollow &f = slot->follow[channel];
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!leave) {
        f.tracking = false;
        f.logged = false;
        f.movedAt = 0; // the slew back to park is not a new follow
        f.returnSlew = true;
        f.parkedAt = now;
        return;
    }
    f.tracking = true;
    f.returnSlew = false;
    f.trackingAt = now;
    showFollow(slot, ip, channel);
}

void HikvisionEvents::notePtzMoved(Conn *slot, const QString &ip, int channel)
{
    if (!slot || slot->lens.size() < 2 || channel <= 0 || !slot->lens.contains(channel))
        return;
    Conn::LensFollow &f = slot->follow[channel];
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (f.tracking) {
        f.movedAt = now;
        f.trackingAt = now;
        showFollow(slot, ip, channel);
        return;
    }
    // One continuous slew. The way home keeps sending positions, so a new follow starts only after a pause.
    if (f.returnSlew && ((f.movedAt > 0 && now - f.movedAt <= kPtzMoveFreshMs)
                         || (f.movedAt == 0 && now - f.parkedAt <= kPtzMoveFreshMs))) {
        f.movedAt = now;
        return;
    }
    f.returnSlew = false;
    f.movedAt = now;
    if (!f.siblingType.isEmpty() && now - f.siblingAt <= kSiblingFreshMs && f.siblingAt > f.parkedAt)
        notePtzLeave(slot, ip, channel, true);
}

void HikvisionEvents::showFollow(Conn *slot, const QString &ip, int channel)
{
    if (!slot)
        return;
    Conn::LensFollow &f = slot->follow[channel];
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!f.tracking || now - f.trackingAt > kFollowStaleMs)
        return;
    if (f.siblingType.isEmpty() || now - f.siblingAt > kSiblingFreshMs)
        return; // the lens moved with no target seen (someone steering it): no log line
    if (f.logged)
        return;
    f.logged = true;
    qDebug() << "[Events] Tracking from" << ip << "channel" << channel << ":" << f.siblingType;
    logTracking(ip, f.siblingType, channel);
}

void HikvisionEvents::logTracking(const QString &ip, const QString &target, int lensChannel)
{
    QMutexLocker lock(&m_mu);
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->recorderMode || lensChannel <= 0 || m_logDir.isEmpty())
        return;
    const QString key = ip + QLatin1Char('#') + QString::number(lensChannel);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - m_lastTrack.value(key, 0) < 10000)
        return;
    m_lastTrack.insert(key, now);
    // The fourth snapshot is asked for three seconds after the line. A quit before that still waits for it.
    m_snapshotsUntilMs = qMax(m_snapshotsUntilMs, now + 4500);
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
    if (m_stopping.load())
        return;
    if (QThread::currentThread() != thread()) {
        QMetaObject::invokeMethod(this, [this, ip, cameraChannel, secs, kind]() {
            takeSnapshot(ip, cameraChannel, secs, kind);
        }, Qt::QueuedConnection);
        return;
    }
    SnapJob job;
    job.ip = ip;
    job.cameraChannel = cameraChannel;
    job.secs = secs;
    job.kind = kind;
    enqueueSnapshot(job);
}

void HikvisionEvents::enqueueSnapshot(const SnapJob &job)
{
    QString user, pass, address;
    int port = 80;
    int lens = 0;
    bool start = false;
    {
        QMutexLocker lock(&m_mu);
        if (m_logDir.isEmpty() || m_stopping.load() || job.cameraChannel <= 0)
            return;
        Conn *c = m_conns.value(job.ip, nullptr);
        if (!c || c->pictureRefused)
            return;
        if (LoginGuard::instance().isRefused(job.ip, c->user, c->pass)) {
            c->pictureRefused = true;
            return;
        }
        // Another two pictures are already downloading. Wait for a free one. Dropping the request here is how a
        // Tracking line was left with no snapshot: the wide lens had just saved its own pictures.
        if (c->pictureFetches >= 2) {
            m_snapQueue.append(job);
            return;
        }
        ++c->pictureFetches;
        if (job.kind.isEmpty())
            ++m_trackingInFlight;
        user = c->user;
        pass = c->pass;
        port = c->httpPort;
        address = cameraAddress(c, job.cameraChannel);
        lens = pictureLens(c, job.cameraChannel);
        start = true;
    }
    if (start)
        issueSnapshot(job, user, pass, port, address, lens);
}

void HikvisionEvents::issueSnapshot(const SnapJob &job, const QString &user, const QString &pass, int httpPort,
                                    const QString &address, int lens)
{
    QUrl url;
    url.setScheme(QStringLiteral("http"));
    url.setHost(job.ip.section(QLatin1Char(':'), 0, 0).trimmed());
    url.setPort(httpPort);
    url.setPath(QStringLiteral("/ISAPI/Streaming/channels/%1/picture").arg(job.cameraChannel * 100 + 1));
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
#if QT_VERSION >= QT_VERSION_CHECK(5, 15, 0)
    req.setTransferTimeout(5000);
#endif
    QNetworkReply *reply = m_net->get(req);
    reply->setProperty("evUser", user);
    reply->setProperty("evPass", pass);
    const QString ip = job.ip;
    const int cameraChannel = job.cameraChannel;
    const qint64 secs = job.secs;
    const QString kind = job.kind;
    const int tries = job.tries;
    connect(reply, &QNetworkReply::finished, this, [this, ip, reply, cameraChannel, secs, kind, tries, address, lens]() {
        reply->deleteLater();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const bool tracking = kind.isEmpty();
        QByteArray jpeg;
        bool save = false;
        {
            QMutexLocker finishedLock(&m_mu);
            Conn *conn = m_conns.value(ip, nullptr);
            if (conn && conn->pictureFetches > 0)
                --conn->pictureFetches;
            if (tracking && m_trackingInFlight > 0)
                --m_trackingInFlight;
            const bool authRefused = LoginGuard::isHttpAuthRefusal(status)
                    || reply->error() == QNetworkReply::AuthenticationRequiredError;
            bool retry = false;
            bool warned = false;
            if (authRefused) {
                if (conn) {
                    conn->pictureRefused = true;
                    LoginGuard::instance().refuse(ip, conn->user, conn->pass);
                }
                qWarning() << "[Events]" << ip << "refused the login for a snapshot. Not asking again.";
                warned = true;
            } else if (status == 403) {
                if (conn)
                    conn->pictureRefused = true;
                qWarning() << "[Events]" << ip << "will not give a snapshot (HTTP 403). The login is still valid.";
                warned = true;
            } else if (reply->error() != QNetworkReply::NoError) {
                retry = tracking && tries < 1 && !m_stopping.load() && !(conn && conn->pictureRefused);
            } else {
                jpeg = reply->readAll();
                if (jpeg.size() < 1000 || jpeg.left(3) != QByteArray("\xff\xd8\xff", 3)) {
                    jpeg.clear();
                    retry = tracking && tries < 1 && !m_stopping.load();
                } else {
                    save = true;
                }
            }
            // The connection may already have been closed (the tile went away). The address was copied when the
            // snapshot was asked for, so the JPEG is still kept with the log line.
            if (retry) {
                SnapJob again;
                again.ip = ip;
                again.cameraChannel = cameraChannel;
                again.secs = secs;
                again.kind = kind;
                again.tries = tries + 1;
                m_snapQueue.append(again);
            } else if (tracking && !save && !warned) {
                qWarning() << "[Events]" << ip << "tracking snapshot was not saved (HTTP" << status << ").";
            }
        }
        if (save)
            savePicture(address, lens, kind, secs, jpeg);
        pumpSnapshotQueue();
    });
}

void HikvisionEvents::pumpSnapshotQueue()
{
    if (m_snapshotPump)
        return;
    m_snapshotPump = true;
    while (!m_stopping.load()) {
        SnapJob job;
        QString user, pass, address;
        int port = 80;
        int lens = 0;
        bool start = false;
        {
            QMutexLocker lock(&m_mu);
            for (int i = 0; i < m_snapQueue.size(); ) {
                const SnapJob queued = m_snapQueue.at(i);
                Conn *c = m_conns.value(queued.ip, nullptr);
                if (!c || c->pictureRefused || m_logDir.isEmpty()
                        || LoginGuard::instance().isRefused(queued.ip, c->user, c->pass)) {
                    if (c && LoginGuard::instance().isRefused(queued.ip, c->user, c->pass))
                        c->pictureRefused = true;
                    m_snapQueue.removeAt(i);
                    continue;
                }
                if (c->pictureFetches >= 2) {
                    ++i;
                    continue;
                }
                m_snapQueue.removeAt(i);
                ++c->pictureFetches;
                if (queued.kind.isEmpty())
                    ++m_trackingInFlight;
                job = queued;
                user = c->user;
                pass = c->pass;
                port = c->httpPort;
                address = cameraAddress(c, job.cameraChannel);
                lens = pictureLens(c, job.cameraChannel);
                start = true;
                break;
            }
        }
        if (!start)
            break;
        issueSnapshot(job, user, pass, port, address, lens);
    }
    m_snapshotPump = false;
}

void HikvisionEvents::drainSnapshots()
{
    const qint64 deadline = QDateTime::currentMSecsSinceEpoch() + 10000;
    auto pending = [this]() {
        QMutexLocker lock(&m_mu);
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        return now < m_snapshotsUntilMs || m_trackingInFlight > 0 || !m_snapQueue.isEmpty();
    };
    if (!pending())
        return;
    QEventLoop loop;
    QTimer tick;
    tick.setInterval(50);
    connect(&tick, &QTimer::timeout, &loop, [this, &loop, &pending, deadline]() {
        if (!pending() || QDateTime::currentMSecsSinceEpoch() >= deadline)
            loop.quit();
    });
    tick.start();
    loop.exec();
}

QVariantList HikvisionEvents::logEventsBetween(const QString &recorderIp, int channel, qint64 startMs, qint64 endMs, const QString &configDir) const
{
    QMutexLocker logLock(&m_logMu);
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
