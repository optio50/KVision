#pragma once
#include <QObject>
#include <QHash>
#include <QByteArray>
#include <QString>
class QTcpServer;

// Loopback-only RTSP/TCP relay for recorders with mismatched AAC SDP payload IDs.
// The player calls streamUrl only for a camera ticked in the audio-repair list.
// Authentication and media remain between the player and the configured recorder.
class RtspAudioCompat : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool offerPending READ offerPending NOTIFY offerPendingChanged)
    Q_PROPERTY(QString droppedHost READ droppedHost NOTIFY droppedCameraChanged)
    Q_PROPERTY(int droppedChannel READ droppedChannel NOTIFY droppedCameraChanged)
public:
    explicit RtspAudioCompat(QObject *parent = nullptr);
    ~RtspAudioCompat() override;
    Q_INVOKABLE QString streamUrl(const QString &url);
    static QByteArray repairSdp(const QByteArray &sdp);
    // Host and Hikvision channel from an RTSP URL. The user and password are not kept.
    // A loopback relay address yields an empty host, because that is this computer, not the camera.
    static void parseDroppedStream(const QString &url, QString *host, int *channel);
    // FFmpeg may report this from a decoder thread. The offer itself is posted to the window thread.
    // streamUrl is the demuxer's address and may contain credentials; only the host and channel are kept.
    static void noteAuHeaderError(const char *streamUrl);
    bool offerPending() const { return m_offerPending; }
    QString droppedHost() const { return m_droppedHost; }
    int droppedChannel() const { return m_droppedChannel; }
    Q_INVOKABLE void dismissOffer();
signals:
    void offerPendingChanged();
    void droppedCameraChanged();
private:
    void setOfferPending(bool on);
    void applyDrop(const QString &host, int channel);
    static RtspAudioCompat *s_instance;
    static bool s_pendingOffer;
    static QString s_pendingHost;
    static int s_pendingChannel;
    QHash<QString, QTcpServer *> m_servers;
    bool m_offerPending = false;
    QString m_droppedHost;
    int m_droppedChannel = 0;
};
