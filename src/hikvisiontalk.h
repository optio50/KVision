#ifndef HIKVISIONTALK_H
#define HIKVISIONTALK_H

#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include "hcnetsdk_compat.h"
#include "talkaudio.h"

class QAudioInput;
class QIODevice;
class QNetworkAccessManager;
class QNetworkReply;

// Hold-to-talk two-way audio to a Hikvision camera.
//
// start() opens the local microphone and a talk session to the device. Audio captured while
// the session is open is levelled, encoded as G.711 u-law (8 kHz) and sent to the camera
// speaker. stop() ends the session. Only one talk session can be active at a time.
class HikvisionTalk : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    Q_PROPERTY(bool live READ live NOTIFY liveChanged)
    Q_PROPERTY(QString activeKey READ activeKey NOTIFY activeChanged)
    Q_PROPERTY(double level READ level NOTIFY levelChanged)

public:
    // Returns a logged-in SDK user id for the device, or a negative number on failure.
    using SessionProvider = std::function<LONG(const QString &ip, int port, const QString &user, const QString &pass)>;

    explicit HikvisionTalk(SessionProvider provider, QObject *parent = nullptr);
    ~HikvisionTalk() override;

    bool active() const { return m_active; }
    bool live() const { return m_live; }
    QString activeKey() const { return m_activeKey; }
    double level() const { return m_level; }

    // key identifies the tile that started the session (any string; returned by activeKey).
    // micName: an entry from microphones(), or empty for the system default.
    // gain: microphone gain multiplier, about 0.5 to 4.
    // boostDb: output boost in dB applied before the limiter, about -6 to +12.
    Q_INVOKABLE bool start(const QString &key, const QString &ip, int port, const QString &user,
                           const QString &pass, const QString &micName, double gain, double boostDb);
    Q_INVOKABLE void stop();
    Q_INVOKABLE QStringList microphones() const;

    // The camera's own speaker volume for two-way audio (0-100), stored on the camera.
    // Both calls are asynchronous. loadSpeakerVolume() answers with speakerVolumeLoaded()
    // (volume is -1 on failure); saveSpeakerVolume() answers with speakerVolumeSaved().
    Q_INVOKABLE void loadSpeakerVolume(const QString &ip, int httpPort, const QString &user, const QString &pass);
    Q_INVOKABLE void saveSpeakerVolume(const QString &ip, int httpPort, const QString &user, const QString &pass, int volume);

signals:
    void activeChanged();
    void liveChanged();
    void levelChanged();
    void speakerVolumeLoaded(const QString &ip, int volume);
    void speakerVolumeSaved(const QString &ip, bool ok, int volume);
    // Emitted once when a session ends. message is empty for a normal end, otherwise the reason.
    void finished(const QString &key, const QString &message);

private:
    struct Job {
        QString ip, user, pass;
        int port = 8000;
        std::mutex m;
        std::condition_variable cv;
        std::deque<std::vector<uint8_t>> frames;
        std::atomic<bool> stop{false};
        std::atomic<bool> done{false};
    };

    void workerMain(std::shared_ptr<Job> job);
    void onAudioReady();
    void onWorkerLive(const std::shared_ptr<Job> &job);
    void onWorkerFailed(const std::shared_ptr<Job> &job, const QString &message);
    void endSession(const QString &message);
    void releaseCapture();
    static QString sdkLibDir();
    QNetworkReply *sendTalkRequest(const QByteArray &verb, const QString &ip, int httpPort,
                                   const QString &user, const QString &pass, const QByteArray &body = QByteArray());

    SessionProvider m_provider;
    std::shared_ptr<Job> m_job;

    QAudioInput *m_input = nullptr;
    QIODevice *m_io = nullptr;
    int m_inputRate = 48000;
    TalkAudio::Resampler m_resampler;
    TalkAudio::VoiceProcessor m_processor;
    std::vector<uint8_t> m_pending;
    QNetworkAccessManager *m_net = nullptr;
    QTimer m_connectTimeout;
    QTimer m_maxDuration;
    int m_levelTicks = 0;

    bool m_active = false;
    bool m_live = false;
    QString m_activeKey;
    double m_level = 0.0;
};

#endif // HIKVISIONTALK_H
