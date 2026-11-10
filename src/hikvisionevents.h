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
    Q_INVOKABLE void watch(const QString &ip, int httpPort, const QString &user, const QString &pass);
    Q_INVOKABLE void unwatch(const QString &ip);

signals:
    // targetType is what the camera reported: "human", "vehicle", "animal" or "other".
    void targetDetected(const QString &ip, const QString &targetType);
    // The connection failed and will not be retried until a tile watches again.
    void listenFailed(const QString &ip, const QString &message);

private:
    struct Conn {
        QString ip;
        int httpPort = 80;
        QString user;
        QString pass;
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

    QNetworkAccessManager *m_net = nullptr;
    QHash<QString, Conn *> m_conns;
};

#endif // HIKVISIONEVENTS_H
