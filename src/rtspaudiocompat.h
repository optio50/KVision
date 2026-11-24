#pragma once
#include <QObject>
#include <QHash>
#include <QByteArray>
class QTcpServer;

// Loopback-only RTSP/TCP relay for recorders with mismatched AAC SDP payload IDs.
// Authentication and media remain between the player and the configured recorder.
class RtspAudioCompat : public QObject {
    Q_OBJECT
public:
    explicit RtspAudioCompat(QObject *parent = nullptr) : QObject(parent) {}
    Q_INVOKABLE QString streamUrl(const QString &url);
    static QByteArray repairSdp(const QByteArray &sdp);
private:
    QHash<QString, QTcpServer *> m_servers;
};
