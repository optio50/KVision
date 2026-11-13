#ifndef HIKVISIONCAMERAINFO_H
#define HIKVISIONCAMERAINFO_H

#include <QList>
#include <QMap>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class QThread;

// Reads a camera's settings, read only, for the "Camera settings" window. Each camera is reached on its own address
// (a camera behind a recorder is found through the recorder's channel list; the recorder is not read). Nothing here
// ever writes to a camera. A section is left out when the camera does not offer it, so old cameras simply show less.
class HikvisionCameraInfo : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)

public:
    explicit HikvisionCameraInfo(QObject *parent = nullptr);
    ~HikvisionCameraInfo() override;

    bool busy() const { return m_busy; }

    // Works out the camera list from the saved recorders and emits camerasLoaded(): maps with name, ip, user.
    Q_INVOKABLE void loadCameras(const QString &recordersJson, const QString &configPath);
    // Reads one camera (an address from the list). Emits cameraRead(ip, sections) with a list of
    // {title, rows:[{label, value}], schedule?:[{label, days:[[{from,to}...] x7]}]}, or readFailed(ip, why).
    Q_INVOKABLE void readCamera(const QString &ip, const QString &user, const QString &password);
    // Reads every camera in the list one after the other and emits overviewRead(rows) once, where each row is
    // {name, ip, audio, light, motion, intrusion, line, model, firmware, error}. Used for the all-cameras table.
    Q_INVOKABLE void readOverview();
    // The same data as plain text, for copying.
    Q_INVOKABLE QString sectionsToText(const QVariantList &sections) const;
    // The all-cameras table as text: a header line, then one line per camera, columns separated by tabs so it pastes
    // straight into a spreadsheet.
    Q_INVOKABLE QString overviewToText(const QVariantList &rows) const;

signals:
    void camerasLoaded(const QVariantList &cameras);
    void cameraRead(const QString &ip, const QVariantList &sections);
    void readFailed(const QString &ip, const QString &why);
    void overviewProgress(int done, int total);
    void overviewRead(const QVariantList &rows);
    void busyChanged();

public:
    struct Cam {
        QString name;
        QString ip;
        int httpPort = 80;
        QString user;
        QString pass;
        // The recorder it sits behind, and its channel numbers there (empty for a camera on its own).
        QString recIp;
        int recPort = 80;
        QString recUser;
        QString recPass;
        QList<int> channels;
        QMap<int, QString> chanNames;     // this camera's own channels
        QMap<int, QString> recChanNames;  // every channel of the recorder, to name the cameras that link to it
    };

private:
    void startLoad(const QByteArray &json, const QString &configPath);

    QList<Cam> m_cams;
    QString m_configPath;
    bool m_busy = false;
    QThread *m_worker = nullptr;
    QThread *m_loader = nullptr;
    bool m_hasPending = false;
    QByteArray m_pendingJson;
    QString m_pendingPath;
};

#endif // HIKVISIONCAMERAINFO_H
