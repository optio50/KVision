#include "eventalert.h"
#include "loginguard.h"
#include "stallwatch.h"
#include "hikvisionvca.h"
#include "vcaparse.h"

#include <gtest/gtest.h>

#include <QDate>
#include <QDateTime>
#include <QTime>

#include <cstring>

namespace {

const QDateTime kNow(QDate(2026, 11, 23), QTime(12, 0, 30), Qt::LocalTime);
const QString kFresh = QStringLiteral("2026-11-23T12:00:25"); // 5 seconds before kNow
const QString kLate = QStringLiteral("2026-11-23T12:00:20");  // 10 seconds before kNow

const QSet<QString> kKinds = {
    QStringLiteral("motion"),
    QStringLiteral("line"),
    QStringLiteral("intrusion"),
    QStringLiteral("enter"),
    QStringLiteral("exit"),
    QStringLiteral("face"),
};
const QSet<QString> kTargets = {
    QStringLiteral("human"),
    QStringLiteral("vehicle"),
    QStringLiteral("animal"),
    QStringLiteral("other"),
};

QString alertXml(const QString &type, const QString &state, const QString &when, const QString &extra = QString())
{
    return QStringLiteral(
               "<EventNotificationAlert><eventType>%1</eventType><eventState>%2</eventState>"
               "<dateTime>%3</dateTime><channelID>3</channelID>%4</EventNotificationAlert>")
        .arg(type, state, when, extra);
}

void putU32(unsigned char *p, quint32 value)
{
    std::memcpy(p, &value, 4);
}

void putF32(unsigned char *p, float value)
{
    std::memcpy(p, &value, 4);
}

void putBox(unsigned char *rec, quint32 id, float x, float y, float w, float h)
{
    putU32(rec, id);
    rec[4] = 1; // class byte, not read by the walker
    putF32(rec + 8, x);
    putF32(rec + 12, y);
    putF32(rec + 16, w);
    putF32(rec + 20, h);
}

} // namespace

TEST(LoginGuard, RefusesOnlyThePasswordThatFailed)
{
    LoginGuard::instance().clear();
    EXPECT_FALSE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("admin"),
                                                  QStringLiteral("wrong")));
    LoginGuard::instance().refuse(QStringLiteral("192.168.1.10"), QStringLiteral("admin"), QStringLiteral("wrong"));
    EXPECT_TRUE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("admin"),
                                                 QStringLiteral("wrong")));
    EXPECT_FALSE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("admin"),
                                                  QStringLiteral("right")));
    EXPECT_FALSE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("other"),
                                                  QStringLiteral("wrong")));
    EXPECT_FALSE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.11"), QStringLiteral("admin"),
                                                  QStringLiteral("wrong")));

    LoginGuard::instance().refuse(QStringLiteral("192.168.1.10"), QStringLiteral("admin"), QStringLiteral("right"));
    EXPECT_FALSE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("admin"),
                                                  QStringLiteral("wrong")));
    EXPECT_TRUE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("admin"),
                                                 QStringLiteral("right")));
    LoginGuard::instance().clear();
    EXPECT_FALSE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("admin"),
                                                  QStringLiteral("right")));
}

TEST(LoginGuard, NormalizesTheHost)
{
    LoginGuard::instance().clear();
    LoginGuard::instance().refuse(QStringLiteral("http://192.168.1.10:80/ISAPI/Streaming/channels"),
                                  QStringLiteral(" admin "), QStringLiteral("secret"));
    EXPECT_TRUE(LoginGuard::instance().isRefused(QStringLiteral("https://192.168.1.10/"), QStringLiteral("admin"),
                                                 QStringLiteral("secret")));
    EXPECT_TRUE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10:8000"), QStringLiteral("admin"),
                                                 QStringLiteral("secret")));
    EXPECT_FALSE(LoginGuard::instance().isRefused(QString(), QStringLiteral("admin"), QStringLiteral("secret")));
    EXPECT_FALSE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QString(), QStringLiteral("secret")));
    EXPECT_FALSE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("admin"), QString()));
    LoginGuard::instance().refuse(QString(), QStringLiteral("admin"), QStringLiteral("secret"));
    LoginGuard::instance().refuse(QStringLiteral("192.168.1.10"), QString(), QStringLiteral("secret"));
    LoginGuard::instance().refuse(QStringLiteral("192.168.1.10"), QStringLiteral("admin"), QString());
    EXPECT_TRUE(LoginGuard::instance().isRefused(QStringLiteral("192.168.1.10"), QStringLiteral("admin"),
                                                 QStringLiteral("secret")));
    LoginGuard::instance().clear();
}

TEST(LoginGuard, Http403DoesNotRefuseTheLogin)
{
    EXPECT_TRUE(LoginGuard::isHttpAuthRefusal(401));
    EXPECT_FALSE(LoginGuard::isHttpAuthRefusal(403));
    EXPECT_FALSE(LoginGuard::isHttpAuthRefusal(404));
    EXPECT_FALSE(LoginGuard::isHttpAuthRefusal(200));
    EXPECT_FALSE(LoginGuard::isHttpAuthRefusal(0));
}

TEST(LoginGuard, SdkAuthFailures)
{
    EXPECT_TRUE(LoginGuard::isSdkAuthFailure(1));
    EXPECT_TRUE(LoginGuard::isSdkAuthFailure(26));
    EXPECT_TRUE(LoginGuard::isSdkAuthFailure(153));
    EXPECT_TRUE(LoginGuard::isSdkAuthFailure(2193));
    EXPECT_FALSE(LoginGuard::isSdkAuthFailure(0));
    EXPECT_FALSE(LoginGuard::isSdkAuthFailure(7));
    EXPECT_FALSE(LoginGuard::isSdkAuthFailure(404));
}

TEST(StallWatch, LeavesAHealthyStreamAlone)
{
    const qint64 now = 200000;
    EXPECT_EQ(evaluateStall(false, kStallStatusInvalid, 0, 1, now, 0, 0), 0);
    EXPECT_EQ(evaluateStall(true, kStallStatusLoading, 1, 1, now + 60000, 0, 0), 0);
    EXPECT_EQ(evaluateStall(true, 6, now - 7999, now - 20000, now, 0, 0), 0);
    EXPECT_EQ(evaluateStall(true, 6, 0, now - 14999, now, 0, 0), 0);
    EXPECT_EQ(evaluateStall(true, 6, 0, 0, now, 0, 0), 0);
}

TEST(StallWatch, RestartsAQuietStreamAndBacksOff)
{
    const qint64 assigned = 100000;
    const qint64 now = assigned + 20000;
    EXPECT_EQ(evaluateStall(true, 6, now - 8000, assigned, now, 0, 0), 5000);
    EXPECT_EQ(evaluateStall(true, 6, 0, now - 15000, now, 0, 0), 5000);
    EXPECT_EQ(evaluateStall(true, kStallStatusEnd, now, now, now, 0, 0), 5000);
    EXPECT_EQ(evaluateStall(true, kStallStatusInvalid, now, now, now, 0, 0), 5000);

    const qint64 attempt = now;
    EXPECT_EQ(evaluateStall(true, kStallStatusInvalid, 0, assigned, attempt + 4999, 5000, attempt), 0);
    EXPECT_EQ(evaluateStall(true, kStallStatusInvalid, 0, assigned, attempt + 5000, 5000, attempt), 10000);
    EXPECT_EQ(evaluateStall(true, 6, now - 8000, assigned, attempt + 20000, 10000, attempt + 5000), 20000);
    EXPECT_EQ(evaluateStall(true, 6, now - 8000, assigned, attempt + 50000, 20000, attempt + 20000), 30000);
    EXPECT_EQ(evaluateStall(true, 6, now - 8000, assigned, attempt + 90000, 30000, attempt + 50000), 30000);
}

TEST(EventAlert, ClassifiesMotionTargets)
{
    const QString human = alertXml(QStringLiteral("VMD"), QStringLiteral("active"), kFresh,
                                   QStringLiteral("<targetType>human</targetType>"));
    const EventAlert person = classifyEventAlert(human, kKinds, kTargets, true, kNow);
    EXPECT_EQ(person.action, EventAlert::LabelledMotion);
    EXPECT_EQ(person.frame, EventAlert::Flash);
    EXPECT_EQ(person.target, QStringLiteral("human"));
    EXPECT_EQ(person.channel, 3);
    EXPECT_EQ(person.shortLabel, QStringLiteral("MOTION"));

    const QString vehicle = alertXml(QStringLiteral("VMD"), QStringLiteral("active"), kFresh,
                                     QStringLiteral("<targetType>Vehicle</targetType>"));
    EXPECT_EQ(classifyEventAlert(vehicle, kKinds, kTargets, true, kNow).target, QStringLiteral("vehicle"));

    const QString animal = alertXml(QStringLiteral("VMD"), QStringLiteral("active"), kFresh,
                                    QStringLiteral("<targetType> animal </targetType>"));
    EXPECT_EQ(classifyEventAlert(animal, kKinds, kTargets, true, kNow).target, QStringLiteral("animal"));

    const QString unknown = alertXml(QStringLiteral("VMD"), QStringLiteral("active"), kFresh,
                                     QStringLiteral("<targetType>bicycle</targetType>"));
    const EventAlert other = classifyEventAlert(unknown, kKinds, kTargets, true, kNow);
    EXPECT_EQ(other.action, EventAlert::LabelledMotion);
    EXPECT_EQ(other.target, QStringLiteral("other"));
    EXPECT_EQ(other.frame, EventAlert::Flash);

    QSet<QString> noOther = kTargets;
    noOther.remove(QStringLiteral("other"));
    EXPECT_EQ(classifyEventAlert(unknown, kKinds, noOther, true, kNow).frame, EventAlert::NoFrame);
}

TEST(EventAlert, PlainMotionKeepsOrFlashes)
{
    const QString plain = alertXml(QStringLiteral("VMD"), QStringLiteral("active"), kFresh);
    const EventAlert flash = classifyEventAlert(plain, kKinds, kTargets, true, kNow);
    EXPECT_EQ(flash.action, EventAlert::PlainMotion);
    EXPECT_EQ(flash.target, QStringLiteral("other"));
    EXPECT_EQ(flash.logKind, QStringLiteral("Motion"));
    EXPECT_EQ(flash.frame, EventAlert::Flash);

    EXPECT_EQ(classifyEventAlert(plain, kKinds, kTargets, false, kNow).frame, EventAlert::Keep);

    QSet<QString> noMotion = kKinds;
    noMotion.remove(QStringLiteral("motion"));
    EXPECT_EQ(classifyEventAlert(plain, noMotion, kTargets, true, kNow).frame, EventAlert::NoFrame);
}

TEST(EventAlert, SmartEventsFlashOnlyWhenActiveAndOnTime)
{
    struct Sample {
        const char *type;
        const char *kind;
        const char *label;
    };
    const Sample samples[] = {
        {"linedetection", "Line crossing", "LINE"},
        {"fielddetection", "Intrusion", "INTRUSION"},
        {"regionEntrance", "Region entrance", "ENTER"},
        {"regionExiting", "Region exit", "EXIT"},
    };
    for (const Sample &sample : samples) {
        const QString body = alertXml(QString::fromLatin1(sample.type), QStringLiteral("active"), kFresh,
                                      QStringLiteral("<detectionTarget>human</detectionTarget>"));
        const EventAlert alert = classifyEventAlert(body, kKinds, kTargets, true, kNow);
        EXPECT_EQ(alert.action, EventAlert::Smart);
        EXPECT_TRUE(alert.active);
        EXPECT_EQ(alert.frame, EventAlert::Flash);
        EXPECT_EQ(alert.logKind, QString::fromLatin1(sample.kind));
        EXPECT_EQ(alert.shortLabel, QString::fromLatin1(sample.label));
        EXPECT_EQ(alert.target, QStringLiteral("human"));
    }

    const QString line = alertXml(QStringLiteral("linedetection"), QStringLiteral("inactive"), kFresh,
                                  QStringLiteral("<detectionTarget>human</detectionTarget>"));
    const EventAlert inactive = classifyEventAlert(line, kKinds, kTargets, true, kNow);
    EXPECT_EQ(inactive.action, EventAlert::Smart);
    EXPECT_FALSE(inactive.active);
    EXPECT_EQ(inactive.frame, EventAlert::NoFrame);

    const QString late = alertXml(QStringLiteral("linedetection"), QStringLiteral("active"), kLate,
                                  QStringLiteral("<detectionTarget>human</detectionTarget>"));
    const EventAlert replay = classifyEventAlert(late, kKinds, kTargets, true, kNow);
    EXPECT_EQ(replay.action, EventAlert::Smart);
    EXPECT_TRUE(replay.active);
    EXPECT_EQ(replay.frame, EventAlert::NoFrame);

    const QString emptyTarget = alertXml(QStringLiteral("linedetection"), QStringLiteral("active"), kFresh,
                                         QStringLiteral("<detectionTarget></detectionTarget>"));
    const EventAlert empty = classifyEventAlert(emptyTarget, kKinds, kTargets, true, kNow);
    EXPECT_TRUE(empty.target.isEmpty());
    EXPECT_EQ(empty.frame, EventAlert::Flash);
}

TEST(EventAlert, FaceAndUnknownTypesDoNotFlash)
{
    const QString face = alertXml(QStringLiteral("facedetection"), QStringLiteral("active"), kFresh);
    const EventAlert faceAlert = classifyEventAlert(face, kKinds, kTargets, true, kNow);
    EXPECT_EQ(faceAlert.action, EventAlert::Face);
    EXPECT_EQ(faceAlert.logKind, QStringLiteral("Face detection"));
    EXPECT_EQ(faceAlert.shortLabel, QStringLiteral("FACE"));
    EXPECT_EQ(faceAlert.frame, EventAlert::NoFrame);

    const QString other = alertXml(QStringLiteral("videoloss"), QStringLiteral("active"), kFresh);
    const EventAlert otherAlert = classifyEventAlert(other, kKinds, kTargets, true, kNow);
    EXPECT_EQ(otherAlert.action, EventAlert::Other);
    EXPECT_EQ(otherAlert.frame, EventAlert::NoFrame);
    EXPECT_EQ(otherAlert.type, QStringLiteral("videoloss"));
}

TEST(EventAlert, LateMeansTenSeconds)
{
    EXPECT_FALSE(eventReportIsLate(QString(), kNow));
    EXPECT_FALSE(eventReportIsLate(QStringLiteral("not-a-time"), kNow));
    EXPECT_FALSE(eventReportIsLate(QStringLiteral("2026-11-23T12:00:21"), kNow));
    EXPECT_TRUE(eventReportIsLate(kLate, kNow));
    const QString labelled = alertXml(QStringLiteral("VMD"), QStringLiteral("active"), kLate,
                                      QStringLiteral("<targetType>human</targetType>"));
    EXPECT_EQ(classifyEventAlert(labelled, kKinds, kTargets, true, kNow).frame, EventAlert::NoFrame);
}

TEST(EventAlert, ZeroByteBetweenAlertsDoesNotHideTheSecond)
{
    const QByteArray first = alertXml(QStringLiteral("VMD"), QStringLiteral("active"), kFresh,
                                      QStringLiteral("<targetType>human</targetType>"))
                                 .toLatin1();
    const QByteArray second = alertXml(QStringLiteral("fielddetection"), QStringLiteral("active"), kFresh,
                                       QStringLiteral("<detectionTarget>vehicle</detectionTarget>"))
                                  .toLatin1();
    QByteArray buffer = first;
    buffer.append('\0');
    buffer.append(second);

    // QString::fromLatin1(QByteArray) stops at the first zero, which is how a picture used to hide
    // the next alert. The length has to be passed in.
    EXPECT_EQ(splitEventAlerts(QString::fromLatin1(buffer)).size(), 1);

    const QString text = QString::fromLatin1(buffer.constData(), buffer.size());
    const QVector<EventAlertSpan> spans = splitEventAlerts(text);
    ASSERT_EQ(spans.size(), 2);
    EXPECT_TRUE(spans[0].body.contains(QStringLiteral("VMD")));
    EXPECT_TRUE(spans[1].body.contains(QStringLiteral("fielddetection")));
    EXPECT_GT(spans[1].start, first.size());
    const EventAlert intrusion = classifyEventAlert(spans[1].body, kKinds, kTargets, true, kNow);
    EXPECT_EQ(intrusion.action, EventAlert::Smart);
    EXPECT_EQ(intrusion.target, QStringLiteral("vehicle"));
    EXPECT_EQ(intrusion.frame, EventAlert::Flash);
}

TEST(VcaParse, OlderRuleGapOfFourKeepsARuleThatStartsWithZero)
{
    unsigned char packet[36];
    std::memset(packet, 0, sizeof packet);
    packet[22] = 2;
    packet[24] = 0x11;
    packet[25] = 0x22;
    packet[30] = 0x00;
    packet[31] = 0x10;

    const QVector<VcaSpan> four = ruleBodySpans(packet, 36, 4);
    ASSERT_EQ(four.size(), 2);
    EXPECT_EQ(four[0].begin, 24);
    EXPECT_EQ(four[0].end, 26);
    EXPECT_EQ(four[1].begin, 30);
    EXPECT_EQ(four[1].end, 32);

    const QVector<VcaSpan> five = ruleBodySpans(packet, 36, 5);
    ASSERT_EQ(five.size(), 1);
    EXPECT_EQ(five[0].begin, 24);
    EXPECT_EQ(five[0].end, 26);

    EXPECT_TRUE(ruleBodySpans(nullptr, 36, 4).isEmpty());
    EXPECT_TRUE(ruleBodySpans(packet, 23, 4).isEmpty());
    EXPECT_TRUE(ruleBodySpans(packet, 36, 0).isEmpty());
}

TEST(VcaParse, G3RuleStartsAndKeptRules)
{
    unsigned char packet[80];
    std::memset(packet, 0, sizeof packet);
    packet[10] = 0x00;
    packet[11] = 0x10; // before the search window
    packet[24] = 0x00;
    packet[25] = 0x10;
    packet[30] = 0x40;
    packet[31] = 0x20;
    packet[40] = 0x40;
    packet[41] = 0x30;
    packet[50] = 0x40;
    packet[51] = 0x38;
    packet[60] = 0x40;
    packet[61] = 0x21;
    packet[70] = 0x00;
    packet[71] = 0x11;

    const QVector<int> starts = g3RuleStarts(packet, 80);
    ASSERT_EQ(starts.size(), 4);
    EXPECT_EQ(starts[0], 24);
    EXPECT_EQ(starts[1], 30);
    EXPECT_EQ(starts[2], 40);
    EXPECT_EQ(starts[3], 50);
    EXPECT_TRUE(g3RuleStarts(nullptr, 80).isEmpty());

    VcaRule first;
    first.id = 1;
    first.polygon = false;
    first.points = {QPointF(0.0, 0.0), QPointF(1.0, 0.0)};
    VcaRule second;
    second.id = 2;
    second.polygon = true;
    second.points = {QPointF(0.0, 0.0), QPointF(1.0, 0.0), QPointF(0.0, 1.0)};
    QVector<VcaRule> rules;
    rules.append(first);
    rules.append(second);

    VcaRule updated = first;
    updated.points = {QPointF(0.1, 0.2), QPointF(0.9, 0.2)};
    QVector<VcaRule> got;
    got.append(updated);
    EXPECT_TRUE(mergeKeptRules(&rules, got));
    ASSERT_EQ(rules.size(), 2);
    EXPECT_EQ(rules[0].id, 1u);
    ASSERT_EQ(rules[0].points.size(), 2);
    EXPECT_NEAR(rules[0].points[0].x(), 0.1, 0.0001);
    EXPECT_EQ(rules[1].id, 2u);
    EXPECT_FALSE(mergeKeptRules(&rules, got));

    VcaRule added;
    added.id = 3;
    added.points = {QPointF(0.2, 0.2)};
    got.append(added);
    EXPECT_TRUE(mergeKeptRules(&rules, got));
    ASSERT_EQ(rules.size(), 3);
    EXPECT_EQ(rules[2].id, 3u);
    EXPECT_FALSE(mergeKeptRules(nullptr, got));
}

TEST(VcaParse, TargetListSkipsZeroIdAndBoxesOutsideThePicture)
{
    unsigned char packet[128];
    std::memset(packet, 0, sizeof packet);
    packet[0] = 0x00;
    packet[1] = 0x14;
    packet[26] = 3;
    putBox(packet + 36, 1, 0.1f, 0.2f, 0.3f, 0.4f);
    putBox(packet + 68, 0, 0.1f, 0.1f, 0.2f, 0.2f);
    putBox(packet + 100, 2, 0.8f, 0.1f, 0.5f, 0.1f);

    QVector<VcaTargetBox> boxes;
    boxes.append(VcaTargetBox());
    ASSERT_TRUE(decodeG3Targets(packet, 128, &boxes));
    ASSERT_EQ(boxes.size(), 1);
    EXPECT_EQ(boxes[0].id, 1u);
    EXPECT_NEAR(boxes[0].x, 0.1f, 0.0001f);
    EXPECT_NEAR(boxes[0].y, 0.2f, 0.0001f);
    EXPECT_NEAR(boxes[0].w, 0.3f, 0.0001f);
    EXPECT_NEAR(boxes[0].h, 0.4f, 0.0001f);

    EXPECT_FALSE(decodeG3Targets(packet, 60, &boxes));
    EXPECT_TRUE(boxes.isEmpty());
    packet[1] = 0x00;
    EXPECT_FALSE(decodeG3Targets(packet, 128, &boxes));
    EXPECT_TRUE(boxes.isEmpty());
    EXPECT_FALSE(decodeG3Targets(nullptr, 128, &boxes));
    EXPECT_FALSE(decodeG3Targets(packet, 128, nullptr));
}

TEST(VcaParse, Scale2325KeepsBothVehicles)
{
    // NVR channel 12 substream, one private packet, two parked vehicles.
    // Linux PlayCtrl returns the first box and a second record with id 0.
    const unsigned char packet[] = {
        0x00, 0x03, 0x00, 0x10, 0x00, 0x01, 0x80, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0xff, 0x23, 0x25,
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x02, 0x81, 0x87, 0x80, 0x84, 0x38, 0x00, 0x00, 0x08, 0xbb,
        0x00, 0x0d, 0xf0, 0x1d, 0x81, 0x54, 0x05, 0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x0d, 0x78, 0xc0, 0x14, 0x90, 0x0c, 0xb8, 0x05, 0x8c, 0x03, 0xf4, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xff, 0xff, 0x03,
    };
    QVector<VcaTargetBox> boxes;
    ASSERT_TRUE(decodeIvs2325Targets(packet, int(sizeof packet), &boxes));
    ASSERT_EQ(boxes.size(), 2);
    EXPECT_EQ(boxes[0].id, 17880u);
    EXPECT_NEAR(boxes[0].x, 0.4640625f, 0.0002f);
    EXPECT_NEAR(boxes[0].y, 0.0537037f, 0.0002f);
    EXPECT_NEAR(boxes[0].w, 0.04375f, 0.0002f);
    EXPECT_NEAR(boxes[0].h, 0.1611111f, 0.0002f);
    EXPECT_EQ(boxes[1].id, 27590u);
    EXPECT_NEAR(boxes[1].x, 0.1708333f, 0.0002f);
    EXPECT_NEAR(boxes[1].y, 0.3759259f, 0.0002f);
    EXPECT_NEAR(boxes[1].w, 0.184375f, 0.0002f);
    EXPECT_NEAR(boxes[1].h, 0.4675926f, 0.0002f);

    unsigned char other[sizeof packet];
    std::memcpy(other, packet, sizeof packet);
    other[14] = 0x23;
    other[15] = 0x24;
    EXPECT_FALSE(decodeIvs2325Targets(other, int(sizeof other), &boxes));
    EXPECT_TRUE(boxes.isEmpty());
    EXPECT_FALSE(decodeIvs2325Targets(packet, 21, &boxes));
    EXPECT_FALSE(decodeIvs2325Targets(nullptr, int(sizeof packet), &boxes));
    EXPECT_FALSE(decodeIvs2325Targets(packet, int(sizeof packet), nullptr));
}

TEST(VcaParse, AlarmIds)
{
    unsigned char g3[40];
    std::memset(g3, 0, sizeof g3);
    g3[0] = 0x00;
    g3[1] = 0x03;
    g3[5] = 2;
    g3[14] = 0x30;
    g3[24] = 0x02;
    g3[25] = 0x46;
    g3[26] = 0x80;
    const VcaAlarmIds g3Alarm = readVcaAlarm(g3, 40);
    EXPECT_EQ(g3Alarm.layout, VcaAlarmIds::G3);
    EXPECT_EQ(g3Alarm.target, 0x1234u);
    EXPECT_EQ(g3Alarm.rule, 0u);

    g3[18] = 1;
    EXPECT_EQ(readVcaAlarm(g3, 40).layout, VcaAlarmIds::None);

    unsigned char legacy[40];
    std::memset(legacy, 0, sizeof legacy);
    legacy[0] = 0x00;
    legacy[1] = 0x03;
    legacy[5] = 2;
    legacy[19] = 7;
    legacy[27] = 0x81;
    legacy[28] = 0x23;
    const VcaAlarmIds legacyAlarm = readVcaAlarm(legacy, 40);
    EXPECT_EQ(legacyAlarm.layout, VcaAlarmIds::Legacy);
    EXPECT_EQ(legacyAlarm.rule, 7u);
    EXPECT_EQ(legacyAlarm.target, 0x0123u);

    legacy[27] = 0x01;
    EXPECT_EQ(readVcaAlarm(legacy, 40).layout, VcaAlarmIds::None);
    EXPECT_EQ(readVcaAlarm(legacy, 20).layout, VcaAlarmIds::None);
}

TEST(VcaClock, FollowsACameraClockThatRestarts)
{
    EXPECT_EQ(vcaRebasedVideoPts(-1, 1000), 1000);          // the first frame latches the base
    EXPECT_EQ(vcaRebasedVideoPts(1000, -1), 1000);          // a frame with no PTS leaves the base
    EXPECT_EQ(vcaRebasedVideoPts(5000000, 8000000), 5000000); // a later frame keeps the original base
    EXPECT_EQ(vcaRebasedVideoPts(5000000, 5000000 - 90 * 1000), 5000000); // one second behind is still the same clock
    const qint64 restarted = 5000000 - 90 * 1000 - 1;
    EXPECT_EQ(vcaRebasedVideoPts(5000000, restarted), restarted); // a step behind the latched base starts again
    EXPECT_EQ(vcaRebasedVideoPts((qint64(1) << 33) - 1000, 5000), 5000); // the 33-bit clock wrapped
}
