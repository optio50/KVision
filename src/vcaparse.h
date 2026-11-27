#ifndef VCAPARSE_H
#define VCAPARSE_H

#include <QPointF>
#include <QVector>
#include <QtGlobal>

// Byte walks for the Hikvision smart-data packets. No PlayCtrl calls: the geometry of an
// older rule still goes through the SDK parser in hikvisionvca.cpp. These functions are
// what the tests cover.

struct VcaSpan {
    int begin = 0;
    int end = 0;
};

struct VcaTargetBox {
    quint32 id = 0;
    float x = 0.f;
    float y = 0.f;
    float w = 0.f;
    float h = 0.f;
};

struct VcaRule {
    quint32 id = 0;
    bool polygon = false;
    QVector<QPointF> points;
};

struct VcaAlarmIds {
    enum Layout { None, G3, Legacy };
    Layout layout = None;
    quint32 rule = 0;
    quint32 target = 0;
};

// Bodies of an older rule list. `gap` is the run of zero bytes between rules
// (five on older cameras, four on a panoramic whose next rule may start with 0x00).
QVector<VcaSpan> ruleBodySpans(const unsigned char *p, int len, int gap);

// Byte offsets where a G3 rule starts (00 10 for a line, 40 20/30/38 for a zone).
QVector<int> g3RuleStarts(const unsigned char *p, int len);

// Valid boxes from a 0x0014 target list. False when the packet is too short to be one,
// in which case the caller keeps its previous sample.
bool decodeG3Targets(const unsigned char *p, int len, QVector<VcaTargetBox> *out);

// Kind-1 target packet whose scale word (bytes 14-15) is 0x2325. Linux PlayCtrl reads the
// rectangle and then stops. The Windows player reads six more bytes before the next target,
// which is what puts the second vehicle on the right bits. False when this is not that packet.
bool decodeIvs2325Targets(const unsigned char *p, int len, QVector<VcaTargetBox> *out);

// A kind-2 alarm packet. None when the tail does not match, or the packet is not an alarm.
VcaAlarmIds readVcaAlarm(const unsigned char *p, int len);

// A G3 rule list arrives in pieces. Rules missing from `got` stay in `rules`.
// True when a rule was added or its shape changed.
bool mergeKeptRules(QVector<VcaRule> *rules, const QVector<VcaRule> &got);

#endif
