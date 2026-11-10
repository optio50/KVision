#ifndef TALKAACENCODER_H
#define TALKAACENCODER_H

#include <cstdint>
#include <vector>

struct AVCodecContext;
struct AVFrame;
struct AVPacket;

// Encodes mono 16-bit PCM into AAC-LC with an ADTS header on every frame, using FFmpeg.
// This is the form Hikvision doorbells and cameras that ask for AAC talk audio accept.
class TalkAacEncoder
{
public:
    TalkAacEncoder() = default;
    ~TalkAacEncoder();
    TalkAacEncoder(const TalkAacEncoder &) = delete;
    TalkAacEncoder &operator=(const TalkAacEncoder &) = delete;

    // sampleRate: 8000, 16000, 32000, 44100 or 48000. Returns false if the encoder is unavailable.
    bool open(int sampleRate, int bitrate = 32000);
    bool isOpen() const { return m_ctx != nullptr; }
    int sampleRate() const { return m_rate; }
    // Samples consumed per encoded frame (1024 for AAC-LC).
    int frameSize() const { return m_frameSize; }

    // Feed PCM; every completed AAC frame (ADTS framed) is appended to out.
    void encode(const int16_t *pcm, int count, std::vector<std::vector<uint8_t>> &out);

private:
    void drain(std::vector<std::vector<uint8_t>> &out);

    AVCodecContext *m_ctx = nullptr;
    AVFrame *m_frame = nullptr;
    AVPacket *m_packet = nullptr;
    std::vector<int16_t> m_pending;
    int m_rate = 0;
    int m_frameSize = 1024;
    int64_t m_pts = 0;
};

#endif // TALKAACENCODER_H
