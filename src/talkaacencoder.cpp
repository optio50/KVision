#include "talkaacencoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
}

#include <algorithm>
#include <cstring>

namespace {

int adtsRateIndex(int rate)
{
    static const int rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                16000, 12000, 11025, 8000, 7350};
    for (int i = 0; i < 13; ++i)
        if (rates[i] == rate)
            return i;
    return -1;
}

} // namespace

TalkAacEncoder::~TalkAacEncoder()
{
    if (m_packet)
        av_packet_free(&m_packet);
    if (m_frame)
        av_frame_free(&m_frame);
    if (m_ctx)
        avcodec_free_context(&m_ctx);
}

bool TalkAacEncoder::open(int sampleRate, int bitrate)
{
    if (m_ctx || adtsRateIndex(sampleRate) < 0)
        return false;
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!codec)
        return false;

    m_ctx = avcodec_alloc_context3(codec);
    if (!m_ctx)
        return false;
    m_ctx->sample_rate = sampleRate;
    m_ctx->bit_rate = bitrate;
    m_ctx->sample_fmt = AV_SAMPLE_FMT_FLTP; // FFmpeg's native AAC encoder only takes planar float
    m_ctx->time_base = AVRational{1, sampleRate};
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(59, 24, 100)
    av_channel_layout_default(&m_ctx->ch_layout, 1);
#else
    m_ctx->channels = 1;
    m_ctx->channel_layout = AV_CH_LAYOUT_MONO;
#endif
    if (avcodec_open2(m_ctx, codec, nullptr) < 0) {
        avcodec_free_context(&m_ctx);
        return false;
    }

    m_frameSize = m_ctx->frame_size > 0 ? m_ctx->frame_size : 1024;
    m_frame = av_frame_alloc();
    m_packet = av_packet_alloc();
    if (!m_frame || !m_packet) {
        avcodec_free_context(&m_ctx);
        return false;
    }
    m_frame->nb_samples = m_frameSize;
    m_frame->format = AV_SAMPLE_FMT_FLTP;
    m_frame->sample_rate = sampleRate;
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(59, 24, 100)
    av_channel_layout_default(&m_frame->ch_layout, 1);
#else
    m_frame->channel_layout = AV_CH_LAYOUT_MONO;
#endif
    if (av_frame_get_buffer(m_frame, 0) < 0) {
        avcodec_free_context(&m_ctx);
        return false;
    }
    m_rate = sampleRate;
    m_pts = 0;
    m_pending.clear();
    return true;
}

void TalkAacEncoder::encode(const int16_t *pcm, int count, std::vector<std::vector<uint8_t>> &out)
{
    if (!m_ctx || count <= 0)
        return;
    m_pending.insert(m_pending.end(), pcm, pcm + count);
    size_t offset = 0;
    while (m_pending.size() - offset >= static_cast<size_t>(m_frameSize)) {
        if (av_frame_make_writable(m_frame) < 0)
            break;
        float *dst = reinterpret_cast<float *>(m_frame->data[0]);
        for (int i = 0; i < m_frameSize; ++i)
            dst[i] = m_pending[offset + static_cast<size_t>(i)] / 32768.0f;
        m_frame->pts = m_pts;
        m_pts += m_frameSize;
        offset += static_cast<size_t>(m_frameSize);
        if (avcodec_send_frame(m_ctx, m_frame) < 0)
            break;
        drain(out);
    }
    m_pending.erase(m_pending.begin(), m_pending.begin() + static_cast<long>(offset));
}

void TalkAacEncoder::drain(std::vector<std::vector<uint8_t>> &out)
{
    const int rateIndex = adtsRateIndex(m_rate);
    while (avcodec_receive_packet(m_ctx, m_packet) == 0) {
        const int payload = m_packet->size;
        const int total = payload + 7;
        std::vector<uint8_t> frame(static_cast<size_t>(total));
        // 7-byte ADTS header: MPEG-4, AAC-LC, no CRC, mono.
        frame[0] = 0xFF;
        frame[1] = 0xF1;
        frame[2] = static_cast<uint8_t>((1 << 6) | (rateIndex << 2) | 0);          // profile LC, rate, channel high bit
        frame[3] = static_cast<uint8_t>((1 << 6) | ((total >> 11) & 0x03));        // channel config 1 (mono), length high
        frame[4] = static_cast<uint8_t>((total >> 3) & 0xFF);
        frame[5] = static_cast<uint8_t>(((total & 0x07) << 5) | 0x1F);
        frame[6] = 0xFC;
        std::memcpy(frame.data() + 7, m_packet->data, static_cast<size_t>(payload));
        out.push_back(std::move(frame));
        av_packet_unref(m_packet);
    }
}
