#ifndef OFFLINERECORDERS_H
#define OFFLINERECORDERS_H

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QSettings>
#include <QString>
#include <QStringList>

// "Offline" recorders: the user ticked the box next to a recorder in the recorder monitoring window because its
// network is not connected. KVision must not try to reach those cameras at all (no video, no detection events, no
// logging, no status checks). The list is stored under NvrMonitoring/mutedRecorders, by recorder name, which is why
// the setting still has its old name.
namespace OfflineRecorders {

inline QString nameOf(const QJsonObject &recorder)
{
    QString name = recorder.value(QStringLiteral("name")).toString();
    if (name.isEmpty())
        name = recorder.value(QStringLiteral("ip")).toString();
    return name;
}

inline QSet<QString> readNames(const QString &configPath)
{
    QSettings s(configPath, QSettings::IniFormat);
    s.beginGroup(QStringLiteral("NvrMonitoring"));
    const QStringList list = s.value(QStringLiteral("mutedRecorders")).toStringList();
    return QSet<QString>(list.begin(), list.end());
}

// The recorder list (the JSON array KVision stores) without the offline recorders. Unchanged text comes back
// unchanged when nothing is offline, so callers that compare strings do not see a difference.
inline QString withoutOffline(const QString &recordersJson, const QSet<QString> &offline)
{
    if (offline.isEmpty())
        return recordersJson;
    const QJsonArray list = QJsonDocument::fromJson(recordersJson.toUtf8()).array();
    QJsonArray out;
    for (const QJsonValue &v : list) {
        if (!offline.contains(nameOf(v.toObject())))
            out.append(v);
    }
    return QString::fromUtf8(QJsonDocument(out).toJson(QJsonDocument::Compact));
}

inline QString hostOf(const QString &address)
{
    return address.section(QLatin1Char(':'), 0, 0).trimmed();
}

// The addresses (without port) of the offline recorders in the recorder list.
inline QSet<QString> offlineHosts(const QString &recordersJson, const QSet<QString> &offline)
{
    QSet<QString> out;
    if (offline.isEmpty())
        return out;
    const QJsonArray list = QJsonDocument::fromJson(recordersJson.toUtf8()).array();
    for (const QJsonValue &v : list) {
        const QJsonObject rec = v.toObject();
        if (offline.contains(nameOf(rec)))
            out.insert(hostOf(rec.value(QStringLiteral("ip")).toString()));
    }
    return out;
}

} // namespace OfflineRecorders

#endif // OFFLINERECORDERS_H
