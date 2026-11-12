#ifndef EVENTSERVICE_H
#define EVENTSERVICE_H

#include <QString>
#include <QVariantMap>

// Shared pieces of the background (headless) detection logger: where its files live, the "UI is running"
// handover lock, and the systemd user service that keeps it alive.
namespace EventService {

// The UI holds this lock while it runs; the background logger sees it and steps aside (option A: one writer).
QString lockPath(const QString &configDir);
// The background logger writes its health here (JSON) about every ten seconds.
QString statusPath(const QString &configDir);
// True when a KVision window process holds the lock (read-only: never takes or disturbs it).
bool uiIsRunning(const QString &configDir);

// Installs/updates and enables (on = true), or disables and stops (on = false), the systemd user service
// "kvision-events.service" that runs `kvision --headless-events`. Returns an empty string, or an error message.
QString setServiceEnabled(bool on, const QString &configPath);
// Writes the unit if needed and (re)starts the service even if it was stopped by hand. Empty string or an error.
QString restartService(const QString &configPath);
// A one-line description of the background logger for the settings page.
QString statusText(const QString &configDir);

// Whether a connection (one entry of HikvisionEvents::connectionStates()) counts as working at time `now` (ms):
// data (a heartbeat comes about every 10 s) arrived in the last two minutes, or it was only just opened.
bool connectionAlive(const QVariantMap &state, qint64 now);
// Health of the background service as seen from its status file and systemd. Returns true when all is well
// (including "standing by while KVision is open"); text says what is going on either way.
// restartable (optional) is set when restarting the service could help: it is not running, or it has hung.
bool serviceHealth(const QString &configDir, QString *text, bool *restartable = nullptr);

// Systemd readiness/watchdog pings (no-ops when not started by systemd).
void notifySystemd(const char *message);

}

#endif // EVENTSERVICE_H
