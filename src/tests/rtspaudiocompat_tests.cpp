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

TEST(RtspAudioCompat, NamesTheCameraWithoutKeepingThePassword)
{
    QString host;
    int channel = -1;
    RtspAudioCompat::parseDroppedStream(
        QStringLiteral("rtsp://admin:secret@192.168.20.185:554/Streaming/Channels/102"),
        &host, &channel);
    EXPECT_EQ(host, QStringLiteral("192.168.20.185"));
    EXPECT_EQ(channel, 1);
    EXPECT_FALSE(host.contains(QStringLiteral("secret")));
    EXPECT_FALSE(host.contains(QStringLiteral("admin")));

    RtspAudioCompat::parseDroppedStream(
        QStringLiteral("rtsp://10.0.0.8:554/Streaming/Channels/1402"),
        &host, &channel);
    EXPECT_EQ(host, QStringLiteral("10.0.0.8"));
    EXPECT_EQ(channel, 14);

    host = QStringLiteral("keep");
    channel = 4;
    RtspAudioCompat::parseDroppedStream(
        QStringLiteral("rtsp://user:pw@127.0.0.1:43100/Streaming/Channels/101"),
        &host, &channel);
    EXPECT_TRUE(host.isEmpty());
    EXPECT_EQ(channel, 0);
}

TEST(RtspAudioCompat, IgnoresOneBadAudioPacket)
{
    RtspAudioCompat::AudioDropBurst burst;
    EXPECT_FALSE(RtspAudioCompat::sustainedAudioDrop(&burst, 0));
    for (int i = 1; i < 30; ++i)
        EXPECT_FALSE(RtspAudioCompat::sustainedAudioDrop(&burst, 0));
}

TEST(RtspAudioCompat, OffersRepairOnlyAfterAudioKeepsFailing)
{
    RtspAudioCompat::AudioDropBurst burst;
    bool offered = false;
    for (qint64 t = 0; t <= 1000; t += 50)
        offered = RtspAudioCompat::sustainedAudioDrop(&burst, t) || offered;
    EXPECT_TRUE(offered);

    RtspAudioCompat::AudioDropBurst other;
    for (int i = 0; i < 6; ++i)
        EXPECT_FALSE(RtspAudioCompat::sustainedAudioDrop(&other, i * 100));
    EXPECT_FALSE(RtspAudioCompat::sustainedAudioDrop(&other, 2000));
    EXPECT_FALSE(RtspAudioCompat::sustainedAudioDrop(&other, 2100));
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
