#include "rtspaudiocompat.h"
#include <gtest/gtest.h>

namespace {
const QByteArray kAudio =
    "m=audio 0 RTP/AVP 104\r\n"
    "a=rtpmap:104 MPEG4-GENERIC/16000\r\n"
    "a=control:trackID=audio\r\n";
const QByteArray kParameters =
    " streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;"
    "indexlength=3;indexdeltalength=3;config=1408\r\n";
}

TEST(RtspAudioCompat, RepairsRecorderAacPayloadMismatchWithoutChangingParameters)
{
    const QByteArray broken = kAudio + "a=fmtp:97" + kParameters;
    const QByteArray expected = kAudio + "a=fmtp:104" + kParameters;
    EXPECT_EQ(RtspAudioCompat::repairSdp(broken), expected);
    EXPECT_EQ(RtspAudioCompat::repairSdp(expected), expected);
}

TEST(RtspAudioCompat, RepairsDuplicateParametersReportedByRecorder)
{
    const QByteArray broken = kAudio + "a=fmtp:97" + kParameters + "a=fmtp:97" + kParameters;
    const QByteArray expected = kAudio + "a=fmtp:104" + kParameters + "a=fmtp:104" + kParameters;
    EXPECT_EQ(RtspAudioCompat::repairSdp(broken), expected);
}

TEST(RtspAudioCompat, PreservesOtherMediaSectionsAndSessionAttributes)
{
    const QByteArray prefix = "v=0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\n"
        "a=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=0\r\n";
    const QByteArray suffix = "m=application 0 RTP/AVP 107\r\na=fmtp:97 untouched\r\n";
    EXPECT_EQ(RtspAudioCompat::repairSdp(prefix + kAudio + "a=fmtp:97" + kParameters + suffix),
              prefix + kAudio + "a=fmtp:104" + kParameters + suffix);
}

TEST(RtspAudioCompat, LeavesValidOrAmbiguousAudioUntouched)
{
    const QByteArray valid = kAudio + "a=fmtp:104" + kParameters + "a=fmtp:97" + kParameters;
    EXPECT_EQ(RtspAudioCompat::repairSdp(valid), valid);
    QByteArray multiple = kAudio + "a=fmtp:97" + kParameters;
    multiple.replace("RTP/AVP 104", "RTP/AVP 104 97");
    EXPECT_EQ(RtspAudioCompat::repairSdp(multiple), multiple);
}

TEST(RtspAudioCompat, DoesNotInventParametersOrRewriteOtherCodecs)
{
    EXPECT_EQ(RtspAudioCompat::repairSdp(kAudio), kAudio);
    QByteArray other = kAudio + "a=fmtp:97" + kParameters;
    other.replace("MPEG4-GENERIC/16000", "PCMU/8000");
    EXPECT_EQ(RtspAudioCompat::repairSdp(other), other);
    EXPECT_TRUE(RtspAudioCompat::repairSdp(QByteArray()).isEmpty());
}
