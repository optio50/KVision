#pragma once
#include <QObject>
#include <QHash>
#include <QByteArray>
class QTcpServer;

// Loopback-only RTSP/TCP relay for recorders with mismatched AAC SDP payload IDs.
// The player calls streamUrl only for a camera ticked in the audio-repair list.
// Authentication and media remain between the player and the configured recorder.
class RtspAudioCompat : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool offerPending READ offerPending NOTIFY offerPendingChanged)
public:
    explicit RtspAudioCompat(QObject *parent = nullptr);
    ~RtspAudioCompat() override;
    Q_INVOKABLE QString streamUrl(const QString &url);
    static QByteArray repairSdp(const QByteArray &sdp);
    // FFmpeg may report this from a decoder thread. The offer itself is posted to the window thread.
    static void noteAuHeaderError();
    bool offerPending() const { return m_offerPending; }
    Q_INVOKABLE void dismissOffer();
signals:
    void offerPendingChanged();
private:
    void setOfferPending(bool on);
    static RtspAudioCompat *s_instance;
    static bool s_pendingOffer;
    QHash<QString, QTcpServer *> m_servers;
    bool m_offerPending = false;
};
