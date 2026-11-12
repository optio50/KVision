#include "hikvisioneventlogger.h"

#include "eventservice.h"
#include "hikvisionevents.h"
#include "hikvisionmanager.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>
#include <QMetaObject>
#include <QStringList>
#include <QThread>

namespace {
const int kRetryMs = 60000; // a recorder that could not be asked is tried again after this long

QString hostOf(const QString &address)
{
    return address.section(QLatin1Char(':'), 0, 0).trimmed();
}

QString camName(const QString &recName, int ch, const QJsonObject &cam)
{
    QString n = cam.value(QStringLiteral("customName")).toString();
    if (n.isEmpty())
        n = cam.value(QStringLiteral("name")).toString();
    if (n.isEmpty())
        n = QStringLiteral("Camera %1").arg(ch);
    return QStringLiteral("%1 Ch. %2 %3").arg(recName).arg(ch).arg(n);
}

QString toJson(const QJsonObject &o)
{
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

int channelOf(const QJsonValue &v)
{
    return v.toObject().value(QStringLiteral("channelId")).toVariant().toInt();
}
}

QString HikvisionEventLogger::Entry::signature() const
{
    return QStringList{ip, QString::number(http), user, pass, name, recIp, QString::number(recChannel),
                       recorderMode ? QStringLiteral("R") : QStringLiteral("C"), chanInfoJson, lensJson}
        .join(QLatin1Char('\x1f'));
}

HikvisionEventLogger::HikvisionEventLogger(HikvisionEvents *events, QObject *parent)
    : QObject(parent), m_events(events)
{
    m_retry = new QTimer(this);
    m_retry->setSingleShot(true);
    m_retry->setInterval(kRetryMs);
    connect(m_retry, &QTimer::timeout, this, [this]() {
        if (m_enabled)
            startPlan();
    });
}

HikvisionEventLogger::~HikvisionEventLogger()
{
    if (m_thread) {
        m_thread->wait();
        delete m_thread;
        m_thread = nullptr;
    }
}

QString HikvisionEventLogger::setBackgroundService(bool on, const QString &configPath)
{
    const QString err = EventService::setServiceEnabled(on, configPath);
    if (!err.isEmpty())
        qWarning() << "[EventLogger] background service:" << err;
    return err;
}

QString HikvisionEventLogger::backgroundStatus(const QString &configDir) const
{
    return EventService::statusText(configDir);
}

void HikvisionEventLogger::monitorBackground(bool on, const QString &configDir, const QString &configPath)
{
    m_bgDir = configDir;
    m_bgConfigPath = configPath;
    if (!m_bgTimer) {
        m_bgTimer = new QTimer(this);
        m_bgTimer->setInterval(10000);
        connect(m_bgTimer, &QTimer::timeout, this, &HikvisionEventLogger::checkBackground);
    }
    if (on == m_bgMonitored)
        return;
    m_bgMonitored = on;
    m_bgBad = 0;
    m_bgAutoTries = 0;
    m_bgOk = true;
    m_bgText.clear();
    if (on) {
        m_bgTimer->start();
        QTimer::singleShot(3000, this, &HikvisionEventLogger::checkBackground); // give a fresh service a moment to report
    } else {
        m_bgTimer->stop();
    }
    emit backgroundHealthChanged();
}

void HikvisionEventLogger::ensureBackground(const QString &configPath)
{
    QThread *t = QThread::create([this, configPath]() {
        const QString err = EventService::setServiceEnabled(true, configPath);
        QMetaObject::invokeMethod(this, [this, err]() {
            if (!err.isEmpty())
                qWarning() << "[EventLogger] background service:" << err;
            QTimer::singleShot(4000, this, &HikvisionEventLogger::checkBackground);
        }, Qt::QueuedConnection);
    });
    connect(t, &QThread::finished, t, &QObject::deleteLater);
    t->start();
}

void HikvisionEventLogger::restartBackground(const QString &configPath)
{
    if (m_bgRestarting)
        return;
    m_bgRestarting = true;
    m_bgText = QStringLiteral("Background logging: restarting...");
    emit backgroundHealthChanged();
    QThread *t = QThread::create([this, configPath]() {
        const QString err = EventService::restartService(configPath);
        QMetaObject::invokeMethod(this, [this, err]() {
            m_bgRestarting = false;
            m_bgBad = 0;
            if (!err.isEmpty())
                qWarning() << "[EventLogger] background service:" << err;
            if (m_bgAutoRun)
                emit backgroundAutoRestarted(err);
            else
                emit backgroundRestartFinished(err);
            m_bgAutoRun = false;
            // Give the service a few seconds to report, then look again.
            QTimer::singleShot(4000, this, &HikvisionEventLogger::checkBackground);
            emit backgroundHealthChanged();
        }, Qt::QueuedConnection);
    });
    connect(t, &QThread::finished, t, &QObject::deleteLater);
    t->start();
}

void HikvisionEventLogger::checkBackground()
{
    if (!m_bgMonitored || m_bgRestarting)
        return;
    QString text;
    bool restartable = false;
    const bool ok = EventService::serviceHealth(m_bgDir, &text, &restartable);
    // A single bad reading can be a camera restarting or a service being restarted: ask for two in a row.
    m_bgBad = ok ? 0 : m_bgBad + 1;
    const bool shownOk = m_bgBad < 2;
    if (ok)
        m_bgAutoTries = 0;
    // Down or hung for two checks in a row while the app is running: restart it on our own. Waits longer after
    // each failed attempt (1 min, 2, 4, ... up to 10) so a service that cannot start is not hammered.
    if (!shownOk && restartable && !m_bgConfigPath.isEmpty()) {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        const qint64 wait = qint64(60000) << qMin(m_bgAutoTries, 4);
        if (m_bgAutoTries == 0 || now - m_bgLastAutoMs >= qMin<qint64>(wait, 600000)) {
            m_bgLastAutoMs = now;
            ++m_bgAutoTries;
            qWarning() << "[EventLogger] the background service is down or not responding: restarting it (attempt"
                       << m_bgAutoTries << ")";
            m_bgAutoRun = true;
            // Show the problem first (red icon), and keep it red until a check finds the service healthy again.
            m_bgOk = false;
            m_bgText = text;
            emit backgroundHealthChanged();
            restartBackground(m_bgConfigPath);
            return;
        }
    }
    if (shownOk != m_bgOk || text != m_bgText) {
        m_bgOk = shownOk;
        m_bgText = text;
        emit backgroundHealthChanged();
    }
}

void HikvisionEventLogger::configure(bool enabled, const QString &recordersJson, const QString &targetSource,
                                     const QString &configDir)
{
    if (m_configured && enabled == m_enabled && recordersJson == m_recordersJson
        && targetSource == m_targetSource && configDir == m_configDir)
        return;
    m_configured = true;
    m_enabled = enabled;
    m_recordersJson = recordersJson;
    m_targetSource = targetSource;
    m_configDir = configDir;

    if (!m_enabled) {
        m_retry->stop();
        applyPlan(Plan());
        return;
    }
    startPlan();
}

void HikvisionEventLogger::startPlan()
{
    if (m_planning) {
        m_replan = true;
        return;
    }
    m_planning = true;
    m_replan = false;
    const QByteArray json = m_recordersJson.toUtf8();
    const QString source = m_targetSource;
    const QString dir = m_configDir;
    if (m_thread) {
        m_thread->wait();
        delete m_thread;
    }
    m_thread = QThread::create([this, json, source, dir]() {
        const Plan plan = buildPlan(json, source, dir);
        QMetaObject::invokeMethod(this, [this, plan]() { finishPlan(plan); }, Qt::QueuedConnection);
    });
    m_thread->start();
}

void HikvisionEventLogger::finishPlan(const Plan &plan)
{
    m_planning = false;
    if (!m_enabled)
        return;
    if (m_replan) {
        startPlan(); // the inputs changed while this one was being worked out: its answer is stale
        return;
    }
    applyPlan(plan);
    if (!plan.failedRecorders.isEmpty()) {
        qWarning() << "[EventLogger] could not read the camera list of" << plan.failedRecorders.values()
                   << "- trying again in" << kRetryMs / 1000 << "seconds";
        m_retry->start();
    }
}

void HikvisionEventLogger::applyPlan(const Plan &plan)
{
    QHash<QString, Entry> wanted;
    for (const Entry &e : plan.entries)
        wanted.insert(e.ip, e);

    // Close what is no longer wanted (or has changed), unless its recorder could not be asked this time.
    const auto keys = m_active.keys();
    for (const QString &ip : keys) {
        const Entry old = m_active.value(ip);
        const auto it = wanted.constFind(ip);
        if (it != wanted.constEnd() && it->signature() == old.signature())
            continue;
        if (it == wanted.constEnd() && plan.failedRecorders.contains(old.recIp))
            continue;
        m_events->unwatch(ip);
        m_active.remove(ip);
    }
    for (auto it = wanted.constBegin(); it != wanted.constEnd(); ++it) {
        if (m_active.contains(it.key()))
            continue;
        const Entry &e = it.value();
        m_events->watch(e.ip, e.http, e.user, e.pass, e.name, e.configDir, e.recIp, e.recChannel, e.recorderMode);
        if (!e.chanInfoJson.isEmpty())
            m_events->setChannelInfo(e.ip, e.chanInfoJson);
        if (!e.lensJson.isEmpty())
            m_events->setLensInfo(e.ip, e.lensJson);
        m_active.insert(it.key(), e);
    }
    qInfo() << "[EventLogger] logging detection events from" << m_active.size() << "connection(s)";
}

// Works out which addresses to listen to, the way a tile does for the camera it shows. Runs on a worker thread.
HikvisionEventLogger::Plan HikvisionEventLogger::buildPlan(const QByteArray &recordersJson, const QString &targetSource,
                                                           const QString &configDir)
{
    Plan plan;
    const QJsonArray list = QJsonDocument::fromJson(recordersJson).array();
    for (const QJsonValue &rv : list) {
        const QJsonObject rec = rv.toObject();
        const QString recIp = hostOf(rec.value(QStringLiteral("ip")).toString());
        const QString user = rec.value(QStringLiteral("username")).toString();
        const QString pass = rec.value(QStringLiteral("password")).toString();
        if (recIp.isEmpty() || user.isEmpty() || pass.isEmpty())
            continue; // never send a login that is known to be incomplete
        int http = rec.value(QStringLiteral("httpPort")).toVariant().toInt();
        if (http <= 0)
            http = 80;
        QString recName = rec.value(QStringLiteral("name")).toString();
        if (recName.isEmpty())
            recName = recIp;
        const QJsonArray cams = rec.value(QStringLiteral("cameras")).toArray();

        Entry base;
        base.http = http;
        base.user = user;
        base.pass = pass;
        base.configDir = configDir;
        base.recIp = recIp;

        if (cams.size() <= 2) {
            // A camera, or a dual-lens camera: it has its own address, and each lens is a channel on one stream.
            Entry e = base;
            e.ip = recIp;
            const int first = cams.isEmpty() ? 1 : qMax(1, channelOf(cams.first()));
            e.recChannel = first;
            e.name = cams.isEmpty() ? QStringLiteral("%1 Ch. 1").arg(recName) : camName(recName, first, cams.first().toObject());
            if (cams.size() == 2) {
                QJsonObject lens;
                for (const QJsonValue &cv : cams) {
                    const int ch = channelOf(cv);
                    lens.insert(QString::number(ch), QJsonObject{{QStringLiteral("name"), camName(recName, ch, cv.toObject())},
                                                                 {QStringLiteral("channel"), ch}});
                }
                e.lensJson = toJson(lens);
            }
            plan.entries.append(e);
            continue;
        }

        // A recorder with more cameras: ask it which camera sits behind each channel.
        const QHash<int, QVariantMap> proxy = HikvisionManager::fetchProxyChannels(recIp, http, user, pass);
        if (proxy.isEmpty()) {
            plan.failedRecorders.insert(recIp);
            continue;
        }

        if (targetSource == QLatin1String("recorder")) {
            // One connection to the recorder serves every camera behind it.
            Entry e = base;
            e.ip = recIp;
            e.recorderMode = true;
            e.name = recName;
            QJsonObject info;
            for (const QJsonValue &cv : cams) {
                const int ch = channelOf(cv);
                info.insert(QString::number(ch), QJsonObject{{QStringLiteral("name"), camName(recName, ch, cv.toObject())},
                                                             {QStringLiteral("ip"), proxy.value(ch).value(QStringLiteral("ip")).toString()}});
            }
            e.chanInfoJson = toJson(info);
            plan.entries.append(e);
            continue;
        }

        // One connection per camera behind the recorder (cameras that share an address share the connection).
        QMap<QString, Entry> byIp;
        QMap<QString, QJsonObject> lensByIp;
        for (const QJsonValue &cv : cams) {
            const int ch = channelOf(cv);
            const QVariantMap p = proxy.value(ch);
            const QString ip = p.value(QStringLiteral("ip")).toString();
            if (ip.isEmpty() || ip == recIp)
                continue;
            const QString nm = camName(recName, ch, cv.toObject());
            if (!byIp.contains(ip)) {
                Entry e = base;
                e.ip = ip;
                e.http = 80; // a camera behind a recorder is reached on its own port 80, as a tile does
                e.recChannel = ch;
                e.name = nm;
                byIp.insert(ip, e);
            }
            const int lensNo = qMax(1, p.value(QStringLiteral("channel")).toInt());
            lensByIp[ip].insert(QString::number(lensNo), QJsonObject{{QStringLiteral("name"), nm}, {QStringLiteral("channel"), ch}});
        }
        for (auto it = byIp.begin(); it != byIp.end(); ++it) {
            const QJsonObject lens = lensByIp.value(it.key());
            if (lens.size() > 1)
                it->lensJson = toJson(lens);
            plan.entries.append(it.value());
        }
    }
    return plan;
}
