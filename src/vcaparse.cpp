#include "vcaparse.h"

#include <algorithm>
#include <cstring>

QVector<VcaSpan> ruleBodySpans(const unsigned char *p, int len, int gap)
{
    QVector<VcaSpan> spans;
    if (!p || len < 24 || gap < 1)
        return spans;
    const int ruleCount = p[22];
    int pos = 24;
    for (int k = 0; k < ruleCount && pos < len; ++k) {
        int end = pos;
        while (end + gap <= len) {
            bool zeros = true;
            for (int z = 0; z < gap; ++z) {
                if (p[end + z] != 0) {
                    zeros = false;
                    break;
                }
            }
            if (zeros)
                break;
            ++end;
        }
        if (end + gap > len)
            break;
        VcaSpan span;
        span.begin = pos;
        span.end = end;
        spans.append(span);
        pos = end + gap;
    }
    return spans;
}

QVector<int> g3RuleStarts(const unsigned char *p, int len)
{
    QVector<int> starts;
    if (!p)
        return starts;
    for (int i = 24; i + 1 < len; ++i) {
        const bool line = p[i] == 0x00 && p[i + 1] == 0x10;
        const bool zone = p[i] == 0x40 && (p[i + 1] == 0x20 || p[i + 1] == 0x30 || p[i + 1] == 0x38);
        if (line || zone)
            starts.append(i);
    }
    return starts;
}

namespace {

// Bit reader used by PlayCtrl's older IVS target parser. The first 32 bits are
// already loaded; each read takes the top n bits and refills from the next bytes.
struct IvsBits {
    const unsigned char *data = nullptr;
    int limit = 0;
    int ptr = 0;
    int bits = 0;
    quint32 buf = 0;
    int dx = 0;
    int dy = 0;
    bool err = false;

    void prime()
    {
        if (limit <= 3) {
            err = true;
            return;
        }
        buf = (quint32(data[0]) << 24) | (quint32(data[1]) << 16) | (quint32(data[2]) << 8) | data[3];
        ptr = 4;
        bits = 32;
    }

    quint32 getn(int n)
    {
        if (bits < n) {
            err = true;
            return 0;
        }
        const quint32 old = buf;
        quint32 acc = old << n;
        if (old == acc)
            acc = 0;
        int nb = bits - n;
        if (nb <= 24) {
            while (true) {
                if (ptr + 1 > limit) {
                    bits = nb;
                    buf = acc;
                    err = true;
                    return 0;
                }
                const unsigned byte = ptr < limit ? data[ptr] : 0;
                ++ptr;
                acc |= quint32(byte) << (0x18 - nb);
                nb += 8;
                if (nb > 24)
                    break;
            }
        }
        bits = nb;
        buf = acc;
        if (n <= 0)
            return 0;
        return old >> (32 - n);
    }

    quint32 readLinfo()
    {
        const quint32 edx = buf;
        int length = 17;
        static const quint32 masks[] = {
            0x80000000u, 0x40000000u, 0x20000000u, 0x10000000u, 0x08000000u, 0x04000000u,
            0x02000000u, 0x01000000u, 0x00800000u, 0x00400000u, 0x00200000u, 0x00100000u,
            0x00080000u, 0x00040000u, 0x00020000u, 0x00010000u,
        };
        for (int i = 0; i < 16; ++i) {
            if (edx & masks[i]) {
                length = i + 1;
                break;
            }
        }
        int nb = bits - length;
        quint32 acc = edx << length;
        int at = ptr;
        if (nb <= 24) {
            while (true) {
                if (at + 1 > limit) {
                    err = true;
                    return 0;
                }
                const unsigned byte = at < limit ? data[at] : 0;
                ++at;
                acc |= quint32(byte) << (0x18 - nb);
                nb += 8;
                if (nb > 24)
                    break;
            }
        }
        if (length <= 1) {
            bits = nb;
            buf = acc;
            ptr = at;
            return 0;
        }
        const quint32 info = acc >> (0x21 - length);
        acc <<= (length - 1);
        nb -= (length - 1);
        if (nb <= 24) {
            while (true) {
                if (at + 1 > limit) {
                    bits = nb;
                    buf = acc;
                    ptr = at;
                    err = true;
                    return 0;
                }
                const unsigned byte = at < limit ? data[at] : 0;
                ++at;
                acc |= quint32(byte) << (0x18 - nb);
                nb += 8;
                if (nb > 24)
                    break;
            }
        }
        bits = nb;
        buf = acc;
        ptr = at;
        const int ret = 2 * length - 1;
        return (1u << (ret >> 1)) + info - 1;
    }

    void align()
    {
        const int n = bits & 7;
        if (n == 0)
            return;
        buf <<= n;
        bits -= n;
    }
};

bool boxInPicture(quint32 tid, float x, float y, float w, float h)
{
    return tid != 0 && w > 0.002f && h > 0.002f && x >= 0.f && y >= 0.f && x + w <= 1.01f && y + h <= 1.01f;
}

} // namespace

bool decodeG3Targets(const unsigned char *p, int len, QVector<VcaTargetBox> *out)
{
    if (!out)
        return false;
    out->clear();
    if (!p || len < 36 + 28 || p[0] != 0x00 || p[1] != 0x14)
        return false;
    const int count = std::min<int>(p[26], 30);
    int pos = 36;
    for (int k = 0; k < count && pos + 28 <= len; ++k, pos += 32) {
        quint32 tid = 0;
        float x = 0.f;
        float y = 0.f;
        float w = 0.f;
        float h = 0.f;
        std::memcpy(&tid, p + pos, 4);
        std::memcpy(&x, p + pos + 8, 4);
        std::memcpy(&y, p + pos + 12, 4);
        std::memcpy(&w, p + pos + 16, 4);
        std::memcpy(&h, p + pos + 20, 4);
        if (tid == 0 || !(w > 0.002f && h > 0.002f && x >= 0.f && y >= 0.f && x + w <= 1.01f && y + h <= 1.01f))
            continue;
        VcaTargetBox box;
        box.id = tid;
        box.x = x;
        box.y = y;
        box.w = w;
        box.h = h;
        out->append(box);
    }
    return true;
}

bool decodeIvs2325Targets(const unsigned char *p, int len, QVector<VcaTargetBox> *out)
{
    if (!out)
        return false;
    out->clear();
    // Bytes 14-15 are the scale word. 0x2325 is the panoramic substream. Anything else,
    // including 0x2324, still belongs to PlayCtrl.
    if (!p || len < 22 || p[0] != 0x00 || p[1] != 0x03 || p[5] != 1 || p[14] != 0x23 || p[15] != 0x25)
        return false;

    const int bodyLen = len - 22;
    QByteArray raw(bodyLen + 8, '\0');
    if (bodyLen > 0)
        std::memcpy(raw.data(), p + 22, static_cast<size_t>(bodyLen));

    IvsBits r;
    r.data = reinterpret_cast<const unsigned char *>(raw.constData());
    // PlayCtrl's limit is the prefixed buffer (4 byte magic plus the body), and the
    // reader base is the body. That allows a few bytes of the zero pad.
    r.limit = bodyLen + 4;
    r.prime();
    if (r.err)
        return true;

    int count = static_cast<int>(r.getn(8));
    const quint32 flags = r.getn(8);
    const int skip = static_cast<int>((flags >> 4) & 7);
    for (int i = 0; i < skip; ++i)
        r.getn(8);
    r.dx = static_cast<int>(r.getn(16) & 0x7fff);
    r.dy = static_cast<int>(r.getn(16) & 0x7fff);
    const int nibble = static_cast<int>(flags & 0xf);
    // A count above 30 is rejected by this older layout (the record is kept empty).
    if (count > 30)
        count = 0;
    if (r.err)
        return true;

    for (int i = 0; i < count; ++i) {
        if (nibble > 0) {
            r.getn(8);
            for (int k = 1; k < nibble; ++k)
                r.getn(8);
        }
        r.getn(4); // class. A vehicle and a person are both drawn.
        // Scale 0x2325 is above 0x3ff, so the id is one byte plus 15 bits.
        const quint32 tid = (r.getn(8) << 24) | r.getn(15);
        float x = 0.f;
        float y = 0.f;
        float w = 0.f;
        float h = 0.f;
        const bool haveScale = r.dx != 0 && r.dy != 0 && !r.err;
        if (haveScale) {
            x = static_cast<float>(r.readLinfo()) / static_cast<float>(r.dx);
            y = static_cast<float>(r.readLinfo()) / static_cast<float>(r.dy);
            w = static_cast<float>(r.readLinfo()) / static_cast<float>(r.dx);
            h = static_cast<float>(r.readLinfo()) / static_cast<float>(r.dy);
        }
        const bool coordsOk = haveScale && !r.err;
        // Six trailer bytes. Linux PlayCtrl does not read these, so the next
        // target is taken from the middle of this one.
        for (int k = 0; k < 6; ++k)
            r.getn(8);
        if (coordsOk && boxInPicture(tid, x, y, w, h)) {
            VcaTargetBox box;
            box.id = tid;
            box.x = x;
            box.y = y;
            box.w = w;
            box.h = h;
            out->append(box);
        }
        r.align();
        if (r.err)
            break;
    }
    return true;
}

VcaAlarmIds readVcaAlarm(const unsigned char *p, int len)
{
    VcaAlarmIds alarm;
    if (!p || len < 40 || p[0] != 0x00 || p[1] != 0x03 || p[5] != 2)
        return alarm;
    if (p[14] == 0x30) {
        const unsigned char *t = p + len - 16;
        if (!std::all_of(t - 6, t, [](unsigned char b) { return b == 0; }))
            return alarm;
        alarm.layout = VcaAlarmIds::G3;
        alarm.target = (((t[0] & 0x0f) << 11) | (static_cast<quint32>(t[1]) << 3) | (t[2] >> 5)) & 0x7fff;
        return alarm;
    }
    const unsigned char *tail = p + len;
    const bool zeros = std::all_of(tail - 20, tail - 13, [](unsigned char b) { return b == 0; });
    if (!zeros || !(tail[-13] & 0x80))
        return alarm;
    alarm.layout = VcaAlarmIds::Legacy;
    alarm.rule = tail[-21];
    alarm.target = ((static_cast<quint32>(tail[-13]) << 8) | tail[-12]) & 0x7fff;
    return alarm;
}

bool mergeKeptRules(QVector<VcaRule> *rules, const QVector<VcaRule> &got)
{
    if (!rules)
        return false;
    bool changed = false;
    for (const VcaRule &n : got) {
        bool found = false;
        for (VcaRule &old : *rules) {
            if (old.id != n.id)
                continue;
            if (old.polygon != n.polygon || old.points != n.points) {
                old = n;
                changed = true;
            }
            found = true;
            break;
        }
        if (!found) {
            rules->append(n);
            changed = true;
        }
    }
    return changed;
}
