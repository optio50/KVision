#include "hikvisionvca.h"
#include "vcaparse.h"

#include <QPainter>
#include <QPolygonF>
#include <algorithm>
#include <cstring>

// PlayCtrl's own parsers for the smart (VCA) data a Hikvision camera writes into its recordings.
// They are exported from libPlayCtrl.so with C linkage but are not in plaympeg4.h.
// The bit reader they take: a pointer at +8 and the byte count at +0x10/+0x14; the rest is their scratch space.
extern "C" int IVS_META_DATA_sys_parse(void *out, void *in);
extern "C" int IVS_RULE_DATA_sys_parse(void *out, void *in);
namespace {
struct IvsBitReader {
    quint64 scratch;
    const unsigned char *data;
    quint32 size1;
    quint32 size2;
    quint64 pad[4];
};
constexpr int kIvsTargetRecord = 28;   // IVS_META_DATA_sys_parse: count byte, then 28-byte records from +8
constexpr int kIvsRuleRecord = 184;    // IVS_RULE_DATA_sys_parse: count dword, then 184-byte records from +4
constexpr int kVcaHoldMs = 400;        // a box with no newer report is dropped after this
// A target box is red while that target has set off a rule, green otherwise (as iVMS-4200).
// The camera writes an alarm event packet when a rule fires, naming the rule and the target.
// For a zone the box stays red while the target is inside it; for a line it stays red this long.
constexpr int kVcaLineAlarmMs = 2000;
// A target that steps out of its alarm zone turns green after this long outside (no flicker at the edge).
constexpr int kVcaZoneLeaveMs = 500;

// One rule from a kind-3 list. [begin, end) is the rule body; the parser wants the scale from the
// packet and five trailing zero bytes (the on-wire separator is not part of the body).
bool parseOneRule(const unsigned char *packet, const unsigned char *begin, const unsigned char *end, HikVcaDecoder::Rule *rule)
{
    if (end <= begin)
        return false;
    QByteArray in;
    in.append('\xff').append('\xff').append(static_cast<char>(packet[14])).append(static_cast<char>(packet[15]));
    in.append('\x01').append('\x00');
    in.append(reinterpret_cast<const char *>(begin), int(end - begin));
    in.append(QByteArray(5, '\0'));
    const int inLen = in.size();
    in.append(QByteArray(64, '\0'));
    alignas(16) unsigned char out[4 + 2 * kIvsRuleRecord + 64];
    std::memset(out, 0, sizeof(out));
    IvsBitReader reader;
    std::memset(&reader, 0, sizeof(reader));
    reader.data = reinterpret_cast<const unsigned char *>(in.constData());
    reader.size1 = reader.size2 = static_cast<quint32>(inLen);
    if (IVS_RULE_DATA_sys_parse(out, &reader) != 1)
        return false;
    const unsigned char *rec = out + 4;
    quint32 points;
    std::memcpy(&points, rec + 0x64, 4);
    if (points < 2 || points > 10)
        return false;
    HikVcaDecoder::Rule got;
    got.id = rec[0];
    got.polygon = rec[2] == 1;
    for (quint32 q = 0; q < points; ++q) {
        float x, y;
        std::memcpy(&x, rec + 0x68 + 8 * q, 4);
        std::memcpy(&y, rec + 0x6c + 8 * q, 4);
        if (!(x >= 0.f && x <= 1.001f && y >= 0.f && y <= 1.001f))
            return false;
        got.points.append(QPointF(x, y));
    }
    *rule = got;
    return true;
}

// Split a kind-3 rule list. `gap` is how many zero bytes separate rules (five on older cameras,
// four on the panoramic above). The byte after the gap belongs to the next rule.
QVector<HikVcaDecoder::Rule> parseRuleList(const unsigned char *p, int len, int gap)
{
    QVector<HikVcaDecoder::Rule> rules;
    const QVector<VcaSpan> spans = ruleBodySpans(p, len, gap);
    for (const VcaSpan &span : spans) {
        HikVcaDecoder::Rule rule;
        if (parseOneRule(p, p + span.begin, p + span.end, &rule))
            rules.append(rule);
    }
    return rules;
}

// A G3 rule list (data type 0x30) does not separate rules with a plain run of zero bytes. Each rule
// starts with 00 10 (a line) or 40 20/30/38 (a zone). Packets leave a rule out from time to time,
// so the caller keeps rules already seen.
QVector<HikVcaDecoder::Rule> parseG3RuleList(const unsigned char *p, int len)
{
    QVector<HikVcaDecoder::Rule> rules;
    const QVector<int> starts = g3RuleStarts(p, len);
    for (int k = 0; k < starts.size(); ++k) {
        int begin = starts[k];
        int end = (k + 1 < starts.size()) ? starts[k + 1] : len;
        while (end > begin && p[end - 1] == 0)
            --end;
        HikVcaDecoder::Rule rule;
        if (parseOneRule(p, p + begin, p + end, &rule))
            rules.append(rule);
    }
    return rules;
}
}

// ---------------------------------------------------------------------------------------------
// Smart (VCA) overlay: rule lines/zones and target boxes recorded in the stream, as in iVMS-4200.
//
// The recording is an MPEG-PS. Next to the video (stream 0xE0) the camera writes private-stream
// (0xBD) packets with a Hikvision header: bytes 0-1 = 0x0003 for intelligent data, byte 5 =
// 1 for the target list, 3 for the rule list. Bytes 14-15 carry the coordinate scale; the data
// starts at byte 22. PlayCtrl's parsers read it after a 4-byte {0xffff, scale} prefix:
//  - targets: IVS_META_DATA_sys_parse -> count (byte 0), then 28-byte records from +8:
//      +0 id, +12 x, +16 y, +20 width, +24 height (floats 0..1 of the picture)
//    Scale 0x2325 (this panoramic substream) carries six extra bytes after each
//    rectangle. Linux PlayCtrl leaves those unread, so only the first vehicle
//    survives. decodeIvs2325Targets reads them the way the Windows player does.
//  - rules:   IVS_RULE_DATA_sys_parse on one rule at a time. Older cameras end each rule with five
//      zero bytes. A panoramic (DT387G2P) ends each rule with four, and the next rule may start
//      with 0x00, which looks like a fifth zero. +4 record: byte 0 id, byte 2 kind (0 = line,
//      1 = zone), +0x64 point count, +0x68 x/y floats
// A packet's PTS minus the first video PTS is the decoder stamp (FRAME_INFO::nStamp) of its frame.
// ---------------------------------------------------------------------------------------------

static qint64 psPts(const unsigned char *pes)
{
    if (!(pes[7] & 0x80))
        return -1;
    const unsigned char *b = pes + 9;
    return (static_cast<qint64>((b[0] >> 1) & 7) << 30) | (static_cast<qint64>(b[1]) << 22)
         | (static_cast<qint64>(b[2] >> 1) << 15) | (static_cast<qint64>(b[3]) << 7) | (b[4] >> 1);
}

void HikVcaDecoder::reset()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_carry.clear();
    m_videoBasePts = -1;
    m_samples.clear();
    m_rules.clear();
    ++m_rulesSerial;
    m_alarms.clear();
}

void HikVcaDecoder::feed(const unsigned char *data, int size)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_carry.append(reinterpret_cast<const char *>(data), size);
    const unsigned char *buf = reinterpret_cast<const unsigned char *>(m_carry.constData());
    const int n = m_carry.size();
    int pos = 0;
    int keepFrom = n;
    while (pos + 4 <= n) {
        if (!(buf[pos] == 0 && buf[pos + 1] == 0 && buf[pos + 2] == 1)) {
            ++pos;
            continue;
        }
        const unsigned char id = buf[pos + 3];
        if (id == 0xBA) { // pack header: 14 bytes plus stuffing
            if (pos + 14 > n) { keepFrom = pos; break; }
            pos += 14 + (buf[pos + 13] & 0x07);
            continue;
        }
        if (id < 0xBB) { // not a PES start code (e.g. a start code inside the video data)
            pos += 3;
            continue;
        }
        if (pos + 9 > n) { keepFrom = pos; break; }
        const int pesLen = (buf[pos + 4] << 8) | buf[pos + 5];
        // Video data can contain bytes that look like a start code ("00 00 01 bd" inside a picture). A real
        // video or private-stream header has the MPEG-2 marker bits (10xx xxxx) and a header length that
        // fits; anything else is skipped, so it cannot inject a nonsense time stamp (which made every box
        // vanish about every 30 seconds).
        if ((id == 0xE0 || id == 0xBD)
                && ((buf[pos + 6] & 0xC0) != 0x80 || pesLen < 3 + buf[pos + 8] || pesLen < 8)) {
            pos += 3;
            continue;
        }
        const int total = 6 + pesLen;
        if (pos + total > n) { keepFrom = pos; break; }
        if ((id == 0xE0 || id == 0xBD) && pesLen >= 8) {
            const qint64 pts = psPts(buf + pos);
            if (id == 0xE0) {
                const qint64 base = vcaRebasedVideoPts(m_videoBasePts, pts);
                if (base != m_videoBasePts) {
                    // Reports already stored were measured from the old base.
                    if (m_videoBasePts >= 0) {
                        m_samples.clear();
                        m_alarms.clear();
                    }
                    m_videoBasePts = base;
                }
            } else {
                const int hl = buf[pos + 8];
                const int payload = pesLen - 3 - hl;
                if (payload > 0 && pts >= 0)
                    handlePacket(buf + pos + 9 + hl, payload, pts);
            }
        }
        pos += total;
    }
    if (keepFrom >= n)
        m_carry.clear();
    else
        m_carry.remove(0, keepFrom);
    if (m_carry.size() > 512 * 1024)
        m_carry.clear(); // lost sync; start again
}

// Newer cameras (G3 series, data type 0x3000/0x3101) send their targets as plain records instead:
// a 0x0014 packet, 12-byte header, then from byte 12: ..., byte 26 = record count, records from byte 36,
// each 28 bytes (u32 id, u8 class, 3 bytes, float x, y, width, height (fractions of the picture), 4 bytes)
// with a 4-byte gap between records.
void HikVcaDecoder::handleTargetList(const unsigned char *p, int len, qint64 ms)
{
    QVector<VcaTargetBox> boxes;
    if (!decodeG3Targets(p, len, &boxes))
        return;
    Sample sample;
    sample.ms = ms;
    for (const VcaTargetBox &box : boxes) {
        const QRectF rect(box.x, box.y, box.w, box.h);
        const bool alarm = targetInAlarm(box.id, rect, ms);
        if (alarm) {
            const auto a = m_alarms.constFind(box.id);
            if (a != m_alarms.constEnd() && a->rule != 0 && !sample.alarmRules.contains(a->rule))
                sample.alarmRules.append(a->rule);
        }
        sample.targets.append({box.id, rect, alarm});
    }
    addSample(sample);
}

void HikVcaDecoder::addSample(const Sample &sample)
{
    // Keep the samples in stamp order; the same report is often sent twice.
    if (!m_samples.empty() && m_samples.back().ms > sample.ms) {
        m_samples.clear(); // went backwards: a new position in the stream
        m_alarms.clear();
    }
    if (!m_samples.empty() && m_samples.back().ms == sample.ms)
        m_samples.back() = sample;
    else
        m_samples.push_back(sample);
    while (m_samples.size() > 600)
        m_samples.pop_front();
}

void HikVcaDecoder::handlePacket(const unsigned char *p, int len, qint64 pts)
{
    if (m_videoBasePts < 0 || len < 24)
        return;
    if (p[0] == 0x00 && p[1] == 0x14) {
        handleTargetList(p, len, (pts - m_videoBasePts) / 90);
        return;
    }
    if (p[0] != 0x00 || p[1] != 0x03)
        return;
    const int kind = p[5];
    const bool newFormat = p[14] == 0x30; // G3 series: data type 0x30xx
    if (kind == 2) {
        // Alarm event. A G3 names the target and not the rule. An older camera names both.
        const VcaAlarmIds alarm = readVcaAlarm(p, len);
        const qint64 ms = (pts - m_videoBasePts) / 90;
        if (alarm.layout == VcaAlarmIds::G3) {
            if (alarm.target != 0)
                m_alarms.insert(alarm.target, {0, ms, -1});
        } else if (alarm.layout == VcaAlarmIds::Legacy) {
            if (alarm.target != 0 && alarm.rule != 0)
                m_alarms.insert(alarm.target, {alarm.rule, ms, -1});
        }
        return;
    }
    if (kind == 1 && newFormat)
        return; // a G3 sends its boxes in the 0x0014 target list; this packet is a different layout
    if (kind == 1 && p[14] == 0x23 && p[15] == 0x25) {
        const qint64 ms = (pts - m_videoBasePts) / 90;
        QVector<VcaTargetBox> boxes;
        if (!decodeIvs2325Targets(p, len, &boxes))
            return;
        if (!m_samples.empty() && m_samples.back().ms > ms)
            m_alarms.clear();
        Sample sample;
        sample.ms = ms;
        for (const VcaTargetBox &box : boxes) {
            const QRectF rect(box.x, box.y, box.w, box.h);
            const bool alarm = targetInAlarm(box.id, rect, ms);
            if (alarm) {
                const auto a = m_alarms.constFind(box.id);
                if (a != m_alarms.constEnd() && !sample.alarmRules.contains(a->rule))
                    sample.alarmRules.append(a->rule);
            }
            sample.targets.append({box.id, rect, alarm});
        }
        addSample(sample);
        return;
    }
    if (kind == 1) {
        const qint64 ms = (pts - m_videoBasePts) / 90;
        QByteArray in;
        in.append('\xff').append('\xff').append(static_cast<char>(p[14])).append(static_cast<char>(p[15]));
        in.append(reinterpret_cast<const char *>(p + 22), len - 22);
        const int inLen = in.size();
        in.append(QByteArray(64, '\0'));
        alignas(16) unsigned char out[8 + 32 * kIvsTargetRecord + 64];
        std::memset(out, 0, sizeof(out));
        IvsBitReader reader;
        std::memset(&reader, 0, sizeof(reader));
        reader.data = reinterpret_cast<const unsigned char *>(in.constData());
        reader.size1 = reader.size2 = static_cast<quint32>(inLen);
        if (IVS_META_DATA_sys_parse(out, &reader) != 1)
            return;
        const int count = std::min<int>(out[0], 30);
        if (!m_samples.empty() && m_samples.back().ms > ms)
            m_alarms.clear(); // went backwards: a new position in the stream
        Sample sample;
        sample.ms = ms;
        for (int i = 0; i < count; ++i) {
            const unsigned char *rec = out + 8 + kIvsTargetRecord * i;
            quint32 tid;
            float x, y, w, h;
            std::memcpy(&tid, rec, 4);
            std::memcpy(&x, rec + 12, 4);
            std::memcpy(&y, rec + 16, 4);
            std::memcpy(&w, rec + 20, 4);
            std::memcpy(&h, rec + 24, 4);
            // A real target has an id and a sensible box; anything else is another record type.
            if (tid == 0 || !(w > 0.002f && h > 0.002f && x >= 0.f && y >= 0.f && x + w <= 1.01f && y + h <= 1.01f))
                continue;
            const bool alarm = targetInAlarm(tid, QRectF(x, y, w, h), ms);
            if (alarm) {
                // The zone or line this target set off is drawn red too, so it shows where the alarm came from.
                const auto a = m_alarms.constFind(tid);
                if (a != m_alarms.constEnd() && !sample.alarmRules.contains(a->rule))
                    sample.alarmRules.append(a->rule);
            }
            sample.targets.append({tid, QRectF(x, y, w, h), alarm});
        }
        addSample(sample);
        return;
    }
    if (kind != 3)
        return;
    if (newFormat) {
        // A G3 sends the rule list in pieces, so a rule missing from this packet is kept.
        const QVector<Rule> gotRules = parseG3RuleList(p, len);
        QVector<VcaRule> got;
        got.reserve(gotRules.size());
        for (const Rule &n : gotRules) {
            VcaRule rule;
            rule.id = n.id;
            rule.polygon = n.polygon;
            rule.points = n.points;
            got.append(rule);
        }
        QVector<VcaRule> kept;
        kept.reserve(m_rules.size());
        for (const Rule &old : m_rules) {
            VcaRule rule;
            rule.id = old.id;
            rule.polygon = old.polygon;
            rule.points = old.points;
            kept.append(rule);
        }
        if (mergeKeptRules(&kept, got)) {
            m_rules.clear();
            for (const VcaRule &rule : kept)
                m_rules.append(Rule{rule.id, rule.polygon, rule.points});
            ++m_rulesSerial;
        }
        return;
    }

    // Rule list (sent about once a second). Older cameras separate rules with five zero bytes.
    // These panoramics separate them with four, and the next rule may itself start with 0x00, so a
    // five-zero split keeps only the first rule. Keep whichever reading produces more rules.
    QVector<Rule> rules = parseRuleList(p, len, 5);
    const QVector<Rule> four = parseRuleList(p, len, 4);
    if (four.size() > rules.size())
        rules = four;
    if (!rules.isEmpty()) {
        m_rules = rules;
        ++m_rulesSerial;
    }
}


bool HikVcaDecoder::targetInAlarm(quint32 tid, const QRectF &box, qint64 ms)
{
    auto it = m_alarms.find(tid);
    if (it == m_alarms.end())
        return false;
    if (ms < it->since)
        return false; // a report from before the alarm (they can arrive slightly out of order)
    const Rule *rule = nullptr;
    for (const Rule &r : m_rules) {
        if (r.id == it->rule) {
            rule = &r;
            break;
        }
    }
    if (!rule || !rule->polygon || rule->points.size() < 3) {
        // A line (or a rule not known yet): red for a short while after it fired.
        if (ms - it->since <= kVcaLineAlarmMs)
            return true;
        m_alarms.erase(it);
        return false;
    }
    // A zone: red while the target's feet (bottom middle of its box) are inside it.
    const QPointF feet(box.center().x(), box.bottom());
    if (QPolygonF(rule->points).containsPoint(feet, Qt::OddEvenFill)) {
        it->outsideSince = -1;
        return true;
    }
    if (it->outsideSince < 0)
        it->outsideSince = ms;
    if (ms - it->outsideSince <= kVcaZoneLeaveMs)
        return true;
    m_alarms.erase(it); // left the zone: green until the camera sends a new alarm
    return false;
}


qint64 HikVcaDecoder::latestMs() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_samples.empty() ? -1 : m_samples.back().ms;
}

quint64 HikVcaDecoder::rulesSerial() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_rulesSerial;
}

QVector<HikVcaDecoder::Rule> HikVcaDecoder::rules() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_rules;
}

bool HikVcaDecoder::sampleAt(qint64 stampMs, int holdMs, Sample *out) const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (stampMs < 0)
        return false;
    for (auto it = m_samples.rbegin(); it != m_samples.rend(); ++it) {
        if (it->ms <= stampMs) {
            if (stampMs - it->ms > holdMs)
                return false;
            *out = *it;
            return true;
        }
    }
    return false;
}

bool HikVcaDecoder::latestTwo(Sample *older, Sample *newer) const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_samples.empty())
        return false;
    *newer = m_samples.back();
    *older = m_samples.size() >= 2 ? m_samples[m_samples.size() - 2] : m_samples.back();
    return true;
}

QVector<HikVcaDecoder::Track> HikVcaDecoder::tracks(qint64 atMs, int holdMs, QVector<quint32> *alarmRules) const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    QVector<Track> out;
    QHash<quint32, int> index;
    for (auto it = m_samples.rbegin(); it != m_samples.rend(); ++it) {
        if (it->ms > atMs)
            continue;
        if (atMs - it->ms > holdMs)
            break;
        for (const Target &t : it->targets) {
            const auto found = index.constFind(t.id);
            if (found == index.constEnd()) {
                index.insert(t.id, out.size());
                out.append({t, t.rect, it->ms, -1});
            } else if (out[*found].previousMs < 0) {
                out[*found].previous = t.rect;
                out[*found].previousMs = it->ms;
            }
        }
        if (alarmRules) {
            for (quint32 r : it->alarmRules) {
                if (!alarmRules->contains(r))
                    alarmRules->append(r);
            }
        }
    }
    return out;
}

void HikVcaDecoder::draw(QPainter *painter, const QRectF &videoRect, const QVector<Rule> &rules, bool drawRules,
                         const QVector<Target> &targets, const QVector<quint32> &alarmRules)
{
    if ((!drawRules || rules.isEmpty()) && targets.isEmpty())
        return;
    auto toView = [&videoRect](const QPointF &pt) {
        return QPointF(videoRect.x() + pt.x() * videoRect.width(), videoRect.y() + pt.y() * videoRect.height());
    };
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing, true);
    painter->setBrush(Qt::NoBrush);
    const qreal lineWidth = std::max<qreal>(1.0, videoRect.height() / 540.0);

    // Rule lines and zones in blue, as iVMS-4200 draws them; a rule in alarm in red, drawn last so it
    // stays on top where it shares an edge with another rule.
    if (drawRules) {
        for (int pass = 0; pass < 2; ++pass) {
            const bool alarmPass = pass == 1;
            painter->setPen(QPen(alarmPass ? QColor(255, 0, 0) : QColor(0, 0, 255), lineWidth));
            for (const Rule &rule : rules) {
                if (alarmRules.contains(rule.id) != alarmPass)
                    continue;
                QPolygonF poly;
                for (const QPointF &pt : rule.points)
                    poly << toView(pt);
                if (rule.polygon && poly.size() >= 3)
                    painter->drawPolygon(poly);
                else
                    painter->drawPolyline(poly);
            }
        }
    }

    // Target boxes: red while the target sets off a rule, green otherwise (as iVMS-4200).
    for (const Target &t : targets) {
        painter->setPen(QPen(t.alarm ? QColor(255, 0, 0) : QColor(0, 255, 0), lineWidth));
        painter->drawRect(QRectF(toView(t.rect.topLeft()), toView(t.rect.bottomRight())));
    }
    painter->restore();
}
