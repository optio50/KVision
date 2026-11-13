#ifndef WEBBROWSER_H
#define WEBBROWSER_H

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>

// Opens web pages (a camera's own page, the project's links) in the browser the user chose, instead of whatever the
// system default is, and whether or not another browser is already running: the chosen browser is started directly
// with the address, and an already running one just opens a new tab.
class WebBrowser : public QObject
{
    Q_OBJECT

public:
    explicit WebBrowser(QObject *parent = nullptr);

    // The browsers installed on this machine, from the launcher files that handle web links: a list of maps with
    // name (what to show) and id (the launcher file name, e.g. "brave-browser.desktop"). Two launchers that start the
    // same program are listed once.
    Q_INVOKABLE QVariantList browsers() const;
    // Which browser to use: "" is the system default, "id:<launcher>" a browser from browsers(), "cmd:<command>" a
    // command typed by the user (the address is added as the last argument, or put where %u is). Saved by the caller.
    Q_INVOKABLE void setChoice(const QString &choice);
    Q_INVOKABLE QString choice() const { return m_choice; }
    // Opens the address. Returns true when the chosen browser was started (or, with the system default, when the system
    // accepted the address). A chosen browser that cannot be started falls back to the system default.
    Q_INVOKABLE bool open(const QString &url);
    // What would be run for the current choice, in words, for the settings page ("" for the system default).
    Q_INVOKABLE QString describe() const;

private:
    // The program and arguments for the current choice with the address filled in; empty when there is no usable choice.
    bool commandFor(const QString &url, QString *program, QStringList *args) const;
    static bool commandFromLauncher(const QString &launcherId, const QString &url, QString *program, QStringList *args);
    static QStringList splitCommand(const QString &command);

    QString m_choice;
};

#endif // WEBBROWSER_H
