#include "recordersecrets.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QSaveFile>
#include <QSettings>
#include <QUrl>

namespace {

QString identityKey(const QString &ip, const QString &user, const QString &channel)
{
    return ip + QLatin1Char('\n') + user + QLatin1Char('\n') + channel;
}

QJsonObject readSecrets(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return QJsonObject();
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    return doc.isObject() ? doc.object() : QJsonObject();
}

bool writeSecrets(const QString &path, const QJsonObject &secrets)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    file.write(QJsonDocument(secrets).toJson(QJsonDocument::Compact));
    if (!file.commit())
        return false;
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    return true;
}

QString compactJson(const QJsonArray &list)
{
    return QString::fromUtf8(QJsonDocument(list).toJson(QJsonDocument::Compact));
}

// Pull a password or a stream userinfo out of one object. A missing password
// keeps the one already on disk, so sealing an already-sealed list does not
// forget it. An empty password is a deliberate clear.
void sealOne(QJsonObject *obj, QJsonObject *secrets, const QJsonObject &existing, const QString &fallbackIp)
{
    QString ip = obj->value(QStringLiteral("ip")).toString().trimmed();
    if (ip.isEmpty())
        ip = fallbackIp;
    const QString user = obj->value(QStringLiteral("username")).toString();
    const QString channel = obj->contains(QStringLiteral("channelId"))
        ? obj->value(QStringLiteral("channelId")).toVariant().toString()
        : QString();
    const QString key = identityKey(ip, user, channel);
    if (obj->contains(QStringLiteral("password"))) {
        const QString pass = obj->value(QStringLiteral("password")).toString();
        if (pass.isEmpty()) {
            obj->remove(QStringLiteral("password"));
        } else if (!ip.isEmpty()) {
            secrets->insert(key, pass);
            obj->remove(QStringLiteral("password"));
        }
    } else if (!ip.isEmpty() && existing.contains(key)) {
        secrets->insert(key, existing.value(key));
    }

    if (obj->contains(QStringLiteral("streamUrl"))) {
        const QString raw = obj->value(QStringLiteral("streamUrl")).toString();
        QUrl url(raw);
        const QString info = url.userInfo();
        url.setUserInfo(QString());
        const QString stripped = url.toString();
        const QString urlKey = QStringLiteral("url\n") + stripped;
        const QString rawKey = QStringLiteral("url\n") + raw;
        // streamUrlSecret marks a sealed URL whose userinfo is already on disk.
        // A saved edit has no userinfo and no marker, which clears the secret.
        // Sealing the sealed list again still has the marker, so it keeps it.
        if (!info.isEmpty()) {
            secrets->insert(urlKey, info);
            obj->insert(QStringLiteral("streamUrl"), stripped);
            obj->insert(QStringLiteral("streamUrlSecret"), true);
        } else if (obj->value(QStringLiteral("streamUrlSecret")).toBool() && existing.contains(urlKey)) {
            secrets->insert(urlKey, existing.value(urlKey));
        } else if (obj->value(QStringLiteral("streamUrlSecret")).toBool() && existing.contains(rawKey)) {
            secrets->insert(rawKey, existing.value(rawKey));
        } else {
            obj->remove(QStringLiteral("streamUrlSecret"));
        }
    }

    if (!obj->contains(QStringLiteral("cameras")) || !obj->value(QStringLiteral("cameras")).isArray())
        return;
    QJsonArray cameras = obj->value(QStringLiteral("cameras")).toArray();
    for (int i = 0; i < cameras.size(); ++i) {
        if (!cameras.at(i).isObject())
            continue;
        QJsonObject camera = cameras.at(i).toObject();
        sealOne(&camera, secrets, existing, ip);
        cameras.replace(i, camera);
    }
    obj->insert(QStringLiteral("cameras"), cameras);
}

void openOne(QJsonObject *obj, const QJsonObject &secrets, const QString &fallbackIp)
{
    QString ip = obj->value(QStringLiteral("ip")).toString().trimmed();
    if (ip.isEmpty())
        ip = fallbackIp;
    const QString user = obj->value(QStringLiteral("username")).toString();
    const QString channel = obj->contains(QStringLiteral("channelId"))
        ? obj->value(QStringLiteral("channelId")).toVariant().toString()
        : QString();
    const QString key = identityKey(ip, user, channel);
    const QString inlinePass = obj->value(QStringLiteral("password")).toString();
    if (inlinePass.isEmpty() && !ip.isEmpty() && secrets.contains(key))
        obj->insert(QStringLiteral("password"), secrets.value(key));

    if (obj->contains(QStringLiteral("streamUrl"))) {
        const QString raw = obj->value(QStringLiteral("streamUrl")).toString();
        QUrl url(raw);
        if (url.userInfo().isEmpty()) {
            QString info = secrets.value(QStringLiteral("url\n") + raw).toString();
            if (info.isEmpty()) {
                QUrl probe(raw);
                probe.setUserInfo(QString());
                info = secrets.value(QStringLiteral("url\n") + probe.toString()).toString();
            }
            if (!info.isEmpty()) {
                url.setUserInfo(info);
                obj->insert(QStringLiteral("streamUrl"), url.toString());
            }
        }
        obj->remove(QStringLiteral("streamUrlSecret"));
    }

    if (!obj->contains(QStringLiteral("cameras")) || !obj->value(QStringLiteral("cameras")).isArray())
        return;
    QJsonArray cameras = obj->value(QStringLiteral("cameras")).toArray();
    for (int i = 0; i < cameras.size(); ++i) {
        if (!cameras.at(i).isObject())
            continue;
        QJsonObject camera = cameras.at(i).toObject();
        openOne(&camera, secrets, ip);
        cameras.replace(i, camera);
    }
    obj->insert(QStringLiteral("cameras"), cameras);
}

} // namespace

QString RecorderSecrets::secretsFileFor(const QString &configFile)
{
    const QFileInfo info(configFile);
    const QString dir = info.absolutePath().isEmpty() ? QDir::currentPath() : info.absolutePath();
    return dir + QStringLiteral("/recorders.secrets");
}

QString RecorderSecrets::passwordFor(const QString &configFile, const QString &ip, const QString &user)
{
    const QString host = ip.trimmed();
    if (configFile.isEmpty() || host.isEmpty())
        return QString();
    const QJsonObject secrets = readSecrets(secretsFileFor(configFile));
    if (!user.isEmpty())
        return secrets.value(identityKey(host, user, QString())).toString();
    const QString prefix = host + QLatin1Char('\n');
    QString found;
    for (auto it = secrets.constBegin(); it != secrets.constEnd(); ++it) {
        if (!it.key().startsWith(prefix))
            continue;
        if (!found.isEmpty())
            return QString();
        found = it.value().toString();
    }
    return found;
}

void RecorderSecrets::fillLogin(const QString &configFile, const QString &ip, QString *user, QString *password)
{
    if (!user || !password || configFile.isEmpty() || ip.trimmed().isEmpty())
        return;
    if (!user->isEmpty() && !password->isEmpty())
        return;
    QSettings settings(configFile, QSettings::IniFormat);
    settings.beginGroup(QStringLiteral("Hikvision"));
    const QString stored = settings.value(QStringLiteral("recordersJson"), QStringLiteral("[]")).toString();
    settings.endGroup();
    const QString host = ip.trimmed();
    QString foundUser;
    QString foundPass;
    int matches = 0;
    const QJsonArray list = QJsonDocument::fromJson(openRecorders(stored, configFile).toUtf8()).array();
    for (const QJsonValue &value : list) {
        const QJsonObject obj = value.toObject();
        if (obj.value(QStringLiteral("ip")).toString().trimmed() != host)
            continue;
        const QString savedUser = obj.value(QStringLiteral("username")).toString();
        if (savedUser.isEmpty())
            continue;
        ++matches;
        foundUser = savedUser;
        foundPass = obj.value(QStringLiteral("password")).toString();
    }
    if (matches != 1)
        return;
    if (user->isEmpty())
        *user = foundUser;
    if (password->isEmpty())
        *password = foundPass;
}

QString RecorderSecrets::openRecorders(const QString &stored, const QString &configFile)
{
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(stored.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isArray())
        return stored;
    const QJsonObject secrets = readSecrets(secretsFileFor(configFile));
    QJsonArray list = doc.array();
    for (int i = 0; i < list.size(); ++i) {
        if (!list.at(i).isObject())
            continue;
        QJsonObject obj = list.at(i).toObject();
        openOne(&obj, secrets, QString());
        list.replace(i, obj);
    }
    return compactJson(list);
}

QString RecorderSecrets::sealRecorders(const QString &live, const QString &configFile)
{
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(live.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isArray())
        return live;

    const QString path = secretsFileFor(configFile);
    QLockFile lock(path + QStringLiteral(".lock"));
    lock.setStaleLockTime(30000);
    if (!lock.tryLock(2000))
        return QString();

    const QJsonObject existing = readSecrets(path);
    QJsonObject secrets;
    QJsonArray list = doc.array();
    for (int i = 0; i < list.size(); ++i) {
        if (!list.at(i).isObject())
            continue;
        QJsonObject obj = list.at(i).toObject();
        sealOne(&obj, &secrets, existing, QString());
        list.replace(i, obj);
    }
    if (secrets != existing && !writeSecrets(path, secrets))
        return QString();
    return compactJson(list);
}

QString RecorderSecrets::recordersFromConfig(const QString &configFile)
{
    if (configFile.isEmpty())
        return QStringLiteral("[]");
    QSettings settings(configFile, QSettings::IniFormat);
    settings.beginGroup(QStringLiteral("Hikvision"));
    const bool present = settings.contains(QStringLiteral("recordersJson"));
    const QString stored = settings.value(QStringLiteral("recordersJson"), QStringLiteral("[]")).toString();
    settings.endGroup();
    const QString live = openRecorders(stored, configFile);
    // A missing key is not "the user deleted every recorder". Sealing that
    // default would wipe a secret file that belongs to this config directory.
    if (!present)
        return live;
    const QString sealed = sealRecorders(live, configFile);
    if (!sealed.isEmpty() && sealed != stored && sealed != live) {
        settings.beginGroup(QStringLiteral("Hikvision"));
        settings.setValue(QStringLiteral("recordersJson"), sealed);
        settings.endGroup();
        settings.sync();
    }
    return live;
}

QString RecorderSecrets::open(const QString &stored, const QString &configFile) const
{
    return openRecorders(stored, configFile);
}

QString RecorderSecrets::seal(const QString &live, const QString &configFile) const
{
    return sealRecorders(live, configFile);
}
