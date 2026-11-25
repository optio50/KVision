#include "rtspaudiocompat.h"
#include <QTcpServer>
#include <QTcpSocket>
#include <QHostAddress>
#include <QUrl>
#include <QRegularExpression>
#include <QTimer>
#include <QCoreApplication>
#include <QDateTime>
#include <QMutex>
#include <QCryptographicHash>
#include <QRandomGenerator>
#include <functional>
#include <atomic>

RtspAudioCompat *RtspAudioCompat::s_instance = nullptr;
bool RtspAudioCompat::s_pendingOffer = false;
QString RtspAudioCompat::s_pendingHost;
int RtspAudioCompat::s_pendingChannel = 0;

RtspAudioCompat::RtspAudioCompat(QObject *parent)
    : QObject(parent)
{
    s_instance = this;
    if (s_pendingOffer) {
        m_droppedHost = s_pendingHost;
        m_droppedChannel = s_pendingChannel;
        setOfferPending(true);
    }
}

RtspAudioCompat::~RtspAudioCompat()
{
    cancelAudioCheck();
    if (s_instance == this)
        s_instance = nullptr;
}

void RtspAudioCompat::setOfferPending(bool on)
{
    if (m_offerPending == on)
        return;
    m_offerPending = on;
    emit offerPendingChanged();
}

void RtspAudioCompat::dismissOffer()
{
    setOfferPending(false);
}

void RtspAudioCompat::applyDrop(const QString &host, int channel)
{
    m_droppedHost = host;
    m_droppedChannel = channel;
    emit droppedCameraChanged();
    setOfferPending(true);
}

void RtspAudioCompat::parseDroppedStream(const QString &url, QString *host, int *channel)
{
    if (host)
        host->clear();
    if (channel)
        *channel = 0;
    const QUrl parsed(url);
    if (parsed.scheme() != QLatin1String("rtsp") && parsed.scheme() != QLatin1String("rtsps"))
        return;
    const QString where = parsed.host();
    if (where.isEmpty() || where == QLatin1String("127.0.0.1")
            || where == QLatin1String("localhost") || where == QLatin1String("::1"))
        return;
    int found = 0;
    const QRegularExpression channelRe(QStringLiteral("/Channels/(\\d+)"));
    const auto match = channelRe.match(parsed.path());
    if (match.hasMatch()) {
        const int streamId = match.captured(1).toInt();
        found = streamId >= 100 ? streamId / 100 : streamId;
    }
    if (host)
        *host = where;
    if (channel)
        *channel = found;
}

bool RtspAudioCompat::sustainedAudioDrop(AudioDropBurst *burst, qint64 nowMs)
{
    const qint64 quietMs = 750;
    const qint64 spanMs = 1000;
    const int need = 12;
    if (!burst)
        return false;
    if (burst->count == 0 || nowMs - burst->lastMs > quietMs) {
        burst->count = 1;
        burst->startMs = nowMs;
        burst->lastMs = nowMs;
        return false;
    }
    ++burst->count;
    burst->lastMs = nowMs;
    return burst->count >= need && nowMs - burst->startMs >= spanMs;
}

void RtspAudioCompat::noteAuHeaderError(const char *streamUrl)
{
    static std::atomic<bool> offered{false};
    if (offered.load())
        return;
    QString host;
    int channel = 0;
    // Copy the host and channel now. The demuxer address is only valid during this callback,
    // and it can contain the camera password.
    parseDroppedStream(streamUrl ? QString::fromUtf8(streamUrl) : QString(), &host, &channel);
    if (host.isEmpty())
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const QString key = host + QLatin1Char('#') + QString::number(channel);
    {
        static QMutex guard;
        static QHash<QString, AudioDropBurst> bursts;
        QMutexLocker lock(&guard);
        if (offered.load())
            return;
        if (!sustainedAudioDrop(&bursts[key], now))
            return;
        offered.store(true);
    }
    QCoreApplication *app = QCoreApplication::instance();
    if (!app) {
        offered.store(false);
        return;
    }
    QMetaObject::invokeMethod(app, [host, channel]() {
        if (!s_instance) {
            s_pendingOffer = true;
            s_pendingHost = host;
            s_pendingChannel = channel;
            return;
        }
        s_instance->applyDrop(host, channel);
    }, Qt::QueuedConnection);
}

QByteArray RtspAudioCompat::repairSdp(const QByteArray &sdp)
{
    QList<QByteArray> lines = sdp.split('\n');
    for (int start = 0; start < lines.size(); ++start) {
        if (!lines[start].startsWith("m=audio ")) continue;
        int end = start + 1;
        while (end < lines.size() && !lines[end].startsWith("m=")) ++end;
        const QList<QByteArray> media = lines[start].trimmed().split(' ');
        // Only repair an unambiguous single-payload AAC section.
        if (media.size() != 4) continue;
        const QByteArray payload = media[3];
        bool aac = false, matching = false;
        for (int i = start + 1; i < end; ++i) {
            if (lines[i].startsWith("a=rtpmap:" + payload + " MPEG4-GENERIC/")) aac = true;
            if (lines[i].startsWith("a=fmtp:" + payload + " ")) matching = true;
        }
        if (!aac || matching) continue;
        for (int i = start + 1; i < end; ++i) {
            if (!lines[i].startsWith("a=fmtp:") || !lines[i].contains("mode=AAC-hbr")) continue;
            const int space = lines[i].indexOf(' ');
            if (space > 7) lines[i] = "a=fmtp:" + payload + lines[i].mid(space);
        }
    }
    return lines.join('\n');
}

RtspAudioCompat::AudioReport RtspAudioCompat::inspectAudio(const QByteArray &sdp)
{
    AudioReport report;
    report.needsRepair = repairSdp(sdp) != sdp;
    const QList<QByteArray> lines = sdp.split('\n');
    for (int start = 0; start < lines.size(); ++start) {
        const QByteArray mediaLine = lines[start].trimmed();
        if (!mediaLine.startsWith("m=audio "))
            continue;
        report.hasAudio = true;
        const QList<QByteArray> media = mediaLine.split(' ');
        const QByteArray payload = media.size() >= 4 ? media.at(3) : QByteArray();
        for (int i = start + 1; i < lines.size(); ++i) {
            const QByteArray line = lines[i].trimmed();
            if (line.startsWith("m="))
                break;
            const QByteArray prefix = "a=rtpmap:" + payload + " ";
            if (payload.isEmpty() || !line.startsWith(prefix))
                continue;
            const QByteArray encoding = line.mid(prefix.size()).split('/').value(0).toUpper();
            if (encoding == "MPEG4-GENERIC")
                report.codec = QStringLiteral("AAC");
            else if (encoding == "PCMU" || encoding == "PCMA")
                report.codec = QStringLiteral("G.711");
            else
                report.codec = QString::fromLatin1(encoding);
        }
        if (report.codec.isEmpty() && payload == "0")
            report.codec = QStringLiteral("G.711");
        break;
    }
    return report;
}

namespace {
class Relay : public QObject {
public:
    Relay(QTcpSocket *client, const QString &host, quint16 port, QObject *parent)
        : QObject(parent), m_client(client), m_upstream(new QTcpSocket(this))
    {
        client->setParent(this);
        connect(client, &QTcpSocket::readyRead, this, [this] {
            m_upstream->write(m_client->readAll());
            if (m_upstream->bytesToWrite() > 4 * 1024 * 1024) stop();
        });
        connect(m_upstream, &QTcpSocket::readyRead, this, [this] { receive(); });
        connect(client, &QTcpSocket::disconnected, this, [this] { stop(); });
        connect(m_upstream, &QTcpSocket::disconnected, this, [this] { stop(); });
#if QT_VERSION >= QT_VERSION_CHECK(5, 15, 0)
        connect(m_upstream, &QTcpSocket::errorOccurred,
#else
        connect(m_upstream, QOverload<QAbstractSocket::SocketError>::of(&QTcpSocket::error),
#endif
                this, [this](QAbstractSocket::SocketError) { stop(); });
        m_upstream->connectToHost(host, port);
        QTimer::singleShot(10000, this, [this] {
            if (m_upstream->state() != QAbstractSocket::ConnectedState) stop();
        });
    }
private:
    void stop() {
        if (m_stopping) return;
        m_stopping = true;
        m_client->abort(); m_upstream->abort(); deleteLater();
    }
    void receive() {
        m_buffer += m_upstream->readAll();
        while (!m_buffer.isEmpty()) {
            if (m_buffer[0] == '$') {
                if (m_buffer.size() < 4) break;
                const int size = 4 + (static_cast<unsigned char>(m_buffer[2]) << 8)
                                     + static_cast<unsigned char>(m_buffer[3]);
                if (m_buffer.size() < size) break;
                m_client->write(m_buffer.constData(), size);
                m_buffer.remove(0, size);
            } else {
                const int headerEnd = m_buffer.indexOf("\r\n\r\n");
                if (headerEnd < 0) break;
                QByteArray header = m_buffer.left(headerEnd + 4);
                const QRegularExpression lengthRe(QStringLiteral("(?im)^Content-Length:[ \\t]*(\\d+)"));
                const auto lengthMatch = lengthRe.match(QString::fromLatin1(header));
                const int length = lengthMatch.hasMatch() ? lengthMatch.captured(1).toInt() : 0;
                if (length < 0 || length > 1024 * 1024) { stop(); return; }
                if (m_buffer.size() < headerEnd + 4 + length) break;
                QByteArray body = m_buffer.mid(headerEnd + 4, length);
                if (header.toLower().contains("application/sdp")) {
                    body = RtspAudioCompat::repairSdp(body);
                    if (lengthMatch.hasMatch())
                        header.replace(lengthMatch.capturedStart(1), lengthMatch.capturedLength(1), QByteArray::number(body.size()));
                }
                m_client->write(header); m_client->write(body);
                m_buffer.remove(0, headerEnd + 4 + length);
            }
            if (m_client->bytesToWrite() > 4 * 1024 * 1024) { stop(); return; }
        }
        if (m_buffer.size() > 2 * 1024 * 1024) stop();
    }
    QTcpSocket *m_client;
    QTcpSocket *m_upstream;
    QByteArray m_buffer;
    bool m_stopping = false;
};
}

QString RtspAudioCompat::streamUrl(const QString &source)
{
    QUrl url(source);
    if (url.scheme() != QStringLiteral("rtsp") || url.host().isEmpty()) return source;
    const QString host = url.host();
    const quint16 port = static_cast<quint16>(url.port(554));
    const QString key = host + QLatin1Char(':') + QString::number(port);
    auto server = m_servers.value(key, nullptr);
    if (!server) {
        server = new QTcpServer(this);
        if (!server->listen(QHostAddress::LocalHost, 0)) { delete server; return source; }
        m_servers.insert(key, server);
        connect(server, &QTcpServer::newConnection, this, [server, host, port] {
            while (server->hasPendingConnections()) new Relay(server->nextPendingConnection(), host, port, server);
        });
    }
    url.setHost(QStringLiteral("127.0.0.1"));
    url.setPort(server->serverPort());
    return url.toString(QUrl::FullyEncoded);
}

namespace {

QByteArray md5Hex(const QByteArray &data)
{
    return QCryptographicHash::hash(data, QCryptographicHash::Md5).toHex();
}

class AudioProbe : public QObject {
public:
    using Done = std::function<void(const QVariantMap &)>;

    AudioProbe(const QString &key, const QString &name, const QString &url, QObject *parent)
        : QObject(parent), m_key(key), m_name(name), m_sock(new QTcpSocket(this))
    {
        const QUrl parsed(url);
        m_user = parsed.userName();
        m_pass = parsed.password();
        m_host = parsed.host();
        m_port = static_cast<quint16>(parsed.port(554));
        m_path = parsed.path();
        if (!m_path.startsWith(QLatin1Char('/')))
            m_path.prepend(QLatin1Char('/'));
        m_uri = QStringLiteral("rtsp://%1:%2%3").arg(m_host).arg(m_port).arg(m_path);
        connect(m_sock, &QTcpSocket::connected, this, [this] { sendDescribe(); });
        connect(m_sock, &QTcpSocket::readyRead, this, [this] { read(); });
#if QT_VERSION >= QT_VERSION_CHECK(5, 15, 0)
        connect(m_sock, &QTcpSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
            if (!m_done && m_sock->state() != QAbstractSocket::ConnectedState)
                fail();
        });
#else
        connect(m_sock, QOverload<QAbstractSocket::SocketError>::of(&QTcpSocket::error),
                this, [this](QAbstractSocket::SocketError) {
            if (!m_done && m_sock->state() != QAbstractSocket::ConnectedState)
                fail();
        });
#endif
        m_timer.setSingleShot(true);
        connect(&m_timer, &QTimer::timeout, this, [this] { fail(); });
    }

    void start(Done done)
    {
        m_doneFn = std::move(done);
        m_timer.start(8000);
        if (m_host.isEmpty()) {
            fail();
            return;
        }
        m_sock->connectToHost(m_host, m_port);
    }

    void abort()
    {
        m_done = true;
        m_timer.stop();
        m_sock->abort();
        deleteLater();
    }

private:
    void sendDescribe()
    {
        QByteArray req = "DESCRIBE " + m_uri.toUtf8() + " RTSP/1.0\r\nCSeq: "
            + QByteArray::number(++m_cseq) + "\r\nAccept: application/sdp\r\nUser-Agent: KVision audio check\r\n";
        if (!m_authorization.isEmpty())
            req += "Authorization: " + m_authorization + "\r\n";
        req += "\r\n";
        m_sock->write(req);
    }

    void read()
    {
        if (m_done)
            return;
        m_buf += m_sock->readAll();
        if (m_buf.size() > 256 * 1024) {
            fail();
            return;
        }
        const int headerEnd = m_buf.indexOf("\r\n\r\n");
        if (headerEnd < 0)
            return;
        const QByteArray header = m_buf.left(headerEnd);
        int length = 0;
        const auto match = QRegularExpression(QStringLiteral("(?im)^Content-Length:[ \\t]*(\\d+)"))
                               .match(QString::fromLatin1(header));
        if (match.hasMatch())
            length = match.captured(1).toInt();
        if (length < 0 || length > 256 * 1024) {
            fail();
            return;
        }
        if (m_buf.size() < headerEnd + 4 + length)
            return;
        const QByteArray body = m_buf.mid(headerEnd + 4, length);
        m_buf.remove(0, headerEnd + 4 + length);
        const int lineEnd = header.indexOf("\r\n");
        const QByteArray status = header.left(lineEnd < 0 ? header.size() : lineEnd);
        if (status.contains(" 200 ")) {
            succeed(body);
            return;
        }
        if (status.contains(" 401 ") && m_authorization.isEmpty() && buildAuthorization(header)) {
            sendDescribe();
            return;
        }
        fail();
    }

    bool buildAuthorization(const QByteArray &header)
    {
        QString www;
        const QList<QByteArray> lines = header.split('\n');
        for (const QByteArray &raw : lines) {
            const QByteArray line = raw.trimmed();
            if (line.toLower().startsWith("www-authenticate:") && line.toLower().contains("digest")) {
                www = QString::fromLatin1(line.mid(line.indexOf(':') + 1).trimmed());
                break;
            }
        }
        if (www.isEmpty() || m_user.isEmpty())
            return false;
        const auto grab = [&www](const char *name) {
            const QRegularExpression re(QString::fromLatin1(name) + QStringLiteral("=\"([^\"]*)\""));
            const auto match = re.match(www);
            return match.hasMatch() ? match.captured(1) : QString();
        };
        const QString realm = grab("realm");
        const QString nonce = grab("nonce");
        const QString opaque = grab("opaque");
        QString qop = grab("qop");
        if (qop.contains(QLatin1Char(',')))
            qop = qop.section(QLatin1Char(','), 0, 0).trimmed();
        if (realm.isEmpty() || nonce.isEmpty())
            return false;
        const QByteArray ha1 = md5Hex(m_user.toUtf8() + ':' + realm.toUtf8() + ':' + m_pass.toUtf8());
        const QByteArray ha2 = md5Hex(QByteArray("DESCRIBE:") + m_uri.toUtf8());
        QByteArray auth = "Digest username=\"" + m_user.toUtf8() + "\", realm=\"" + realm.toUtf8()
            + "\", nonce=\"" + nonce.toUtf8() + "\", uri=\"" + m_uri.toUtf8() + "\", response=\"";
        if (qop.isEmpty()) {
            auth += md5Hex(ha1 + ':' + nonce.toUtf8() + ':' + ha2);
            auth += '"';
        } else {
            const QByteArray nc = "00000001";
            const QByteArray cnonce = QByteArray::number(QRandomGenerator::global()->generate(), 16);
            auth += md5Hex(ha1 + ':' + nonce.toUtf8() + ':' + nc + ':' + cnonce + ':' + qop.toUtf8() + ':' + ha2);
            auth += "\", qop=\"" + qop.toUtf8() + "\", nc=" + nc + ", cnonce=\"" + cnonce + '"';
        }
        if (!opaque.isEmpty())
            auth += ", opaque=\"" + opaque.toUtf8() + '"';
        m_authorization = auth;
        return true;
    }

    QVariantMap baseRow() const
    {
        QVariantMap row;
        row.insert(QStringLiteral("key"), m_key);
        row.insert(QStringLiteral("name"), m_name);
        return row;
    }

    void succeed(const QByteArray &sdp)
    {
        if (m_done)
            return;
        m_done = true;
        m_timer.stop();
        const RtspAudioCompat::AudioReport report = RtspAudioCompat::inspectAudio(sdp);
        QVariantMap row = baseRow();
        row.insert(QStringLiteral("hasAudio"), report.hasAudio);
        row.insert(QStringLiteral("needsRepair"), report.needsRepair);
        row.insert(QStringLiteral("codec"), report.codec);
        row.insert(QStringLiteral("state"), !report.hasAudio ? QStringLiteral("off")
            : (report.needsRepair ? QStringLiteral("problem") : QStringLiteral("ok")));
        const Done done = std::move(m_doneFn);
        if (done)
            done(row);
        deleteLater();
    }

    void fail()
    {
        if (m_done)
            return;
        m_done = true;
        m_timer.stop();
        QVariantMap row = baseRow();
        row.insert(QStringLiteral("hasAudio"), false);
        row.insert(QStringLiteral("needsRepair"), false);
        row.insert(QStringLiteral("codec"), QString());
        row.insert(QStringLiteral("state"), QStringLiteral("error"));
        const Done done = std::move(m_doneFn);
        if (done)
            done(row);
        m_sock->abort();
        deleteLater();
    }

    QString m_key;
    QString m_name;
    QString m_user;
    QString m_pass;
    QString m_host;
    QString m_path;
    QString m_uri;
    quint16 m_port = 554;
    QTcpSocket *m_sock;
    QTimer m_timer;
    QByteArray m_buf;
    QByteArray m_authorization;
    int m_cseq = 0;
    bool m_done = false;
    Done m_doneFn;
};

} // namespace

class AudioCheckSession : public QObject {
public:
    explicit AudioCheckSession(RtspAudioCompat *owner) : QObject(owner), m_owner(owner) {}

    void start(const QVariantList &cameras)
    {
        cancel();
        for (const QVariant &value : cameras) {
            const QVariantMap map = value.toMap();
            Job job;
            job.key = map.value(QStringLiteral("key")).toString();
            job.name = map.value(QStringLiteral("name")).toString();
            job.url = map.value(QStringLiteral("url")).toString();
            if (!job.key.isEmpty() && !job.url.isEmpty())
                m_queue.append(job);
        }
        m_total = m_queue.size();
        m_done = 0;
        m_owner->setAudioCheckProgress(true, 0, m_total);
        if (m_total == 0) {
            m_owner->finishAudioCheck();
            return;
        }
        pump();
    }

    void cancel()
    {
        ++m_generation;
        m_queue.clear();
        const QList<AudioProbe *> probes = m_probes;
        m_probes.clear();
        for (AudioProbe *probe : probes)
            probe->abort();
        m_active = 0;
    }

private:
    struct Job {
        QString key;
        QString name;
        QString url;
    };

    void pump()
    {
        while (m_active < 3 && !m_queue.isEmpty()) {
            const Job job = m_queue.takeFirst();
            ++m_active;
            const int generation = m_generation;
            auto *probe = new AudioProbe(job.key, job.name, job.url, this);
            m_probes.append(probe);
            probe->start([this, generation, probe](const QVariantMap &row) {
                m_probes.removeAll(probe);
                if (generation != m_generation)
                    return;
                --m_active;
                ++m_done;
                m_owner->reportAudioRow(row);
                m_owner->setAudioCheckProgress(true, m_done, m_total);
                if (m_queue.isEmpty() && m_active == 0)
                    m_owner->finishAudioCheck();
                else
                    pump();
            });
        }
    }

    RtspAudioCompat *m_owner;
    QList<Job> m_queue;
    int m_generation = 0;
    int m_active = 0;
    int m_done = 0;
    int m_total = 0;
    QList<AudioProbe *> m_probes;
};

void RtspAudioCompat::startAudioCheck(const QVariantList &cameras)
{
    if (!m_audioCheck)
        m_audioCheck = new AudioCheckSession(this);
    m_audioCheck->start(cameras);
}

void RtspAudioCompat::cancelAudioCheck()
{
    if (m_audioCheck)
        m_audioCheck->cancel();
    if (m_audioCheckRunning)
        setAudioCheckProgress(false, m_audioCheckDone, m_audioCheckTotal);
}

void RtspAudioCompat::reportAudioRow(const QVariantMap &row)
{
    emit audioChecked(row);
}

void RtspAudioCompat::finishAudioCheck()
{
    setAudioCheckProgress(false, m_audioCheckTotal, m_audioCheckTotal);
    emit audioCheckFinished();
}

void RtspAudioCompat::setAudioCheckProgress(bool running, int done, int total)
{
    m_audioCheckRunning = running;
    m_audioCheckDone = done;
    m_audioCheckTotal = total;
    emit audioCheckProgressChanged();
}
