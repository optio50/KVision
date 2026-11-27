#ifndef EVENTALERT_H
#define EVENTALERT_H

#include <QDateTime>
#include <QSet>
#include <QString>
#include <QVector>

// One <EventNotificationAlert> inside a detection-stream buffer.
// start and end are indexes in the QString the caller built with an explicit length,
// so a zero byte inside a picture does not hide the next alert.
struct EventAlertSpan {
    int start = 0;
    int end = 0;
    QString body;
};

QVector<EventAlertSpan> splitEventAlerts(const QString &text);

// True when the camera's timestamp is at least 10 seconds behind `now`.
// An invalid timestamp is not late.
bool eventReportIsLate(const QString &cameraTime, const QDateTime &now);

// What one alert asks the tile and the log to do. Logging, pictures and the quiet-period
// for plain motion stay with the caller. This only reads the XML.
struct EventAlert {
    enum Action { None, Face, Other, Smart, PlainMotion, LabelledMotion };
    enum Frame { NoFrame, Keep, Flash };

    Action action = None;
    Frame frame = NoFrame;
    bool active = false;
    QString type;
    QString target;
    QString logKind;
    QString shortLabel;
    QString cameraTime;
    QString state;
    int channel = 0;
};

EventAlert classifyEventAlert(const QString &body, const QSet<QString> &kinds, const QSet<QString> &targets,
                              bool frameMotion, const QDateTime &now);

// One zone from a camera's saved line or area rule. points is x, y, x, y... as a fraction of the
// picture, with Y measured from the top. The rule document itself measures Y from the bottom.
struct ZonePolygon {
    int id = 0;
    QVector<double> points;
};

// The corners of every zone in a region, intrusion or line document. A zone with no corners is left out.
QVector<ZonePolygon> zonePolygonsFromRule(const QString &xml);

// Some cameras name only the first four corners in the alert. Closing those draws a small shape that is
// not the region on the camera's rule page. When the alert's corners are the start of the saved rule,
// the rule is the zone that was configured. A rule that no longer starts the same way is left alone,
// and so is a camera that already sent the whole shape.
QVector<double> completedZone(const QVector<double> &alertPoly, const QVector<double> &rulePoly);

// One G3 "faceCapture" JSON alert. These cameras send this instead of the XML "facedetection"
// alert, and the JPEGs follow it in the same stream. end is the index just past the object.
struct FaceCaptureEvent {
    int start = 0;
    int end = 0;
    bool active = false;
    QString cameraTime;
    int channel = 0;
    bool hasRect = false;
    double x = 0;
    double y = 0;
    double w = 0;
    double h = 0;
    // An NVR sends the pictures as links. A camera leaves these empty and attaches the JPEGs instead.
    QString sceneUrl;
    QString faceUrl;
};

QVector<FaceCaptureEvent> splitFaceCaptures(const QString &text);

// A finished JPEG that follows a face capture. background is the wide shot the face rectangle
// refers to. face is the camera's capture of the person, which may be a face or a full body.
struct FaceJpeg {
    int start = 0;
    int end = 0;
    bool background = false;
    bool face = false;
};

QVector<FaceJpeg> faceCaptureJpegs(const QByteArray &data);

#endif
