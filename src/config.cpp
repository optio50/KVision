#include "config.h"

#include <QDate>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QLoggingCategory>

Config::Config(QObject *parent)
    : Config(QSettings().fileName(), parent)
{
}

Config::Config(const QString &fileName, QObject *parent)
    : QObject(parent),
      m_fileName(fileName)
{
    qSetMessagePattern("%{message}");
    reconfigureLoggingFilterRules();

    connect(this, &Config::logLevelChanged, this, &Config::reconfigureLoggingFilterRules);

    // Create a backup of the config file on startup
    if (QFile::exists(m_fileName)) {
        // One copy per day, the last 14 days kept. The ".bak" copy below is replaced at every start, so a bad start (settings back at
        // their defaults) would otherwise overwrite the last good file with no way back.
        const QFileInfo info(m_fileName);
        const QString dailyPrefix = info.fileName() + QStringLiteral(".daily-");
        const QString dailyName = info.absolutePath() + QLatin1Char('/') + dailyPrefix + QDate::currentDate().toString(Qt::ISODate);
        if (!QFile::exists(dailyName))
            QFile::copy(m_fileName, dailyName);
        QDir dir(info.absolutePath());
        const QStringList dailies = dir.entryList(QStringList{dailyPrefix + QLatin1Char('*')}, QDir::Files, QDir::Name);
        for (int i = 0; i < dailies.size() - 14; ++i)
            dir.remove(dailies.at(i));

        QString backupFileName = m_fileName + ".bak";
        QFile::remove(backupFileName);
        QFile::copy(m_fileName, backupFileName);
    }
}

void Config::reconfigureLoggingFilterRules()
{
    QLoggingCategory::setFilterRules(QString("%1.critical=%2\n"
                                             "%1.warning=%3\n"
                                             "%1.info=%4\n"
                                             "%1.debug=%5")
                                             .arg("qmlav")
                                             .arg(m_logLevel >= Config::LogCritical ? "true" : "false",
                                                  m_logLevel >= Config::LogWarning ? "true" : "false",
                                                  m_logLevel >= Config::LogInfo ? "true" : "false",
                                                  m_logLevel >= Config::LogDebug ? "true" : "false"));
}
