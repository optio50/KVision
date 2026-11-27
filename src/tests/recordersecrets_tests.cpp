#include "recordersecrets.h"

#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QTemporaryDir>
#include <QUrl>

namespace {

struct AppEnv {
    AppEnv()
    {
        if (!QCoreApplication::instance()) {
            static int argc = 1;
            static char arg0[] = "kvision_tests";
            static char *argv[] = {arg0, nullptr};
            app = new QCoreApplication(argc, argv);
        }
    }
    QCoreApplication *app = nullptr;
};

AppEnv g_app;

QString compact(const QJsonArray &list)
{
    return QString::fromUtf8(QJsonDocument(list).toJson(QJsonDocument::Compact));
}

QJsonObject recorder(const QString &ip, const QString &user, const QString &pass, bool withPassword)
{
    QJsonObject o;
    o.insert(QStringLiteral("name"), ip);
    o.insert(QStringLiteral("ip"), ip);
    o.insert(QStringLiteral("username"), user);
    if (withPassword)
        o.insert(QStringLiteral("password"), pass);
    return o;
}

QString passwordOf(const QString &json, const QString &ip)
{
    const QJsonArray list = QJsonDocument::fromJson(json.toUtf8()).array();
    for (const QJsonValue &v : list) {
        const QJsonObject o = v.toObject();
        if (o.value(QStringLiteral("ip")).toString() == ip)
            return o.value(QStringLiteral("password")).toString();
    }
    return QString();
}

bool hasPasswordKey(const QString &json)
{
    const QJsonArray list = QJsonDocument::fromJson(json.toUtf8()).array();
    for (const QJsonValue &v : list) {
        const QJsonObject o = v.toObject();
        if (o.contains(QStringLiteral("password")))
            return true;
        for (const QJsonValue &c : o.value(QStringLiteral("cameras")).toArray()) {
            if (c.toObject().contains(QStringLiteral("password")))
                return true;
        }
    }
    return false;
}

} // namespace

TEST(RecorderSecrets, RoundTripAndKeepsSecretWhenSealedAgain)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    const QString live = compact(QJsonArray{recorder(QStringLiteral("10.0.0.8"), QStringLiteral("admin"),
                                                     QStringLiteral("pw-one"), true)});
    const QString sealed = RecorderSecrets::sealRecorders(live, conf);
    ASSERT_FALSE(sealed.isEmpty());
    EXPECT_FALSE(hasPasswordKey(sealed));
    EXPECT_EQ(passwordOf(RecorderSecrets::openRecorders(sealed, conf), QStringLiteral("10.0.0.8")),
              QStringLiteral("pw-one"));

    const QString sealedAgain = RecorderSecrets::sealRecorders(sealed, conf);
    ASSERT_FALSE(sealedAgain.isEmpty());
    EXPECT_EQ(passwordOf(RecorderSecrets::openRecorders(sealedAgain, conf), QStringLiteral("10.0.0.8")),
              QStringLiteral("pw-one"));
    EXPECT_EQ(RecorderSecrets::sealRecorders(RecorderSecrets::openRecorders(sealed, conf), conf), sealedAgain);

    const QFileInfo info(RecorderSecrets::secretsFileFor(conf));
    ASSERT_TRUE(info.exists());
    const QFile::Permissions perms = QFile::permissions(info.filePath());
    EXPECT_EQ(int(perms & (QFileDevice::ReadGroup | QFileDevice::WriteGroup | QFileDevice::ExeGroup
                           | QFileDevice::ReadOther | QFileDevice::WriteOther | QFileDevice::ExeOther)),
              0);
    EXPECT_TRUE(perms & QFileDevice::ReadOwner);
    EXPECT_TRUE(perms & QFileDevice::WriteOwner);
}

TEST(RecorderSecrets, EmptyPasswordForgetsAndOtherRecorderStays)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    const QString both = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.1"), QStringLiteral("admin"), QStringLiteral("aaa"), true),
        recorder(QStringLiteral("10.0.0.2"), QStringLiteral("admin"), QStringLiteral("bbb"), true)});
    ASSERT_FALSE(RecorderSecrets::sealRecorders(both, conf).isEmpty());

    const QString edited = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.1"), QStringLiteral("admin"), QString(), true),
        recorder(QStringLiteral("10.0.0.2"), QStringLiteral("admin"), QString(), false)});
    const QString resealed = RecorderSecrets::sealRecorders(edited, conf);
    ASSERT_FALSE(resealed.isEmpty());
    const QString opened = RecorderSecrets::openRecorders(resealed, conf);
    EXPECT_TRUE(passwordOf(opened, QStringLiteral("10.0.0.1")).isEmpty());
    EXPECT_EQ(passwordOf(opened, QStringLiteral("10.0.0.2")), QStringLiteral("bbb"));
}

TEST(RecorderSecrets, SameHostDifferentUsersStayApart)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    const QString both = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.5"), QStringLiteral("admin"), QStringLiteral("aaa"), true),
        recorder(QStringLiteral("10.0.0.5"), QStringLiteral("guest"), QStringLiteral("bbb"), true)});
    const QString sealed = RecorderSecrets::sealRecorders(both, conf);
    ASSERT_FALSE(sealed.isEmpty());
    const QString opened = RecorderSecrets::openRecorders(sealed, conf);
    const QJsonArray list = QJsonDocument::fromJson(opened.toUtf8()).array();
    ASSERT_EQ(list.size(), 2);
    EXPECT_EQ(list.at(0).toObject().value(QStringLiteral("password")).toString(), QStringLiteral("aaa"));
    EXPECT_EQ(list.at(1).toObject().value(QStringLiteral("password")).toString(), QStringLiteral("bbb"));
}

TEST(RecorderSecrets, DroppedRecorderDropsItsSecret)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    const QString both = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.1"), QStringLiteral("admin"), QStringLiteral("aaa"), true),
        recorder(QStringLiteral("10.0.0.2"), QStringLiteral("admin"), QStringLiteral("bbb"), true)});
    ASSERT_FALSE(RecorderSecrets::sealRecorders(both, conf).isEmpty());

    const QString onlyFirst = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.1"), QStringLiteral("admin"), QStringLiteral("aaa"), true)});
    ASSERT_FALSE(RecorderSecrets::sealRecorders(onlyFirst, conf).isEmpty());

    const QString second = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.2"), QStringLiteral("admin"), QString(), false)});
    EXPECT_TRUE(passwordOf(RecorderSecrets::openRecorders(second, conf), QStringLiteral("10.0.0.2")).isEmpty());
    EXPECT_EQ(passwordOf(RecorderSecrets::openRecorders(onlyFirst, conf), QStringLiteral("10.0.0.1")),
              QStringLiteral("aaa"));
}

TEST(RecorderSecrets, EmptyListClearsSecrets)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    const QString live = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.8"), QStringLiteral("admin"), QStringLiteral("pw-one"), true)});
    const QString sealed = RecorderSecrets::sealRecorders(live, conf);
    ASSERT_FALSE(sealed.isEmpty());
    EXPECT_EQ(RecorderSecrets::sealRecorders(QStringLiteral("[]"), conf), QStringLiteral("[]"));
    EXPECT_TRUE(passwordOf(RecorderSecrets::openRecorders(sealed, conf), QStringLiteral("10.0.0.8")).isEmpty());
}

TEST(RecorderSecrets, PasswordWithoutAddressIsLeftInPlace)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    const QString live = QStringLiteral("[{\"username\":\"admin\",\"password\":\"keep-me\"}]");
    const QString sealed = RecorderSecrets::sealRecorders(live, conf);
    ASSERT_FALSE(sealed.isEmpty());
    EXPECT_TRUE(sealed.contains(QStringLiteral("keep-me")));
}

TEST(RecorderSecrets, StreamUrlUserInfoRoundTrip)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    QJsonObject o;
    o.insert(QStringLiteral("kind"), QStringLiteral("rtsp"));
    o.insert(QStringLiteral("name"), QStringLiteral("door"));
    o.insert(QStringLiteral("ip"), QStringLiteral("192.168.1.50"));
    o.insert(QStringLiteral("streamUrl"),
             QStringLiteral("rtsp://admin:secret@192.168.1.50:554/Streaming/Channels/101"));
    const QString live = compact(QJsonArray{o});
    const QString sealed = RecorderSecrets::sealRecorders(live, conf);
    ASSERT_FALSE(sealed.isEmpty());
    const QString stripped = QJsonDocument::fromJson(sealed.toUtf8()).array().at(0).toObject()
                                 .value(QStringLiteral("streamUrl")).toString();
    EXPECT_TRUE(QUrl(stripped).userInfo().isEmpty());
    EXPECT_FALSE(stripped.contains(QStringLiteral("secret")));

    const QString opened = RecorderSecrets::openRecorders(sealed, conf);
    const QUrl restored(QJsonDocument::fromJson(opened.toUtf8()).array().at(0).toObject()
                            .value(QStringLiteral("streamUrl")).toString());
    EXPECT_EQ(restored.userName(), QStringLiteral("admin"));
    EXPECT_EQ(restored.password(), QStringLiteral("secret"));

    const QString sealedAgain = RecorderSecrets::sealRecorders(sealed, conf);
    ASSERT_FALSE(sealedAgain.isEmpty());
    const QUrl again(QJsonDocument::fromJson(RecorderSecrets::openRecorders(sealedAgain, conf).toUtf8()).array().at(0).toObject()
                         .value(QStringLiteral("streamUrl")).toString());
    EXPECT_EQ(again.userName(), QStringLiteral("admin"));
    EXPECT_EQ(again.password(), QStringLiteral("secret"));
}

TEST(RecorderSecrets, ClearedStreamUrlDropsUserInfo)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    QJsonObject o;
    o.insert(QStringLiteral("kind"), QStringLiteral("rtsp"));
    o.insert(QStringLiteral("name"), QStringLiteral("door"));
    o.insert(QStringLiteral("ip"), QStringLiteral("192.168.1.50"));
    o.insert(QStringLiteral("streamUrl"),
             QStringLiteral("rtsp://admin:secret@192.168.1.50:554/Streaming/Channels/101"));
    const QString sealed = RecorderSecrets::sealRecorders(compact(QJsonArray{o}), conf);
    ASSERT_FALSE(sealed.isEmpty());

    QJsonObject cleared = QJsonDocument::fromJson(RecorderSecrets::openRecorders(sealed, conf).toUtf8()).array().at(0).toObject();
    QUrl bare(cleared.value(QStringLiteral("streamUrl")).toString());
    bare.setUserInfo(QString());
    cleared.insert(QStringLiteral("streamUrl"), bare.toString());
    const QString resealed = RecorderSecrets::sealRecorders(compact(QJsonArray{cleared}), conf);
    ASSERT_FALSE(resealed.isEmpty());
    const QUrl opened(QJsonDocument::fromJson(RecorderSecrets::openRecorders(resealed, conf).toUtf8()).array().at(0).toObject()
                          .value(QStringLiteral("streamUrl")).toString());
    EXPECT_TRUE(opened.userInfo().isEmpty());
}

TEST(RecorderSecrets, NestedCameraPasswordRoundTrip)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    QJsonObject cam;
    cam.insert(QStringLiteral("ip"), QStringLiteral("10.1.1.3"));
    cam.insert(QStringLiteral("channelId"), 3);
    cam.insert(QStringLiteral("username"), QStringLiteral("admin"));
    cam.insert(QStringLiteral("password"), QStringLiteral("cam-secret"));
    QJsonObject rec = recorder(QStringLiteral("10.1.1.1"), QStringLiteral("admin"), QStringLiteral("nvr-secret"), true);
    rec.insert(QStringLiteral("cameras"), QJsonArray{cam});
    const QString sealed = RecorderSecrets::sealRecorders(compact(QJsonArray{rec}), conf);
    ASSERT_FALSE(sealed.isEmpty());
    EXPECT_FALSE(hasPasswordKey(sealed));
    const QJsonObject opened = QJsonDocument::fromJson(RecorderSecrets::openRecorders(sealed, conf).toUtf8()).array().at(0).toObject();
    EXPECT_EQ(opened.value(QStringLiteral("password")).toString(), QStringLiteral("nvr-secret"));
    EXPECT_EQ(opened.value(QStringLiteral("cameras")).toArray().at(0).toObject().value(QStringLiteral("password")).toString(),
              QStringLiteral("cam-secret"));
}

TEST(RecorderSecrets, MalformedJsonDoesNotTouchTheSecretFile)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    const QString live = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.8"), QStringLiteral("admin"), QStringLiteral("pw-one"), true)});
    const QString sealed = RecorderSecrets::sealRecorders(live, conf);
    ASSERT_FALSE(sealed.isEmpty());
    const QString bad = QStringLiteral("{");
    EXPECT_EQ(RecorderSecrets::sealRecorders(bad, conf), bad);
    EXPECT_EQ(RecorderSecrets::openRecorders(bad, conf), bad);
    EXPECT_EQ(passwordOf(RecorderSecrets::openRecorders(sealed, conf), QStringLiteral("10.0.0.8")),
              QStringLiteral("pw-one"));
}

TEST(RecorderSecrets, MigratesIniAndDoesNotWipeWhenTheKeyIsMissing)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    const QString stored = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.8"), QStringLiteral("admin"), QStringLiteral("pw-one"), true)});
    {
        QSettings settings(conf, QSettings::IniFormat);
        settings.beginGroup(QStringLiteral("Hikvision"));
        settings.setValue(QStringLiteral("recordersJson"), stored);
        settings.endGroup();
        settings.setValue(QStringLiteral("language"), QStringLiteral("en"));
        settings.sync();
    }

    const QString live = RecorderSecrets::recordersFromConfig(conf);
    EXPECT_EQ(passwordOf(live, QStringLiteral("10.0.0.8")), QStringLiteral("pw-one"));
    QString onDisk;
    {
        QSettings settings(conf, QSettings::IniFormat);
        onDisk = settings.value(QStringLiteral("Hikvision/recordersJson")).toString();
        EXPECT_EQ(settings.value(QStringLiteral("language")).toString(), QStringLiteral("en"));
    }
    EXPECT_FALSE(hasPasswordKey(onDisk));
    EXPECT_FALSE(onDisk.contains(QStringLiteral("pw-one")));
    EXPECT_EQ(passwordOf(RecorderSecrets::recordersFromConfig(conf), QStringLiteral("10.0.0.8")),
              QStringLiteral("pw-one"));

    const QString other = dir.filePath(QStringLiteral("other.conf"));
    {
        QSettings settings(other, QSettings::IniFormat);
        settings.setValue(QStringLiteral("language"), QStringLiteral("en"));
        settings.sync();
    }
    EXPECT_EQ(RecorderSecrets::recordersFromConfig(other), QStringLiteral("[]"));
    EXPECT_EQ(passwordOf(RecorderSecrets::openRecorders(onDisk, conf), QStringLiteral("10.0.0.8")),
              QStringLiteral("pw-one"));
}

TEST(RecorderSecrets, FillLoginUsesTheNamedRecorderAndSkipsABlankUser)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString conf = dir.filePath(QStringLiteral("KVision.conf"));
    QJsonObject zero;
    zero.insert(QStringLiteral("name"), QStringLiteral("Zero Channel"));
    zero.insert(QStringLiteral("ip"), QStringLiteral("10.0.0.99"));
    zero.insert(QStringLiteral("username"), QString());
    const QString live = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.99"), QStringLiteral("admin"), QStringLiteral("pw-nvr"), true),
        zero});
    const QString sealed = RecorderSecrets::sealRecorders(live, conf);
    ASSERT_FALSE(sealed.isEmpty());
    {
        QSettings settings(conf, QSettings::IniFormat);
        settings.beginGroup(QStringLiteral("Hikvision"));
        settings.setValue(QStringLiteral("recordersJson"), sealed);
        settings.endGroup();
        settings.sync();
    }

    QString user;
    QString pass;
    RecorderSecrets::fillLogin(conf, QStringLiteral("10.0.0.99"), &user, &pass);
    EXPECT_EQ(user, QStringLiteral("admin"));
    EXPECT_EQ(pass, QStringLiteral("pw-nvr"));

    user.clear();
    pass = QStringLiteral("already");
    RecorderSecrets::fillLogin(conf, QStringLiteral("10.0.0.99"), &user, &pass);
    EXPECT_EQ(user, QStringLiteral("admin"));
    EXPECT_EQ(pass, QStringLiteral("already"));

    user = QStringLiteral("other");
    pass = QStringLiteral("kept");
    RecorderSecrets::fillLogin(conf, QStringLiteral("10.0.0.99"), &user, &pass);
    EXPECT_EQ(user, QStringLiteral("other"));
    EXPECT_EQ(pass, QStringLiteral("kept"));

    user.clear();
    pass.clear();
    RecorderSecrets::fillLogin(conf, QStringLiteral("10.0.0.8"), &user, &pass);
    EXPECT_TRUE(user.isEmpty());
    EXPECT_TRUE(pass.isEmpty());

    const QString both = compact(QJsonArray{
        recorder(QStringLiteral("10.0.0.99"), QStringLiteral("admin"), QStringLiteral("pw-nvr"), true),
        recorder(QStringLiteral("10.0.0.99"), QStringLiteral("guest"), QStringLiteral("pw-guest"), true)});
    const QString sealedBoth = RecorderSecrets::sealRecorders(both, conf);
    ASSERT_FALSE(sealedBoth.isEmpty());
    {
        QSettings settings(conf, QSettings::IniFormat);
        settings.beginGroup(QStringLiteral("Hikvision"));
        settings.setValue(QStringLiteral("recordersJson"), sealedBoth);
        settings.endGroup();
        settings.sync();
    }
    user.clear();
    pass.clear();
    RecorderSecrets::fillLogin(conf, QStringLiteral("10.0.0.99"), &user, &pass);
    EXPECT_TRUE(user.isEmpty());
    EXPECT_TRUE(pass.isEmpty());
}
