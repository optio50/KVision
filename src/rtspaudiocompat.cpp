#include "rtspaudiocompat.h"
#include <QTcpServer>
#include <QTcpSocket>
#include <QHostAddress>
#include <QUrl>
#include <QRegularExpression>
#include <QTimer>
#include <QCoreApplication>
#include <atomic>

RtspAudioCompat *RtspAudioCompat::s_instance = nullptr;
bool RtspAudioCompat::s_pendingOffer = false;

RtspAudioCompat::RtspAudioCompat(QObject *parent)
    : QObject(parent)
{
    s_instance = this;
    if (s_pendingOffer)
        setOfferPending(true);
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

void RtspAudioCompat::noteAuHeaderError()
{
    static std::atomic<bool> seen{false};
    if (seen.exchange(true))
        return;
    QCoreApplication *app = QCoreApplication::instance();
    if (!app) {
        seen.store(false);
        return;
    }
    QMetaObject::invokeMethod(app, []() {
        if (!s_instance) {
            s_pendingOffer = true;
            return;
        }
        s_instance->setOfferPending(true);
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
