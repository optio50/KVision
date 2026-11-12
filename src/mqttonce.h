#ifndef MQTTONCE_H
#define MQTTONCE_H

#include <QByteArray>
#include <QObject>
#include <QString>

class QTcpSocket;
class QTimer;

// Reads one message from an MQTT broker (protocol 3.1.1, plain TCP, QoS 0) and hangs up: connect, subscribe to the topic,
// wait for the first message, disconnect. Used to read a value now and then, so no connection is kept open. It sends
// nothing but the standard connect, subscribe and disconnect packets and never publishes.
class MqttOnce : public QObject
{
    Q_OBJECT

public:
    MqttOnce(const QString &host, int port, const QString &user, const QString &pass, const QString &topic, int timeoutMs,
             QObject *parent = nullptr);

    void start();

    // The "remaining length" field of an MQTT packet (one to four bytes, seven bits each).
    static QByteArray remainingLength(int n);

signals:
    // payload is the text of the first message; error says what went wrong when ok is false.
    void finished(bool ok, const QString &payload, const QString &error);

private:
    void onReadyRead();
    void sendConnect();
    void sendSubscribe();
    void finish(bool ok, const QString &payload, const QString &error);
    static QByteArray utf8Field(const QString &s);

    QString m_host;
    int m_port;
    QString m_user;
    QString m_pass;
    QString m_topic;
    int m_timeoutMs;
    QTcpSocket *m_socket = nullptr;
    QTimer *m_timer = nullptr;
    QByteArray m_buffer;
    bool m_done = false;
};

#endif // MQTTONCE_H
