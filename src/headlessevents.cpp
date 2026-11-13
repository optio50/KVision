#include "headlessevents.h"

#include "eventservice.h"
#include "hikvisioneventlogger.h"
#include "hikvisionevents.h"

#include <QCoreApplication>
#include <QCommandLineParser>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSettings>
#include <QTimer>

#include <csignal>
#include <cstring>
#include <unistd.h>

namespace {
const int kTickMs = 5000;           // how often the loop checks for the UI, reads settings, and reports health
const int kWatchdogEveryTicks = 2;  // systemd watchdog ping every 10 s (the unit allows 90 s)

QCoreApplication *g_app = nullptr;

void onSignal(int)
{
    if (g_app)
        QMetaObject::invokeMethod(g_app, "quit", Qt::QueuedConnection);
}

struct Settings {
    bool enabled = false;
    QString recorders;
    QString source = QStringLiteral("camera");
    QString kinds = QStringLiteral("motion,line,intrusion,enter,exit,other");
    QString targets = QStringLiteral("human,vehicle,animal,other");
    int pictures = 100;
    bool logMotion = false; // log motion reports that name no target
    QString sourceOverrides = QStringLiteral("{}"); // where single cameras behind a recorder get their reports from
};

Settings readSettings(const QString &configPath)
{
    QSettings s(configPath, QSettings::IniFormat);
    Settings r;
    r.enabled = s.value(QStringLiteral("logDetectionEvents"), false).toBool();
    r.kinds = s.value(QStringLiteral("targetKinds"), r.kinds).toString();
    r.targets = s.value(QStringLiteral("targetTargets"), r.targets).toString();
    r.pictures = s.value(QStringLiteral("picturesPerCamera"), 100).toInt();
    r.logMotion = s.value(QStringLiteral("logUnlabelledMotion"), false).toBool();
    r.sourceOverrides = s.value(QStringLiteral("targetSourceOverrides"), QStringLiteral("{}")).toString();
    r.source = s.value(QStringLiteral("targetSource"), QStringLiteral("camera")).toString();
    if (r.source != QLatin1String("camera") && r.source != QLatin1String("recorder"))
        r.source = QStringLiteral("camera");
    s.beginGroup(QStringLiteral("Hikvision"));
    r.recorders = s.value(QStringLiteral("recordersJson"), QStringLiteral("[]")).toString();
    return r;
}

void writeStatus(const QString &configDir, const QString &state, HikvisionEvents &events, HikvisionEventLogger &logger)
{
    QJsonArray conns;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    for (const QVariant &v : events.connectionStates()) {
        const QVariantMap m = v.toMap();
        const qint64 last = m.value(QStringLiteral("lastDataMs")).toLongLong();
        const bool alive = EventService::connectionAlive(m, now);
        conns.append(QJsonObject{{QStringLiteral("ip"), m.value(QStringLiteral("ip")).toString()},
                                 {QStringLiteral("name"), m.value(QStringLiteral("name")).toString()},
                                 {QStringLiteral("open"), alive},
                                 {QStringLiteral("lastDataMs"), double(last)},
                                 {QStringLiteral("failures"), m.value(QStringLiteral("failures")).toInt()},
                                 {QStringLiteral("authFailed"), m.value(QStringLiteral("authFailed")).toBool()},
                                 {QStringLiteral("unsupported"), m.value(QStringLiteral("unsupported")).toBool()}});
    }
    QJsonObject o{{QStringLiteral("state"), state},
                  {QStringLiteral("pid"), double(::getpid())},
                  {QStringLiteral("updatedMs"), double(now)},
                  {QStringLiteral("watched"), logger.watchedCount()},
                  {QStringLiteral("connections"), conns}};
    QDir().mkpath(configDir + QStringLiteral("/logs"));
    QSaveFile f(EventService::statusPath(configDir));
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
        f.commit();
    }
}
}

bool wantsHeadlessEvents(int argc, char *argv[])
{
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--headless-events") == 0)
            return true;
    }
    return false;
}

int runHeadlessEvents(int argc, char *argv[])
{
    QCoreApplication::setApplicationName(QStringLiteral(APP_NAME));
    QCoreApplication::setOrganizationName(QStringLiteral(ORG_NAME));
    QCoreApplication app(argc, argv);
    g_app = &app;
    std::signal(SIGTERM, onSignal);
    std::signal(SIGINT, onSignal);

    // The same config file the UI uses (or the one named with --config / -c).
    QString configPath = QSettings().fileName();
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::strcmp(argv[i], "--config") == 0 || std::strcmp(argv[i], "-c") == 0)
            configPath = QString::fromLocal8Bit(argv[i + 1]);
    }
    const QString configDir = QDir::fromNativeSeparators(QFileInfo(configPath).absolutePath());
    qInfo() << "[Headless] KVision background detection logger, config" << configPath;

    HikvisionEvents events;
    HikvisionEventLogger logger(&events);

    Settings current;
    QString state = QStringLiteral("starting");
    int tick = 0;
    bool started = false;

    auto step = [&]() {
        ++tick;
        const Settings s = readSettings(configPath);
        const bool ui = EventService::uiIsRunning(configDir);

        // Filters are cheap and idempotent: apply them every time so a change in the UI takes effect.
        events.setAllowedKinds(s.kinds);
        events.setAllowedTargets(s.targets);
        events.setMaxPictures(s.pictures);
        events.setUnlabelledMotion(s.logMotion, false);

        if (!s.enabled)
            state = QStringLiteral("disabled");
        else if (ui)
            state = QStringLiteral("yielding"); // a KVision window owns the cameras' event streams right now
        else
            state = QStringLiteral("logging");

        // One writer at a time: only hold connections when enabled and no window is open.
        logger.configure(state == QLatin1String("logging"), s.recorders, s.source, configDir, s.sourceOverrides);
        current = s;

        writeStatus(configDir, state, events, logger);
        if (!started) {
            started = true;
            EventService::notifySystemd("READY=1");
        }
        if (tick % kWatchdogEveryTicks == 0)
            EventService::notifySystemd("WATCHDOG=1");
    };

    QTimer timer;
    timer.setInterval(kTickMs);
    QObject::connect(&timer, &QTimer::timeout, &app, step);
    timer.start();
    QTimer::singleShot(0, &app, step);

    const int rc = app.exec();
    logger.configure(false, QString(), QString(), QString());
    writeStatus(configDir, QStringLiteral("stopped"), events, logger);
    EventService::notifySystemd("STOPPING=1");
    return rc;
}
