#include "rtspaudiocompat.h"
#include <QTcpServer>
#include <QTcpSocket>
#include <QHostAddress>
#include <QUrl>
#include <QRegularExpression>
#include <QTimer>
#include <QCoreApplication>
#include <QUrl>
#include <QDateTime>
#include <QMutex>
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
