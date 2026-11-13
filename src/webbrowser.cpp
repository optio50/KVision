#include "webbrowser.h"

#include <QDebug>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QSet>
#include <QStandardPaths>
#include <QUrl>

namespace {
// The folders launcher files live in: system wide, for the user, and for Flatpak and Snap.
QStringList launcherDirs()
{
    QStringList dirs = QStandardPaths::standardLocations(QStandardPaths::ApplicationsLocation);
    dirs << QStringLiteral("/var/lib/flatpak/exports/share/applications")
         << QDir::homePath() + QStringLiteral("/.local/share/flatpak/exports/share/applications")
         << QStringLiteral("/var/lib/snapd/desktop/applications");
    dirs.removeDuplicates();
    return dirs;
}

QString launcherPath(const QString &id)
{
    // The id is a file name only, never a path, so a saved value cannot point somewhere else.
    if (id.isEmpty() || id.contains(QLatin1Char('/')) || !id.endsWith(QLatin1String(".desktop")))
        return QString();
    for (const QString &d : launcherDirs()) {
        const QString p = d + QLatin1Char('/') + id;
        if (QFileInfo::exists(p))
            return p;
    }
    return QString();
}

// A value from the [Desktop Entry] group of a launcher file ("" when missing), read straight from the file. QSettings is not
// used: it treats a value with semicolons (MimeType=a;b;c) as a list and keeps only the first item.
QString entry(const QString &path, const QString &key)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return QString();
    bool inEntry = false;
    const QString prefix = key + QLatin1Char('=');
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.startsWith(QLatin1Char('['))) {
            inEntry = line == QLatin1String("[Desktop Entry]");
            continue;
        }
        if (inEntry && line.startsWith(prefix))
            return line.mid(prefix.size()).trimmed();
    }
    return QString();
}
}

WebBrowser::WebBrowser(QObject *parent) : QObject(parent) {}

void WebBrowser::setChoice(const QString &choice)
{
    m_choice = choice.trimmed();
}

// Splits a command line into words the way a shell would for simple cases (quotes, backslash), without running a shell.
QStringList WebBrowser::splitCommand(const QString &command)
{
    QStringList out;
    QString cur;
    bool inWord = false;
    QChar quote;
    for (int i = 0; i < command.size(); ++i) {
        const QChar ch = command.at(i);
        if (!quote.isNull()) {
            if (ch == quote)
                quote = QChar();
            else if (ch == QLatin1Char('\\') && quote == QLatin1Char('"') && i + 1 < command.size())
                cur += command.at(++i);
            else
                cur += ch;
        } else if (ch == QLatin1Char('"') || ch == QLatin1Char('\'')) {
            quote = ch;
            inWord = true;
        } else if (ch == QLatin1Char('\\') && i + 1 < command.size()) {
            cur += command.at(++i);
            inWord = true;
        } else if (ch.isSpace()) {
            if (inWord) {
                out << cur;
                cur.clear();
                inWord = false;
            }
        } else {
            cur += ch;
            inWord = true;
        }
    }
    if (inWord)
        out << cur;
    return out;
}

// The command from a launcher file's Exec= line, with the address in place of %u / %U / %f / %F (the other field codes
// are dropped). The first word is the program. No shell is involved.
bool WebBrowser::commandFromLauncher(const QString &launcherId, const QString &url, QString *program, QStringList *args)
{
    const QString path = launcherPath(launcherId);
    if (path.isEmpty())
        return false;
    const QString exec = entry(path, QStringLiteral("Exec"));
    const QStringList words = splitCommand(exec);
    if (words.isEmpty())
        return false;
    QStringList out;
    bool gaveUrl = false;
    for (const QString &w : words) {
        if (w == QLatin1String("%u") || w == QLatin1String("%U") || w == QLatin1String("%f") || w == QLatin1String("%F")) {
            out << url;
            gaveUrl = true;
        } else if (w.size() == 2 && w.startsWith(QLatin1Char('%'))) {
            continue; // %i %c %k and the like mean nothing here
        } else if (w.contains(QLatin1String("%u")) || w.contains(QLatin1String("%U"))) {
            QString v = w;
            v.replace(QLatin1String("%u"), url).replace(QLatin1String("%U"), url);
            out << v;
            gaveUrl = true;
        } else {
            out << w;
        }
    }
    if (!gaveUrl)
        out << url;
    *program = out.takeFirst();
    *args = out;
    return true;
}

bool WebBrowser::commandFor(const QString &url, QString *program, QStringList *args) const
{
    if (m_choice.startsWith(QLatin1String("id:")))
        return commandFromLauncher(m_choice.mid(3), url, program, args);
    if (m_choice.startsWith(QLatin1String("cmd:"))) {
        QStringList words = splitCommand(m_choice.mid(4));
        if (words.isEmpty())
            return false;
        bool gaveUrl = false;
        for (QString &w : words) {
            if (w.contains(QLatin1String("%u"))) {
                w.replace(QLatin1String("%u"), url);
                gaveUrl = true;
            }
        }
        if (!gaveUrl)
            words << url;
        *program = words.takeFirst();
        *args = words;
        return true;
    }
    return false;
}

QString WebBrowser::describe() const
{
    QString program;
    QStringList args;
    if (!commandFor(QStringLiteral("http://ADDRESS"), &program, &args))
        return QString();
    return (QStringList() << program << args).join(QLatin1Char(' '));
}

// The browsers installed here: launchers that handle web links, each shown once by name (two launchers that run the
// same program, such as a Flatpak export beside the normal one, are merged).
QVariantList WebBrowser::browsers() const
{
    QVariantList out;
    QSet<QString> seenFiles, seenCommands;
    for (const QString &dir : launcherDirs()) {
        const QFileInfoList files = QDir(dir).entryInfoList({QStringLiteral("*.desktop")}, QDir::Files, QDir::Name);
        for (const QFileInfo &fi : files) {
            if (seenFiles.contains(fi.fileName()))
                continue;
            seenFiles.insert(fi.fileName());
            const QString p = fi.absoluteFilePath();
            if (!entry(p, QStringLiteral("MimeType")).contains(QLatin1String("x-scheme-handler/http")))
                continue;
            if (entry(p, QStringLiteral("NoDisplay")) == QLatin1String("true") || entry(p, QStringLiteral("Hidden")) == QLatin1String("true"))
                continue;
            QString program;
            QStringList args;
            if (!commandFromLauncher(fi.fileName(), QStringLiteral("http://x"), &program, &args))
                continue;
            const QString key = program + QLatin1Char(' ') + args.join(QLatin1Char(' '));
            if (seenCommands.contains(key))
                continue;
            seenCommands.insert(key);
            out.append(QVariantMap{{QStringLiteral("name"), entry(p, QStringLiteral("Name"))}, {QStringLiteral("id"), fi.fileName()}});
        }
    }
    return out;
}

bool WebBrowser::open(const QString &url)
{
    const QUrl parsed(url);
    // Only ever hand a web address to a browser: never a file or another kind of link.
    if (!parsed.isValid() || (parsed.scheme() != QLatin1String("http") && parsed.scheme() != QLatin1String("https")))
        return false;

    QString program;
    QStringList args;
    if (commandFor(url, &program, &args)) {
        // Detached: KVision does not wait for the browser, and the browser keeps running if KVision is closed.
        // Its input and output go nowhere. Otherwise it keeps KVision's terminal open (the launcher's output pipe), so the shell
        // prompt does not come back after KVision closes until the browser is closed too, and its messages land in that terminal.
        QProcess browser;
        browser.setProgram(program);
        browser.setArguments(args);
        browser.setStandardInputFile(QProcess::nullDevice());
        browser.setStandardOutputFile(QProcess::nullDevice());
        browser.setStandardErrorFile(QProcess::nullDevice());
        if (browser.startDetached())
            return true;
        qWarning() << "[Browser] could not start" << program << "- using the system default instead";
    }
    return QDesktopServices::openUrl(parsed);
}
