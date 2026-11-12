#include "eventservice.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QProcess>
#include <QStandardPaths>
#include <QStringList>

#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {
const char *kUnitName = "kvision-events.service";

QString unitPath()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QStringLiteral("/systemd/user/")
           + QLatin1String(kUnitName);
}

// Runs systemctl --user and returns its exit code (-1 if it could not run); output goes to `out` when given.
int systemctl(const QStringList &args, QString *out = nullptr)
{
    QProcess p;
    p.start(QStringLiteral("systemctl"), QStringList{QStringLiteral("--user")} + args);
    if (!p.waitForFinished(8000)) {
        p.kill();
        return -1;
    }
    if (out)
        *out = QString::fromUtf8(p.readAllStandardOutput() + p.readAllStandardError()).trimmed();
    return p.exitStatus() == QProcess::NormalExit ? p.exitCode() : -1;
}

QString quoted(const QString &s)
{
    QString r = s;
    r.replace(QLatin1Char('\\'), QStringLiteral("\\\\")).replace(QLatin1Char('"'), QStringLiteral("\\\""));
    return QLatin1Char('"') + r + QLatin1Char('"');
}
}

namespace EventService {

QString lockPath(const QString &configDir)
{
    return configDir + QStringLiteral("/kvision-ui.lock");
}

QString statusPath(const QString &configDir)
{
    return configDir + QStringLiteral("/logs/EventLogger.status");
}

bool uiIsRunning(const QString &configDir)
{
    QLockFile lock(lockPath(configDir));
    qint64 pid = 0;
    QString host, app;
    if (!lock.getLockInfo(&pid, &host, &app) || pid <= 0)
        return false;
    return QFileInfo::exists(QStringLiteral("/proc/%1").arg(pid));
}

QString setServiceEnabled(bool on, const QString &configPath)
{
    const QString path = unitPath();
    if (!on) {
        if (!QFileInfo::exists(path))
            return QString(); // nothing installed: nothing to turn off
        systemctl({QStringLiteral("disable"), QStringLiteral("--now"), QLatin1String(kUnitName)});
        return QString();
    }

    QString exec = quoted(QCoreApplication::applicationFilePath()) + QStringLiteral(" --headless-events");
    if (!configPath.isEmpty())
        exec += QStringLiteral(" --config ") + quoted(configPath);
    const QString unit = QStringLiteral(
        "[Unit]\n"
        "Description=KVision background detection logger\n"
        "After=network-online.target\n\n"
        "[Service]\n"
        "Type=notify\n"
        "NotifyAccess=main\n"
        "ExecStart=%1\n"
        "Restart=always\n"
        "RestartSec=10\n"
        "WatchdogSec=90\n"
        "Nice=10\n\n"
        "[Install]\n"
        "WantedBy=default.target\n").arg(exec);

    QFile existing(path);
    const bool same = existing.open(QIODevice::ReadOnly) && existing.readAll() == unit.toUtf8();
    existing.close();
    if (!same) {
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
            return QStringLiteral("cannot write ") + path + QStringLiteral(": ") + f.errorString();
        f.write(unit.toUtf8());
        f.close();
        if (systemctl({QStringLiteral("daemon-reload")}) != 0)
            return QStringLiteral("systemctl --user daemon-reload failed (is systemd running for this user?)");
    }
    QString out;
    if (systemctl({QStringLiteral("enable"), QStringLiteral("--now"), QLatin1String(kUnitName)}, &out) != 0)
        return QStringLiteral("could not start the background service: ") + out;
    if (!same)
        systemctl({QStringLiteral("restart"), QLatin1String(kUnitName)}); // pick up a changed program path
    return QString();
}

QString restartService(const QString &configPath)
{
    QString err = setServiceEnabled(true, configPath); // writes the unit, enables it and starts it if stopped
    if (!err.isEmpty())
        return err;
    QString out;
    if (systemctl({QStringLiteral("restart"), QLatin1String(kUnitName)}, &out) != 0)
        return QStringLiteral("could not restart the background service: ") + out;
    return QString();
}

bool connectionAlive(const QVariantMap &state, qint64 now)
{
    const qint64 last = state.value(QStringLiteral("lastDataMs")).toLongLong();
    const qint64 opened = state.value(QStringLiteral("openedMs")).toLongLong();
    if (state.value(QStringLiteral("authFailed")).toBool())
        return false;
    if (last > 0 && last >= opened && now - last < 120000)
        return true;
    // Just opened (or being reopened after a short drop): give it time to deliver its first heartbeat.
    return opened > 0 && now - opened < 30000 && state.value(QStringLiteral("failures")).toInt() < 3;
}

bool serviceHealth(const QString &configDir, QString *text, bool *restartable)
{
    if (restartable)
        *restartable = false;
    QString dummy;
    QString &t = text ? *text : dummy;
    QFile f(statusPath(configDir));
    const bool haveFile = f.open(QIODevice::ReadOnly);
    const QJsonObject o = haveFile ? QJsonDocument::fromJson(f.readAll()).object() : QJsonObject();
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const qint64 age = haveFile ? (now - qint64(o.value(QStringLiteral("updatedMs")).toDouble())) / 1000 : -1;

    if (!haveFile || age > 45) {
        // No fresh report: ask systemd whether the service is even there.
        if (systemctl({QStringLiteral("is-active"), QStringLiteral("--quiet"), QLatin1String(kUnitName)}) != 0) {
            t = QStringLiteral("Background logging: not running");
            if (restartable)
                *restartable = true;
            return false;
        }
        if (restartable && haveFile)
            *restartable = true; // alive according to systemd but silent: hung
        t = haveFile ? QStringLiteral("Background logging: not responding (last report %1 s ago)").arg(age)
                     : QStringLiteral("Background logging: starting...");
        return !haveFile; // still starting is fine; a stale report is not
    }

    const QString state = o.value(QStringLiteral("state")).toString();
    if (state == QLatin1String("yielding")) {
        t = QStringLiteral("Background logging: standing by while KVision is open");
        return true;
    }
    if (state == QLatin1String("disabled")) {
        t = QStringLiteral("Background logging: switched off in settings");
        return true;
    }
    if (state == QLatin1String("stopped")) {
        t = QStringLiteral("Background logging: not running");
        if (restartable)
            *restartable = true;
        return false;
    }
    if (state != QLatin1String("logging")) {
        t = QStringLiteral("Background logging: ") + state;
        return true;
    }

    const QJsonArray conns = o.value(QStringLiteral("connections")).toArray();
    QStringList down;
    int noEvents = 0;
    for (const QJsonValue &v : conns) {
        const QJsonObject c = v.toObject();
        if (c.value(QStringLiteral("unsupported")).toBool()) {
            ++noEvents; // the camera has no event stream: nothing to log, and nothing a restart could fix
            continue;
        }
        if (!c.value(QStringLiteral("open")).toBool())
            down << c.value(QStringLiteral("name")).toString();
    }
    const int total = conns.size() - noEvents;
    if (!down.isEmpty()) {
        t = QStringLiteral("Background logging: %1 of %2 cameras not connected (%3)")
                .arg(down.size()).arg(total).arg(down.mid(0, 3).join(QStringLiteral(", ")));
        return false;
    }
    t = QStringLiteral("Background logging: running, %1 camera connection(s) OK").arg(total);
    if (noEvents > 0)
        t += QStringLiteral(" (%1 camera(s) without event support)").arg(noEvents);
    return true;
}

QString statusText(const QString &configDir)
{
    QString t;
    serviceHealth(configDir, &t);
    return t;
}

void notifySystemd(const char *message)
{
    const char *p = std::getenv("NOTIFY_SOCKET");
    if (!p || !*p)
        return;
    const size_t n = std::strlen(p);
    sockaddr_un addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (n >= sizeof(addr.sun_path))
        return;
    std::memcpy(addr.sun_path, p, n);
    if (addr.sun_path[0] == '@')
        addr.sun_path[0] = '\0'; // abstract socket
    const int fd = ::socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return;
    ::sendto(fd, message, std::strlen(message), 0, reinterpret_cast<sockaddr *>(&addr),
             static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + n));
    ::close(fd);
}

}
