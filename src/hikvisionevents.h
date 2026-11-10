#ifndef HIKVISIONEVENTS_H
#define HIKVISIONEVENTS_H

#include <QHash>
#include <QObject>
#include <QString>
#include <QTimer>

class QNetworkAccessManager;
class QNetworkReply;

// Listens to the motion/target events a Hikvision camera streams over HTTP
// (/ISAPI/Event/notification/alertStream) and reports which kind of target
// (human, vehicle, animal) the camera last saw. One connection per camera, shared by
// every tile that shows it. Cameras only send these when their motion detection is on.
class HikvisionEvents : public QObject
{
    Q_OBJECT

public:
    explicit HikvisionEvents(QObject *parent = nullptr);
    ~HikvisionEvents() override;

    // A tile calls watch() when it starts showing a camera and unwatch() when it stops.
    // The connection is opened by the first watcher and closed with the last.
    // name and configDir are only used for the detection log (configDir/logs/Detection.log).
    Q_INVOKABLE void watch(const QString &ip, int httpPort, const QString &user, const QString &pass,
                           const QString &name = QString(), const QString &configDir = QString());
    Q_INVOKABLE void unwatch(const QString &ip);
    // A tile calls this when it shows a detection frame, so logs/Frames.log records what was on screen.
    Q_INVOKABLE void logFrame(const QString &ip, const QString &text, int tile);

signals:
    // targetType is what the camera reported: "human", "vehicle", "animal" or "other".
    // source is empty for a labelled motion report, or LINE, INTRUSION, ENTER or EXIT for a smart event.
    void targetDetected(const QString &ip, const QString &targetType, const QString &source);
    // A motion report with no target type. Some cameras send the type only once per target, so a
    // tile uses these to keep a frame it is already showing alive.
    void motionDetected(const QString &ip);
    // The connection failed and will not be retried until a tile watches again.
    void listenFailed(const QString &ip, const QString &message);

private:
    struct Conn {
        QString ip;
        int httpPort = 80;
        QString user;
        QString pass;
        QString name;
        int watchers = 0;
        int failures = 0;
        bool authFailed = false; // the camera refused our login: never try again in this session
        QNetworkReply *reply = nullptr;
        QByteArray buffer;
        QTimer *retry = nullptr;
    };

    void open(const QString &ip);
    void onReadyRead(const QString &ip);
    void onFinished(const QString &ip, QNetworkReply *reply);
    void close(const QString &ip);
    void logDetection(const Conn *c, const QString &target, const QString &kind, const QString &cameraTime);

    QNetworkAccessManager *m_net = nullptr;
    QHash<QString, Conn *> m_conns;
    QString m_logDir; // where Detection.log is written; empty until a tile gives the config directory
};

#endif // HIKVISIONEVENTS_H
