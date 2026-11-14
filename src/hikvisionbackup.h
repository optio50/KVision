#ifndef HIKVISIONBACKUP_H
#define HIKVISIONBACKUP_H

#include <QList>
#include <QObject>
#include <QString>
#include <functional>
#include <QVariantList>

class QThread;

// Backs up the configuration of Hikvision cameras, one camera at a time, each reached on its own address
// (a camera behind a recorder is found through the recorder's channel list, but the recorder itself is never
// backed up and is not contacted for the export). A backup is the camera's own configuration export
// (/ISAPI/System/configurationData), saved to <config dir>/backups/ with a small .json beside it.
// The export needs a key; a fixed one built into the program is used for every camera, so there is nothing
// to type or remember, and it must never change or older backups stop restoring.
class HikvisionBackup : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool ruleBusy READ ruleBusy NOTIFY ruleBusyChanged)

public:
    explicit HikvisionBackup(QObject *parent = nullptr);
    ~HikvisionBackup() override;

    bool busy() const { return m_busy; }
    bool ruleBusy() const { return m_ruleBusy; }

    // Works out the camera list from the saved recorders (looking up each recorder's channels on a worker
    // thread) and emits camerasLoaded(): a list of maps with name, ip, login ("own" or "recorder") and user.
    Q_INVOKABLE void loadCameras(const QString &recordersJson, const QString &configPath);
    // Backs up one camera of the loaded list. A non-empty user and password are used for this camera instead of
    // its saved login, and are remembered for it once the camera has accepted them. One login attempt only.
    Q_INVOKABLE void backupCamera(const QString &ip, const QString &user, const QString &password);
    // Backs up every camera of the loaded list, one after the other.
    Q_INVOKABLE void backupAll();
    // The backups saved for one camera (matched by address), newest first: a list of maps with file and label.
    Q_INVOKABLE QVariantList listBackups(const QString &ip) const;
    // Puts a backup back on the camera it came from (never another camera: the serial number must match).
    // Takes a fresh backup of the camera first, uploads the file, waits for the camera to restart and checks it
    // answers again. A non-empty user and password are used instead of the saved login. One login attempt only.
    Q_INVOKABLE void restoreCamera(const QString &ip, const QString &file, const QString &user, const QString &password);
    // The folder the backups are saved in.
    Q_INVOKABLE QString backupDir() const;
    // The camera's own switch for drawing the VCA rule lines and targets on the video stream (web page: VCA > Smart
    // Event > General Settings > Metadata > Enable Stream Rule / Sub-Stream). Both work on the camera's own address,
    // with the camera's saved login, one login attempt only. checkRuleLines only reads. setRuleLines reads first,
    // changes only "enabled" and "streamType", and reads it back. The answer comes in ruleLinesResult().
    Q_INVOKABLE void checkRuleLines(const QString &ip);
    Q_INVOKABLE void setRuleLines(const QString &ip, bool on);

signals:
    void camerasLoaded(const QVariantList &cameras);
    void progress(const QString &label, const QString &text);
    // summary is a short report; ok is false when something failed.
    void finished(const QString &summary, bool ok);
    void busyChanged();
    void ruleBusyChanged();
    // state is "on", "off", "unavailable" (the camera has no such switch) or "error"; message says what happened.
    void ruleLinesResult(const QString &ip, const QString &state, const QString &message);

public:
    struct Cam {
        QString name;
        QString ip;
        int httpPort = 80;
        QString user;
        QString pass;
        bool ownLogin = false; // a login saved for this camera, not the recorder's
    };
    struct Result {
        enum Kind { Saved, Skipped, Failed } kind = Failed;
        QString message;
    };

private:
    void runRuleLines(const QString &ip, int mode);
    void startLoad(const QByteArray &json, const QString &configPath);
    void start(const QList<Cam> &cams, bool single, const QString &overrideUser, const QString &overridePass);
    static Result backupOne(const Cam &cam, const QString &dir);
    static Result restoreOne(const Cam &cam, const QString &dir, const QString &fileName,
                             const std::function<void(const QString &)> &say);

    QList<Cam> m_cams;
    QString m_configPath;
    bool m_busy = false;
    QThread *m_worker = nullptr;
    QThread *m_loader = nullptr;
    QThread *m_ruleWorker = nullptr;
    bool m_ruleBusy = false;
    // A load asked for while another is running waits here (only the newest is kept), so it is never lost.
    bool m_hasPending = false;
    QByteArray m_pendingJson;
    QString m_pendingPath;
};

#endif // HIKVISIONBACKUP_H
