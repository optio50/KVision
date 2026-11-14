#ifndef HIKVISIONMANAGER_H
#define HIKVISIONMANAGER_H

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QHash>
#include <QList>
#include <QThread>
#include <mutex>
#include <queue>
#include <condition_variable>
#include <thread>
#include "hcnetsdk_compat.h"

class HikvisionManager : public QObject
{
    Q_OBJECT

public:
    explicit HikvisionManager(QObject *parent = nullptr);
    ~HikvisionManager() override;

    // Singleton provider
    static HikvisionManager* instance();

    // Login and discover channels for a specific recorder
    Q_INVOKABLE QVariantList discoverCameras(const QString &ip, int port, int httpPort, const QString &username, const QString &password);
    Q_INVOKABLE void discoverCamerasAsync(const QString &ip, int port, int httpPort, const QString &username, const QString &password);

    // Logout from a recorder session
    Q_INVOKABLE void logout(const QString &ip);

    // Check if logged in to a recorder
    Q_INVOKABLE bool isLogged(const QString &ip);

    // PTZ zoom control
    Q_INVOKABLE bool ptzZoom(const QString &ip, int port, const QString &username, const QString &password, int channelId, int command, bool stop);

    // PTZ preset control (presets are stored on the camera itself).
    // command: SET_PRESET=8 (save current position), GOTO_PRESET=39 (recall), CLE_PRESET=9 (clear)
    Q_INVOKABLE bool ptzPreset(const QString &ip, int port, const QString &username, const QString &password, int channelId, int command, int presetIndex);

    // Force I-Frame for seamless switching
    // Current clock of the recorder/camera (local wall clock, epoch ms), or -1 on failure.
    Q_INVOKABLE qint64 deviceTimeMs(const QString &ip, int port, const QString &username, const QString &password);
    Q_INVOKABLE bool forceIFrame(const QString &ip, int port, const QString &username, const QString &password, int channelId);
    Q_INVOKABLE QString fetchStreamingChannels(const QString &ip, int httpPort, const QString &username, const QString &password);
    // Same answer as proxyCamera() (ip, channel, sdkPort of the camera behind a recorder channel), but
    // the recorder's whole camera list is fetched once and remembered, so many tiles do not each wait
    // for the recorder. A failed fetch is not retried for 30 seconds.
    Q_INVOKABLE QVariantMap proxyCameraCached(const QString &nvrIp, int httpPort, const QString &username, const QString &password, int channelId);
    Q_INVOKABLE QVariantMap proxyCamera(const QString &nvrIp, int httpPort, const QString &username, const QString &password, int channelId);

    // Every channel of a recorder with the camera behind it (channel -> {ip, channel, sdkPort}). Keeps no state,
    // so it is safe to call from any thread; it blocks while it talks to the recorder. Empty on failure.
    static QHash<int, QVariantMap> fetchProxyChannels(const QString &nvrIp, int httpPort, const QString &username, const QString &password);

    // Unstick a camera whose LAN event-push dispatcher has wedged (accepts connections,
    // heartbeats, but delivers zero detection events). Toggles "Notify Surveillance
    // Center" (the LAN push) notification method off and back on for every event trigger of the
    // given channel (motion, line crossing, intrusion, ...), restoring the original config.
    // Returns "ok (N trigger(s) reset)" or an error/warning string.
    // Blocking worker; emits unstickProgress() while it runs. Use the async variant from the UI.
    QString unstickEventDetection(const QString &ip, int httpPort, const QString &username, const QString &password, int channelId, const QString &label);
    // Runs unstickEventDetection() on a background thread; emits unstickProgress()/unstickFinished().
    Q_INVOKABLE void unstickEventDetectionAsync(const QString &ip, int httpPort, const QString &username, const QString &password, int channelId, const QString &label);

    // Shared session management for playback players
    struct SharedSession {
        LONG lUserID = -1;
        NET_DVR_DEVICEINFO_V40 deviceInfo;
        int refCount = 0;
    };

    LONG loginShared(const QString &ip, int port, const QString &username, const QString &password, NET_DVR_DEVICEINFO_V40 &deviceInfo);
    void logoutShared(const QString &ip);
    void forceLogoutShared(const QString &ip);

    LONG getSession(const QString &ip, int port, const QString &username, const QString &password);
    bool getDeviceInfo(const QString &ip, NET_DVR_DEVICEINFO_V40 &deviceInfo);

signals:
    void sessionStatusChanged(const QString &ip, bool loggedIn);
    void discoveryFinished(const QString &ip, const QVariantList &cameras, bool success, const QString &errorMsg);
    void unstickProgress(const QString &label, const QString &text);
    void unstickFinished(const QString &label, const QString &result);

private:
    struct SessionInfo {
        LONG lUserID = -1;
        NET_DVR_DEVICEINFO_V40 deviceInfo;
    };

    bool isLoggedInternal(const QString &ip) const;

    static HikvisionManager* m_instance;
    QHash<QString, SessionInfo> m_sessions; // Maps IP to SessionInfo
    QHash<QString, QHash<int, QVariantMap>> m_proxyCache; // recorder ip -> channel -> camera
    QHash<QString, qint64> m_proxyFailedAt;                // recorder ip -> ms since epoch of the last failed fetch
    QHash<QString, SharedSession> m_sharedSessions;
    std::mutex m_sharedSessionsMutex;
    bool m_initialized;

    struct PtzCommand {
        QString ip;
        int port;
        QString username;
        QString password;
        int channelId;
        int command;
        bool stop;
        int presetIndex = 0; // > 0 for preset commands (SET/GOTO/CLE), 0 for movement commands
    };

    std::queue<PtzCommand> m_ptzQueue;
    std::mutex m_ptzMutex;
    std::condition_variable m_ptzCond;
    std::thread m_ptzWorker;
    bool m_ptzWorkerStop = false;

    void ptzWorkerLoop();
    void ensureInitialized() const;

    mutable std::mutex m_initMutex;
    mutable std::condition_variable m_initCond;
    bool m_initCompleted = false;

    QList<QThread*> m_discoveryThreads;
    std::mutex m_discoveryMutex;
};

#endif // HIKVISIONMANAGER_H
