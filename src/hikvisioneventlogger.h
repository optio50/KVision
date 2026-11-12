#ifndef HIKVISIONEVENTLOGGER_H
#define HIKVISIONEVENTLOGGER_H

#include <QHash>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>

class HikvisionEvents;
class QThread;

// Keeps the detection log going for every configured camera, whether or not a tile shows it.
// HikvisionEvents counts watchers per camera, so this holds one watcher for each camera and the tiles keep
// watching on top of it for the on-screen frame: no second connection is opened. Which cameras to watch
// is worked out from the saved recorder list the same way a tile does it (a standalone camera on its own
// address, a camera behind a recorder on its own address or through the recorder, by the source setting).
class HikvisionEventLogger : public QObject
{
    Q_OBJECT
    // True when the background logging is switched on but is not working (service not running, hung, or a camera
    // stream down). Drives the red flashing toolbar icon. Re-checked every few seconds while it is switched on.
    Q_PROPERTY(bool backgroundProblem READ backgroundProblem NOTIFY backgroundHealthChanged)
    Q_PROPERTY(bool backgroundMonitored READ backgroundMonitored NOTIFY backgroundHealthChanged)
    Q_PROPERTY(QString backgroundText READ backgroundText NOTIFY backgroundHealthChanged)

public:
    explicit HikvisionEventLogger(HikvisionEvents *events, QObject *parent = nullptr);
    ~HikvisionEventLogger() override;

    // Call whenever the switch, the recorder list or the source setting changes. Does nothing when the
    // inputs are the same as last time. The recorder lookups run on a background thread.
    Q_INVOKABLE void configure(bool enabled, const QString &recordersJson, const QString &targetSource, const QString &configDir);
    // Installs and starts (or stops and disables) the systemd user service that keeps logging after KVision is
    // closed. Returns an empty string, or what went wrong.
    Q_INVOKABLE QString setBackgroundService(bool on, const QString &configPath);
    // One line saying how the background service is doing (running, standing by, a camera down, ...).
    Q_INVOKABLE QString backgroundStatus(const QString &configDir) const;
    // Restarts the background service (also when it was stopped by hand) on a worker thread, then re-checks its
    // health. backgroundRestartFinished() carries an empty string on success, or what went wrong.
    Q_INVOKABLE void restartBackground(const QString &configPath);
    // Makes sure the background service is installed and running (starts it if it was stopped; leaves a running
    // one alone). Runs on a worker thread; used when KVision starts with the option on.
    Q_INVOKABLE void ensureBackground(const QString &configPath);
    Q_PROPERTY(bool backgroundRestarting READ backgroundRestarting NOTIFY backgroundHealthChanged)
    bool backgroundRestarting() const { return m_bgRestarting; }
    // Turns the periodic health check of the background service on or off (call with the saved setting).
    Q_INVOKABLE void monitorBackground(bool on, const QString &configDir, const QString &configPath);
    bool backgroundProblem() const { return m_bgMonitored && !m_bgOk; }
    bool backgroundMonitored() const { return m_bgMonitored; }
    QString backgroundText() const { return m_bgText; }
    // How many camera connections the logger holds.
    Q_INVOKABLE int watchedCount() const { return m_active.size(); }

signals:
    void backgroundHealthChanged();
    void backgroundRestartFinished(const QString &error);
    // The app restarted the background service on its own because it was down or hung. error is empty on success.
    void backgroundAutoRestarted(const QString &error);

private:
    void checkBackground();

    QTimer *m_bgTimer = nullptr;
    QString m_bgDir;
    bool m_bgMonitored = false;
    bool m_bgOk = true;
    bool m_bgRestarting = false;
    bool m_bgAutoRun = false;      // the restart in progress was started by the app, not by the user
    QString m_bgConfigPath;
    int m_bgAutoTries = 0;         // automatic restarts since the service was last healthy
    qint64 m_bgLastAutoMs = 0;
    int m_bgBad = 0; // checks in a row that found a problem
    QString m_bgText;

    struct Entry {
        QString ip;
        int http = 80;
        QString user;
        QString pass;
        QString name;
        QString configDir;
        QString recIp;
        int recChannel = 0;
        bool recorderMode = false;
        QString chanInfoJson;
        QString lensJson;
        QString signature() const;
    };
    struct Plan {
        QList<Entry> entries;
        QSet<QString> failedRecorders; // recorders that could not be asked: their old connections are kept
    };

    static Plan buildPlan(const QByteArray &recordersJson, const QString &targetSource, const QString &configDir);
    void startPlan();
    void finishPlan(const Plan &plan);
    void applyPlan(const Plan &plan);

    HikvisionEvents *m_events = nullptr;
    QHash<QString, Entry> m_active; // by the address that is watched
    bool m_enabled = false;
    QString m_recordersJson;
    QString m_targetSource;
    QString m_configDir;
    bool m_configured = false;
    bool m_planning = false;
    bool m_replan = false;
    QThread *m_thread = nullptr;
    QTimer *m_retry = nullptr;
};

#endif // HIKVISIONEVENTLOGGER_H
