#pragma once
#include <QObject>
#include <QHash>
#include <QByteArray>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
class QTcpServer;
class AudioCheckSession;

// Loopback-only RTSP/TCP relay for recorders with mismatched AAC SDP payload IDs.
// The player calls streamUrl only for a camera ticked in the audio-repair list.
// Authentication and media remain between the player and the configured recorder.
class RtspAudioCompat : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool offerPending READ offerPending NOTIFY offerPendingChanged)
    Q_PROPERTY(QString droppedHost READ droppedHost NOTIFY droppedCameraChanged)
    Q_PROPERTY(int droppedChannel READ droppedChannel NOTIFY droppedCameraChanged)
    Q_PROPERTY(bool audioCheckRunning READ audioCheckRunning NOTIFY audioCheckProgressChanged)
    Q_PROPERTY(int audioCheckDone READ audioCheckDone NOTIFY audioCheckProgressChanged)
    Q_PROPERTY(int audioCheckTotal READ audioCheckTotal NOTIFY audioCheckProgressChanged)
public:
    explicit RtspAudioCompat(QObject *parent = nullptr);
    ~RtspAudioCompat() override;
    Q_INVOKABLE QString streamUrl(const QString &url);
    static QByteArray repairSdp(const QByteArray &sdp);
    // What the audio section of one description says, and whether the repair would change it.
    struct AudioReport {
        bool hasAudio = false;
        bool needsRepair = false;
        QString codec;
    };
    static AudioReport inspectAudio(const QByteArray &sdp);
    // Read each camera's live description. A map has key, name and url. The url may hold the
    // password and is not kept. Results arrive on audioChecked, then audioCheckFinished.
    Q_INVOKABLE void startAudioCheck(const QVariantList &cameras);
    Q_INVOKABLE void cancelAudioCheck();
    // Host and Hikvision channel from an RTSP URL. The user and password are not kept.
    // A loopback relay address yields an empty host, because that is this computer, not the camera.
    static void parseDroppedStream(const QString &url, QString *host, int *channel);
    // One damaged audio packet is not a broken camera. The same camera has to keep failing
    // across a full second before the repair is offered.
    struct AudioDropBurst {
        qint64 startMs = 0;
        qint64 lastMs = 0;
        int count = 0;
    };
    static bool sustainedAudioDrop(AudioDropBurst *burst, qint64 nowMs);
    // FFmpeg may report this from a decoder thread. The offer itself is posted to the window thread.
    // streamUrl is the demuxer's address and may contain credentials; only the host and channel are kept.
    static void noteAuHeaderError(const char *streamUrl);
    bool offerPending() const { return m_offerPending; }
    QString droppedHost() const { return m_droppedHost; }
    int droppedChannel() const { return m_droppedChannel; }
    bool audioCheckRunning() const { return m_audioCheckRunning; }
    int audioCheckDone() const { return m_audioCheckDone; }
    int audioCheckTotal() const { return m_audioCheckTotal; }
    Q_INVOKABLE void dismissOffer();
signals:
    void offerPendingChanged();
    void droppedCameraChanged();
    void audioChecked(const QVariantMap &row);
    void audioCheckFinished();
    void audioCheckProgressChanged();
private:
    friend class AudioCheckSession;
    void setOfferPending(bool on);
    void applyDrop(const QString &host, int channel);
    void reportAudioRow(const QVariantMap &row);
    void finishAudioCheck();
    void setAudioCheckProgress(bool running, int done, int total);
    static RtspAudioCompat *s_instance;
    static bool s_pendingOffer;
    static QString s_pendingHost;
    static int s_pendingChannel;
    QHash<QString, QTcpServer *> m_servers;
    bool m_offerPending = false;
    QString m_droppedHost;
    int m_droppedChannel = 0;
    AudioCheckSession *m_audioCheck = nullptr;
    bool m_audioCheckRunning = false;
    int m_audioCheckDone = 0;
    int m_audioCheckTotal = 0;
};
