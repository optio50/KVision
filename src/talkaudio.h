#ifndef TALKAUDIO_H
#define TALKAUDIO_H

// Plain C++ helpers for two-way audio: resampling to 8 kHz, voice level control and
// G.711 u-law encoding. No Qt or SDK dependencies, so they can be tested on their own.

#include <cmath>
#include <cstdint>
#include <vector>

namespace TalkAudio {

// ITU-T G.711 u-law encoder for one 16-bit sample.
inline uint8_t linearToUlaw(int16_t pcm)
{
    const int bias = 0x84;
    const int clip = 32635;
    int sign = (pcm >> 8) & 0x80;
    int v = pcm;
    if (sign)
        v = -v;
    if (v > clip)
        v = clip;
    v += bias;
    int exponent = 7;
    for (int mask = 0x4000; (v & mask) == 0 && exponent > 0; mask >>= 1)
        --exponent;
    int mantissa = (v >> (exponent + 3)) & 0x0F;
    return static_cast<uint8_t>(~(sign | (exponent << 4) | mantissa));
}

// ITU-T G.711 A-law encoder for one 16-bit sample.
inline uint8_t linearToAlaw(int16_t pcm)
{
    static const int segEnd[8] = {0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF};
    int v = pcm >> 3; // 13-bit magnitude range
    int mask;
    if (v >= 0) {
        mask = 0xD5;
    } else {
        mask = 0x55;
        v = -v - 1;
    }
    int seg = 0;
    while (seg < 8 && v > segEnd[seg])
        ++seg;
    if (seg >= 8)
        return static_cast<uint8_t>(0x7F ^ mask);
    int aval = seg << 4;
    aval |= (seg < 2) ? ((v >> 1) & 0x0F) : ((v >> seg) & 0x0F);
    return static_cast<uint8_t>(aval ^ mask);
}

// Streaming sample-rate converter (box filter average) to a lower rate, mono, float samples.
class Resampler
{
public:
    explicit Resampler(int inRate = 48000, int outRate = 8000)
        : m_in(inRate > 0 ? inRate : 8000), m_out(outRate > 0 ? outRate : 8000) {}

    void process(const float *in, int count, std::vector<float> &out)
    {
        for (int i = 0; i < count; ++i) {
            m_sum += in[i];
            ++m_count;
            m_phase += m_out;
            if (m_phase >= m_in) {
                m_phase -= m_in;
                out.push_back(m_sum / static_cast<float>(m_count));
                m_sum = 0.0f;
                m_count = 0;
            }
        }
    }

private:
    int m_in;
    int m_out;
    int m_phase = 0;
    int m_count = 0;
    float m_sum = 0.0f;
};

// Voice level control for a small camera speaker: removes low rumble, applies the user gain,
// compresses so quiet speech is lifted, and soft-limits so loud peaks never clip.
class VoiceProcessor
{
public:
    explicit VoiceProcessor(int sampleRate = 8000)
    {
        const double rate = sampleRate > 0 ? sampleRate : 8000;
        m_hpCoeff = static_cast<float>(1.0 / (1.0 + 2.0 * M_PI * 150.0 / rate)); // ~150 Hz high-pass
        m_attack = static_cast<float>(1.0 - std::exp(-1.0 / (0.005 * rate)));    // 5 ms
        m_release = static_cast<float>(1.0 - std::exp(-1.0 / (0.120 * rate)));   // 120 ms
    }

    void setGain(double gain) { m_gain = static_cast<float>(gain); }

    // Output boost in dB, applied after compression and before the limiter, on top of the
    // built-in makeup of about +15.6 dB. Peaks are still held below the limiter ceiling.
    void setOutputBoostDb(double db)
    {
        const double clamped = db < -12.0 ? -12.0 : (db > 18.0 ? 18.0 : db);
        m_makeup = static_cast<float>(6.0 * std::pow(10.0, clamped / 20.0));
    }

    // Returns the peak of the processed block (0..1).
    float process(float *x, int count)
    {
        const float threshold = 0.04f;   // about -28 dBFS
        const float slope = 1.0f / 6.0f - 1.0f; // 6:1 compression
        const float knee = 0.70f;
        const float ceiling = 0.89f;
        float peak = 0.0f;
        for (int i = 0; i < count; ++i) {
            // High-pass: y[n] = a * (y[n-1] + x[n] - x[n-1])
            const float in = x[i];
            const float hp = m_hpCoeff * (m_hpY + in - m_hpX);
            m_hpX = in;
            m_hpY = hp;

            float s = hp * m_gain;
            const float a = std::fabs(s);
            m_env += (a > m_env ? m_attack : m_release) * (a - m_env);
            if (m_env > threshold)
                s *= std::pow(m_env / threshold, slope);
            s *= m_makeup;

            const float mag = std::fabs(s);
            if (mag > knee) {
                const float over = std::tanh((mag - knee) / (ceiling - knee)) * (ceiling - knee);
                s = (s < 0.0f ? -1.0f : 1.0f) * (knee + over);
            }
            x[i] = s;
            const float m = std::fabs(s);
            if (m > peak)
                peak = m;
        }
        return peak;
    }

private:
    float m_gain = 1.0f;
    float m_makeup = 6.0f;
    float m_hpCoeff = 0.0f;
    float m_hpX = 0.0f;
    float m_hpY = 0.0f;
    float m_env = 0.0f;
    float m_attack = 0.0f;
    float m_release = 0.0f;
};

} // namespace TalkAudio

#endif // TALKAUDIO_H
