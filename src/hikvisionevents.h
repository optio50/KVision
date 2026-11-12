#ifndef HIKVISIONEVENTS_H
#define HIKVISIONEVENTS_H

#include <QDateTime>
#include <QHash>
#include <QRectF>
#include <QSet>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QTimer>

class QNetworkAccessManager;
class QNetworkReply;
class QUrl;

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
    // recorderIp and recorderChannel say where this camera is played back from (the recorder it is
    // behind, or the camera itself), and are written to the detection log so an entry can be opened in
    // playback later.
    Q_INVOKABLE void watch(const QString &ip, int httpPort, const QString &user, const QString &pass,
                           const QString &name = QString(), const QString &configDir = QString(),
                           const QString &recorderIp = QString(), int recorderChannel = 0,
                           bool recorderMode = false);
    Q_INVOKABLE void unwatch(const QString &ip);

    // For a connection to a recorder (recorderMode): the name and address of each camera behind it, as a
    // JSON object {"17": {"name": "NVR Ch. 17 Garage3", "ip": "192.0.0.3"}, ...}. The detection log uses it
    // so a report for any channel is written under that camera, whether or not a tile shows it.
    Q_INVOKABLE void setChannelInfo(const QString &ip, const QString &json);
    // For a camera with more than one lens (one address, several channels), which recorder channel and name each of
    // the camera's own channels is, as JSON: {"1": {"name": "...", "channel": 14}, "2": {...}}. A report from the
    // camera's own stream names its own channel, and this turns it into the right camera for the detection log.
    Q_INVOKABLE void setLensInfo(const QString &ip, const QString &json);
    // A PTZ lens has started to follow a target the other lens named (target is human, vehicle, animal or other).
    // Writes a "Tracking" line to the detection log and keeps four snapshots of the PTZ lens (the first at once, then one a second apart), that the
    // log window offers with that line. lensChannel is the camera's own channel of the PTZ lens. Only for a camera
    // on its own connection; ignored if the same lens was logged in the last 10 seconds.
    Q_INVOKABLE void logTracking(const QString &ip, const QString &target, int lensChannel);

    // Which kinds of report may show a frame and be logged. kinds is a comma list of: motion, line,
    // intrusion, enter, exit, other (smart events not listed here). An empty list allows nothing.
    Q_INVOKABLE void setAllowedKinds(const QString &kinds);
    // Which targets may show a frame and be logged: a comma list of human, vehicle, animal, other.
    Q_INVOKABLE void setAllowedTargets(const QString &targets);
    // How many event pictures are kept for each camera (the newest ones). Older ones are deleted at once.
    Q_INVOKABLE void setMaxPictures(int count);
    // A tile calls this when it shows a detection frame, so logs/Frames.log records what was on screen.
    // name is the camera name the tile shows; without it the connection's name is used.
    Q_INVOKABLE void logFrame(const QString &ip, const QString &text, int tile, const QString &name = QString());
    // Newest-first entries from logs/Detection.log, skipping the first `skip`. Each entry is a map with
    // time, epochMs, target, kind, camera, ip, recorderIp, channel and received (empty unless the report
    // was read late). recorderIp is empty for lines without a recorder. The result
    // also says whether older entries remain. Reads from the end of the file, so it stays quick when the
    // log is large.
    // filterIp limits the entries to one camera address (empty for all); skip then counts only those.
    // The line, intrusion, entrance, exit and other smart events the detection log holds for one camera of a recorder
    // between two moments (milliseconds since 1970, this computer's local time as the log is written), as a list of
    // {startTime, endTime, kind} with kind line, intrusion, enter, exit or other. Plain motion and tracking lines are
    // left out. Used to draw what the camera reported on a playback timeline where the recorder saved less.
    // Copies a saved picture to another file (an existing file there is replaced) and returns true when it worked. Used to
    // save the picture on screen in the snapshot folder.
    Q_INVOKABLE bool copyPicture(const QString &fromPath, const QString &toPath) const;
    Q_INVOKABLE QVariantList logEventsBetween(const QString &recorderIp, int channel, qint64 startMs, qint64 endMs, const QString &configDir) const;
    // fromMs and toMs (milliseconds since 1970, 0 = no limit) limit the entries to a time range, target to one of human,
    // vehicle, animal or other (empty = all), and kinds is a list of the log's words for the type of event (such as
    // "Line crossing,Intrusion"; empty = every kind except plain labelled Motion). When any
    // filter is used the whole range is read and the result also carries "total", the number of matching entries.
    Q_INVOKABLE QVariantMap readDetections(int skip, int count, const QString &configDir, const QString &filterIp = QString(),
                                           qint64 fromMs = 0, qint64 toMs = 0, const QString &target = QString(), const QString &kinds = QString()) const;
    // What the newest event picture from a camera showed: a map with state ("on" if the picture carries the red
    // target frame, "off" if the camera sent a clean picture, empty if none has been seen since KVision started)
    // and time. address is the camera's own address. The picture is only looked at, never kept.
    Q_INVOKABLE QVariantMap pictureFrames(const QString &address) const;
    // The saved picture for a camera address at a moment (seconds since 1970), or an empty string if there is none.
    // The detection log entries carry this as "picture" already; this is for anything else that wants one.
    // A camera with more than one lens (one address, several channels) keeps each lens's pictures apart: lens is the
    // recorder channel of the lens, and the name becomes <address>_ch<lens>_<secs>.jpg. 0 means an ordinary camera.
    // kind (the log's word for the event, such as "Line crossing") is added to the name, so events of different kinds in
    // the same second keep their own pictures: <address>_ch14_<secs>-linecrossing.jpg. Empty for none.
    static QString picturePath(const QString &configDir, const QString &address, qint64 secs, int lens = 0, const QString &kind = QString());
    static QString pictureKey(const QString &address, int lens);

signals:
    // targetType is what the camera reported: "human", "vehicle", "animal" or "other".
    // source says what kind of report it was: MOTION for a labelled motion report, or LINE, INTRUSION,
    // ENTER or EXIT for a smart event.
    // channel is the channel number in the report. For a camera behind a recorder that streams its own
    // events it is 1, and for a recorder connection it is the recorder channel; a tile matches on both.
    void targetDetected(const QString &ip, const QString &targetType, const QString &source, int channel);
    // A motion report with no target type. Some cameras send the type only once per target, so a
    // tile uses these to keep a frame it is already showing alive.
    void motionDetected(const QString &ip, int channel);
    // A PTZ camera leaves its park position (preset) to follow a target the other lens saw, or comes back to it. channel
    // is the camera's own channel of the PTZ lens. tracking is true when it leaves and false when it is back.
    void trackingChanged(const QString &ip, int channel, bool tracking);
    // The PTZ lens reported where it points (about once a second while it moves).
    void ptzMoved(const QString &ip, int channel);
    // The connection failed and will not be retried until a tile watches again.
    void listenFailed(const QString &ip, const QString &message);

private:
    struct Conn {
        QString ip;
        int httpPort = 80;
        QString user;
        QString pass;
        QString name;
        QString recIp;      // recorder this camera is played back from
        int recChannel = 0; // and its channel there
        bool recorderMode = false; // this connection is to a recorder, and its reports name the channel
        struct ChanInfo { QString name; QString ip; };
        QHash<int, ChanInfo> chanInfo;
        struct Lens { QString name; int channel = 0; };
        QHash<int, Lens> lens; // a multi-lens camera on its own connection: its own channel -> camera name and recorder channel
        int watchers = 0;
        int failures = 0;
        bool authFailed = false; // the camera refused our login: never try again in this session
        QNetworkReply *reply = nullptr;
        QByteArray buffer;
        int jsonScanned = 0; // how much of the buffer has been searched for PTZ JSON messages already
        QTimer *retry = nullptr;
        QTimer *watchdog = nullptr; // fires when nothing has arrived for too long: a stalled stream is reopened
        qint64 openedMs = 0;        // when the stream was last opened
        bool unsupported = false;   // the device has no event stream (HTTP 404/405/501): do not ask again
        // The target rectangle (0..1) of the last smart event, waiting for the picture that follows it.
        bool pendingValid = false;  // a picture is expected after the last smart event
        bool pendingHasRect = false; // and the event named where the target is
        QRectF pendingRect;
        QString pendingAddress;
        QString pendingKind;         // what the event was, for the picture's file name
        int pendingLens = 0;         // the lens's recorder channel when the camera has more than one, else 0
        qint64 pendingSecs = 0;      // the event's time, which names the saved picture
        bool pictureRefused = false; // the recorder refused the login for a picture: never ask again this session
        int pictureFetches = 0;      // picture downloads in progress
    };
    struct PictureVerdict {
        bool on = false;
        QDateTime when;
    };

    void open(const QString &ip);
    void onReadyRead(const QString &ip);
    void onFinished(const QString &ip, QNetworkReply *reply);
    void close(const QString &ip);
    void logDetection(const Conn *c, const QString &target, const QString &kind, const QString &cameraTime, int eventChannel);
    // Looks for the picture that follows an event in `data`, and records whether it carries the target frame.
    // Returns true if a whole picture was there (so the event is done with).
    bool judgePicture(Conn *c, const QByteArray &data);
    // Remembers the target rectangle an event names, so the picture that follows it can be judged.
    void notePictureRect(Conn *c, const QString &body, int eventChannel, const QString &cameraTime, const QString &kind);
    // A recorder sends a link to the picture instead of the picture. Downloads it with the connection's login
    // (one try, and only from the connection's own address), then keeps and judges it like an attached one.
    void fetchPicture(const QString &ip, const QUrl &url, const QString &address, int lens, const QString &kind, qint64 secs, bool hasRect, const QRectF &rect);
    void judgeJpeg(const QString &address, bool hasRect, const QRectF &rect, const QByteArray &jpeg);
    void savePicture(const QString &address, int lens, const QString &kind, qint64 secs, const QByteArray &jpeg);
    void takeSnapshot(const QString &ip, int cameraChannel, qint64 secs);
    QHash<QString, qint64> m_lastTrack; // when a lens last logged a track (ms), to ignore a second tile of the same camera
    int pictureLens(const Conn *c, int eventChannel) const;
    // Keeps the newest m_maxPictures pictures of each camera in logs/pictures (or of one camera) and deletes the older ones.
    void prunePictures(const QString &dirPath, const QString &key);
    QString cameraAddress(const Conn *c, int eventChannel) const;

    QNetworkAccessManager *m_net = nullptr;
    int m_maxPictures = 100;
    QHash<QString, Conn *> m_conns;
    QSet<QString> m_allowedKinds{QStringLiteral("motion"), QStringLiteral("line"), QStringLiteral("intrusion"),
                                 QStringLiteral("enter"), QStringLiteral("exit"), QStringLiteral("other")};
    QSet<QString> m_allowedTargets{QStringLiteral("human"), QStringLiteral("vehicle"), QStringLiteral("animal"),
                                   QStringLiteral("other")};
    QHash<QString, PictureVerdict> m_pictures; // by camera address
    QString m_logDir; // where Detection.log is written; empty until a tile gives the config directory
};

#endif // HIKVISIONEVENTS_H
