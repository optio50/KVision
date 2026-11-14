#ifndef HIKVISIONSETUPCHECK_H
#define HIKVISIONSETUPCHECK_H

#include <QHash>
#include <QList>
#include <QObject>
#include <QSet>
#include <QSharedPointer>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <functional>

class HikvisionEvents;
class QNetworkAccessManager;
class QTimer;

// A read-only check of whether a camera is set up to report detection events. It only asks the camera (and the
// recorder it is behind) for settings, one request at a time, and never changes anything. A wrong login counts
// toward a camera lock-out, so a request is never sent with an incomplete login, each request tries its login
// once, and a refused login stops the check for that device.
class HikvisionSetupCheck : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int pending READ pending NOTIFY queueChanged)

public:
    explicit HikvisionSetupCheck(QObject *parent = nullptr);

    // Lets the check report whether the event pictures a camera sends carry the rule and target frames. That is
    // learned from the events KVision is already listening to, so it asks the camera for nothing extra.
    void setEvents(HikvisionEvents *events) { m_events = events; }

    // key identifies the camera (recorder address # channel). For a camera behind a recorder (behindRecorder) the
    // recorder is asked for the camera's address and the recorder's login is used for both. throughRecorder says
    // the settings send reports through the recorder, so Notify Surveillance Center and the camera's metadata
    // switch matter. Checks are queued and run one after another.
    Q_INVOKABLE void check(const QString &key, const QString &name, const QString &recorderIp, int httpPort,
                           const QString &user, const QString &pass, int channel, bool behindRecorder,
                           bool throughRecorder, const QString &configDir);

    // The newest result for every camera checked since KVision started, sorted by name. Each result is a map with
    // key, name, time, summary, problems, warnings, model, firmware and items (a list of maps with id, label, state, detail).
    // state is "ok", "problem", "note" or "unknown".
    Q_INVOKABLE QVariantList results() const;
    Q_INVOKABLE QVariantMap resultFor(const QString &key) const;
    Q_INVOKABLE bool isChecking(const QString &key) const;
    int pending() const { return m_queue.size() + (m_running ? 1 : 0); }

signals:
    void resultReady(const QString &key);
    void queueChanged();

private:
    struct Job {
        QString key, name, recorderIp, user, pass, configDir;
        int httpPort = 80;
        int channel = 1;
        bool behindRecorder = false;
        bool through = false;
        QString camIp;
        int camPort = 80;
        int camId = 1;      // the camera's own channel number for its settings
        QString model, firmware;
        QVariantList items;
        bool motionSet = false;
        QStringList smartSet; // kinds with a line or zone defined: linedetection, fielddetection, ...
        QStringList nvrSet;   // kinds the recorder itself has a line or zone for (rules that live in the recorder)
        // Trigger reads still to do, each as host, port, path, event name, side ("recorder" or "camera").
        QList<QStringList> trig;
        QStringList recOk, recMissing, camOk, camMissing; // events with and without Notify Surveillance Center, per side
    };
    using JobPtr = QSharedPointer<Job>;

    void startNext();
    void finish(const JobPtr &j);
    void get(const QString &host, int port, const QString &path, const QString &user, const QString &pass,
             std::function<void(int, const QString &)> done);
    static void add(const JobPtr &j, const QString &id, const QString &label, const QString &state, const QString &detail);

    void stepRecorderList(const JobPtr &j);
    void stepDeviceInfo(const JobPtr &j);
    void stepMetadata(const JobPtr &j);
    void stepMotion(const JobPtr &j);
    void stepSmart(const JobPtr &j, int index);
    void stepNvrSmart(const JobPtr &j, int index);
    void stepSmartDone(const JobPtr &j);
    void stepSmartRead(const JobPtr &j, int index);
    void stepSizeLimits(const JobPtr &j, int index, const QStringList &zones);
    void stepOnline(const JobPtr &j);
    void stepTriggers(const JobPtr &j, int index);

    QNetworkAccessManager *m_net = nullptr;
    QList<JobPtr> m_queue;
    bool m_running = false;
    QHash<QString, QVariantMap> m_results;
    QString m_activeKey;
    HikvisionEvents *m_events = nullptr;
    QSet<QString> m_refused; // devices that refused the login this session: never asked again
};

#endif // HIKVISIONSETUPCHECK_H
