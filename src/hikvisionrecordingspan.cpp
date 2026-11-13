#include "hikvisionrecordingspan.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QProcess>
#include <QRegularExpression>
#include <QThread>
#include <QUuid>

namespace {
const qint64 kMinGapMs = 10 * 60 * 1000; // never ask again sooner than this

struct Ask {
    QString ip;
    int port = 80;
    QString user;
    QString pass;
    QList<int> channels;
};

// The start of the oldest recording on one track, as ms since 1970; 0 when there is none or it could not be asked.
// *refused is set when the login was refused, so the recorder is left alone after that (a wrong password can lock it).
qint64 oldestOnTrack(const Ask &a, int channel, bool *refused)
{
    const QString body = QStringLiteral(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><CMSearchDescription><searchID>%1</searchID>"
        "<trackList><trackID>%2</trackID></trackList><timeSpanList><timeSpan><startTime>%3</startTime>"
        "<endTime>%4</endTime></timeSpan></timeSpanList><maxResults>1</maxResults>"
        "<searchResultPosition>0</searchResultPosition><metadataList>"
        "<metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList></CMSearchDescription>")
        .arg(QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper()).arg(channel * 100 + 1)
        // A recorder rejects a huge range (it answers "Device Error"), so ask for the last 60 days: more than any recorder
        // here keeps. A camera whose oldest video is older than that would simply show 60 days.
        .arg(QDateTime::currentDateTimeUtc().addDays(-60).toString(QStringLiteral("yyyy-MM-ddTHH:mm:ss")) + QLatin1Char('Z'))
        .arg(QDateTime::currentDateTimeUtc().addDays(1).toString(QStringLiteral("yyyy-MM-ddTHH:mm:ss")) + QLatin1Char('Z'));
    QProcess p;
    p.start(QStringLiteral("curl"), {QStringLiteral("-s"), QStringLiteral("--anyauth"), QStringLiteral("-u"),
                                     QStringLiteral("%1:%2").arg(a.user, a.pass), QStringLiteral("--max-time"), QStringLiteral("8"),
                                     QStringLiteral("-X"), QStringLiteral("POST"), QStringLiteral("-H"),
                                     QStringLiteral("Content-Type: application/xml"), QStringLiteral("--data-binary"), body,
                                     QStringLiteral("-w"), QStringLiteral("\n%{http_code}"),
                                     QStringLiteral("http://%1:%2/ISAPI/ContentMgmt/search").arg(a.ip).arg(a.port)});
    if (!p.waitForFinished(12000)) {
        p.kill();
        return 0;
    }
    const QString out = QString::fromUtf8(p.readAllStandardOutput());
    const int code = out.section(QLatin1Char('\n'), -1).trimmed().toInt();
    if (code == 401) {
        if (refused)
            *refused = true;
        return 0;
    }
    static const QRegularExpression rx(QStringLiteral("<startTime>([^<]+)</startTime>"));
    const QString t = rx.match(out).captured(1);
    const QDateTime when = QDateTime::fromString(t, Qt::ISODate);
    return when.isValid() ? when.toMSecsSinceEpoch() : 0;
}
}

HikvisionRecordingSpan::HikvisionRecordingSpan(QObject *parent) : QObject(parent) {}

HikvisionRecordingSpan::~HikvisionRecordingSpan()
{
    if (m_worker) {
        m_worker->disconnect(this);
        m_worker->wait();
    }
}

qint64 HikvisionRecordingSpan::oldestMs(const QString &recorderIp, int channel) const
{
    return m_oldest.value(recorderIp + QLatin1Char('#') + QString::number(channel), 0);
}

void HikvisionRecordingSpan::refresh(const QString &recordersJson)
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (m_busy || (m_lastDoneMs > 0 && now - m_lastDoneMs < kMinGapMs))
        return;

    QList<Ask> asks;
    for (const QJsonValue &rv : QJsonDocument::fromJson(recordersJson.toUtf8()).array()) {
        const QJsonObject rec = rv.toObject();
        Ask a;
        a.ip = rec.value(QStringLiteral("ip")).toString().section(QLatin1Char(':'), 0, 0).trimmed();
        a.user = rec.value(QStringLiteral("username")).toString();
        a.pass = rec.value(QStringLiteral("password")).toString();
        a.port = rec.value(QStringLiteral("httpPort")).toVariant().toInt();
        if (a.port <= 0)
            a.port = 80;
        for (const QJsonValue &cv : rec.value(QStringLiteral("cameras")).toArray()) {
            const int ch = cv.toObject().value(QStringLiteral("channelId")).toVariant().toInt();
            if (ch > 0)
                a.channels << ch;
        }
        if (!a.ip.isEmpty() && !a.user.isEmpty() && !a.pass.isEmpty() && !a.channels.isEmpty()) // never send a blank login
            asks << a;
    }
    if (asks.isEmpty())
        return;

    m_busy = true;
    if (m_worker) {
        m_worker->wait();
        m_worker->deleteLater();
    }
    m_worker = QThread::create([this, asks]() {
        QHash<QString, qint64> found;
        for (const Ask &a : asks) {
            bool refused = false;
            for (int ch : a.channels) {
                const qint64 ms = oldestOnTrack(a, ch, &refused);
                if (refused)
                    break; // one refused login is enough for this recorder
                if (ms > 0)
                    found.insert(a.ip + QLatin1Char('#') + QString::number(ch), ms);
            }
        }
        QMetaObject::invokeMethod(this, [this, found]() {
            // Keep an earlier answer for a camera that did not answer this time, so a failed check never un-greys or
            // greys anything by itself.
            for (auto it = found.constBegin(); it != found.constEnd(); ++it)
                m_oldest.insert(it.key(), it.value());
            m_lastDoneMs = QDateTime::currentMSecsSinceEpoch();
            m_busy = false;
            ++m_revision;
            emit changed();
        }, Qt::QueuedConnection);
    });
    m_worker->start();
}
