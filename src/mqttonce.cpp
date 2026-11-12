#include "mqttonce.h"

#include <QHostAddress>
#include <QTcpSocket>
#include <QTimer>
#include <QUuid>

MqttOnce::MqttOnce(const QString &host, int port, const QString &user, const QString &pass, const QString &topic, int timeoutMs,
                   QObject *parent)
    : QObject(parent)
    , m_host(host)
    , m_port(port > 0 ? port : 1883)
    , m_user(user)
    , m_pass(pass)
    , m_topic(topic)
    , m_timeoutMs(timeoutMs > 0 ? timeoutMs : 20000)
{
}

QByteArray MqttOnce::remainingLength(int n)
{
    QByteArray out;
    do {
        int digit = n % 128;
        n /= 128;
        if (n > 0)
            digit |= 0x80;
        out.append(char(digit));
    } while (n > 0 && out.size() < 4);
    return out;
}

QByteArray MqttOnce::utf8Field(const QString &s)
{
    const QByteArray b = s.toUtf8();
    QByteArray out;
    out.append(char((b.size() >> 8) & 0xff));
    out.append(char(b.size() & 0xff));
    out.append(b);
    return out;
}

void MqttOnce::start()
{
    if (m_host.trimmed().isEmpty() || m_topic.trimmed().isEmpty()) {
        QTimer::singleShot(0, this, [this]() { finish(false, QString(), tr("the broker address or the topic is empty")); });
        return;
    }
    m_socket = new QTcpSocket(this);
    m_timer = new QTimer(this);
    m_timer->setSingleShot(true);
    connect(m_timer, &QTimer::timeout, this, [this]() {
        if (m_socket->state() != QAbstractSocket::ConnectedState)
            finish(false, QString(), tr("cannot reach the broker: %1").arg(m_socket->errorString()));
        else
            finish(false, QString(), tr("no message arrived within %1 seconds").arg(m_timeoutMs / 1000));
    });
    connect(m_socket, &QTcpSocket::connected, this, &MqttOnce::sendConnect);
    connect(m_socket, &QTcpSocket::readyRead, this, &MqttOnce::onReadyRead);
    connect(m_socket, &QTcpSocket::stateChanged, this, [this](QAbstractSocket::SocketState st) {
        if (st == QAbstractSocket::UnconnectedState && !m_done)
            finish(false, QString(), tr("the broker closed the connection: %1").arg(m_socket->errorString()));
    });
    m_timer->start(m_timeoutMs);
    m_socket->connectToHost(m_host.trimmed(), quint16(m_port));
}

void MqttOnce::sendConnect()
{
    QByteArray body;
    body.append(utf8Field(QStringLiteral("MQTT")));
    body.append(char(4)); // protocol level 3.1.1
    char flags = 0x02;    // clean session
    if (!m_user.isEmpty())
        flags |= char(0x80);
    if (!m_user.isEmpty() && !m_pass.isEmpty())
        flags |= char(0x40);
    body.append(flags);
    body.append(char(0));
    body.append(char(30)); // keep-alive, seconds
    body.append(utf8Field(QStringLiteral("kvision-") + QUuid::createUuid().toString(QUuid::Id128).left(10)));
    if (!m_user.isEmpty())
        body.append(utf8Field(m_user));
    if (!m_user.isEmpty() && !m_pass.isEmpty())
        body.append(utf8Field(m_pass));
    QByteArray packet;
    packet.append(char(0x10));
    packet.append(remainingLength(body.size()));
    packet.append(body);
    m_socket->write(packet);
}

void MqttOnce::sendSubscribe()
{
    QByteArray body;
    body.append(char(0));
    body.append(char(1)); // packet id
    body.append(utf8Field(m_topic.trimmed()));
    body.append(char(0)); // QoS 0
    QByteArray packet;
    packet.append(char(0x82));
    packet.append(remainingLength(body.size()));
    packet.append(body);
    m_socket->write(packet);
}

void MqttOnce::onReadyRead()
{
    m_buffer.append(m_socket->readAll());
    while (!m_done) {
        if (m_buffer.size() < 2)
            return;
        const quint8 first = quint8(m_buffer.at(0));
        int len = 0, mult = 1, used = 1;
        bool complete = false;
        for (int i = 1; i < m_buffer.size() && i <= 4; ++i) {
            const quint8 d = quint8(m_buffer.at(i));
            len += (d & 0x7f) * mult;
            mult *= 128;
            used = i + 1;
            if (!(d & 0x80)) {
                complete = true;
                break;
            }
        }
        if (!complete || m_buffer.size() < used + len)
            return; // the rest of the packet is still on its way
        const QByteArray body = m_buffer.mid(used, len);
        m_buffer.remove(0, used + len);
        const int type = first >> 4;
        if (type == 2) { // CONNACK
            const int rc = body.size() >= 2 ? quint8(body.at(1)) : 255;
            if (rc != 0) {
                static const char *why[] = { "", "the broker does not speak MQTT 3.1.1", "the client name was rejected", "the broker is unavailable",
                                              "wrong user name or password", "not authorised" };
                finish(false, QString(), tr("the broker refused the connection: %1").arg(rc <= 5 ? QString::fromLatin1(why[rc]) : tr("code %1").arg(rc)));
                return;
            }
            sendSubscribe();
        } else if (type == 9) { // SUBACK
            if (body.size() >= 3 && quint8(body.at(2)) == 0x80) {
                finish(false, QString(), tr("the broker refused the subscription to this topic"));
                return;
            }
        } else if (type == 3) { // PUBLISH
            if (body.size() < 2)
                continue;
            const int topicLen = (quint8(body.at(0)) << 8) | quint8(body.at(1));
            int pos = 2 + topicLen;
            const int qos = (first >> 1) & 3;
            if (qos > 0)
                pos += 2;
            if (pos > body.size())
                continue;
            finish(true, QString::fromUtf8(body.mid(pos)), QString());
            return;
        }
    }
}

void MqttOnce::finish(bool ok, const QString &payload, const QString &error)
{
    if (m_done)
        return;
    m_done = true;
    if (m_timer)
        m_timer->stop();
    if (m_socket) {
        if (m_socket->state() == QAbstractSocket::ConnectedState) {
            m_socket->write(QByteArray::fromHex("e000")); // DISCONNECT
            m_socket->flush();
        }
        m_socket->abort();
    }
    emit finished(ok, payload, error);
}
