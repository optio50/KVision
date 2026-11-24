#ifndef HIKVISIONVCA_H
#define HIKVISIONVCA_H

#include <QByteArray>
#include <QHash>
#include <QPointF>
#include <QRectF>
#include <QVector>
#include <deque>
#include <mutex>

class QPainter;

// A video PTS more than a second behind the latched base is a new timeline: the camera restarted its
// 90 kHz clock (a time step, or the 33-bit value wrapped). Target time is measured from that base, so a
// stamp behind it is negative and the live overlay would ignore every later box.
inline qint64 vcaRebasedVideoPts(qint64 basePts, qint64 videoPts)
{
    constexpr qint64 kRestartTicks = 90 * 1000; // one second at 90 kHz
    if (videoPts < 0)
        return basePts;
    if (basePts < 0 || videoPts + kRestartTicks < basePts)
        return videoPts;
    return basePts;
}

// The smart (VCA) data a Hikvision camera sends next to its video, in recordings and in an SDK live
// stream alike: the rule lines and zones, every tracked target's box, and an alarm event when a rule
// fires (named by rule and target). Fed raw MPEG-PS bytes; decoded with PlayCtrl's own parsers.
// Used by the archive player (boxes matched to each decoded frame) and the live overlay.
// Thread safe: feed() and the readers may run on different threads.
class HikVcaDecoder
{
public:
    struct Target { quint32 id; QRectF rect; bool alarm; };
    struct Sample { qint64 ms; QVector<Target> targets; QVector<quint32> alarmRules; }; // alarmRules: rules set off here
    struct Rule { quint32 id; bool polygon; QVector<QPointF> points; };

    // Raw stream bytes (the SDK data callback's NET_DVR_STREAMDATA).
    void feed(const unsigned char *data, int size);
    void reset();

    // Stream time (ms from the first video frame) of the newest target report; -1 if none yet.
    qint64 latestMs() const;
    // Bumps each time the rule list is replaced. A rule packet does not move latestMs(), so a live
    // overlay that is drawing lines and not boxes watches this to know it should paint.
    quint64 rulesSerial() const;
    QVector<Rule> rules() const;
    // The newest report at or before stampMs, if no older than holdMs. False when there is none.
    bool sampleAt(qint64 stampMs, int holdMs, Sample *out) const;
    // The two newest reports (for smoothing a live box between reports). False when there are fewer than one.
    bool latestTwo(Sample *older, Sample *newer) const;
    // Every target seen in the reports of the last holdMs before atMs, each with its newest box, the box
    // from its report before that (for smoothing; the same box if there is none) and when it was last seen.
    // A camera does not list every target in every report (a G3 alternates), so a target is kept until it
    // has been missing for holdMs.
    struct Track { Target target; QRectF previous; qint64 lastMs; qint64 previousMs; };
    QVector<Track> tracks(qint64 atMs, int holdMs, QVector<quint32> *alarmRules = nullptr) const;

    // Rule lines and zones in blue (a rule in alarm in red), then each target box green or red (iVMS-4200 colours).
    // Points are fractions of the picture; videoRect is where the picture is drawn.
    static void draw(QPainter *painter, const QRectF &videoRect, const QVector<Rule> &rules, bool drawRules,
                     const QVector<Target> &targets, const QVector<quint32> &alarmRules);

private:
    struct Alarm { quint32 rule; qint64 since; qint64 outsideSince; };
    void handlePacket(const unsigned char *p, int len, qint64 pts);
    void handleTargetList(const unsigned char *p, int len, qint64 ms); // newer (G3) target records
    void addSample(const Sample &sample);
    bool targetInAlarm(quint32 tid, const QRectF &box, qint64 ms);

    mutable std::mutex m_mutex;     // guards everything below
    QByteArray m_carry;             // unfinished PS packet from the previous feed
    qint64 m_videoBasePts = -1;     // PTS of the first video frame: stream time 0
    std::deque<Sample> m_samples;
    QVector<Rule> m_rules;
    quint64 m_rulesSerial = 0;
    QHash<quint32, Alarm> m_alarms; // target id -> the rule it set off
};

#endif // HIKVISIONVCA_H
