#ifndef RECORDERSECRETS_H
#define RECORDERSECRETS_H

#include <QObject>
#include <QString>

// Recorder passwords are not stored in the settings JSON. They live in a
// mode-0600 file next to the config. openRecorders puts them back for the
// running app. sealRecorders takes them out before anything is written to
// the ini file or to an export. A password that is still in an old JSON
// blob is moved across on the first open.
class RecorderSecrets : public QObject
{
    Q_OBJECT
public:
    explicit RecorderSecrets(QObject *parent = nullptr) : QObject(parent) {}

    static QString secretsFileFor(const QString &configFile);
    static QString openRecorders(const QString &stored, const QString &configFile);
    // The password saved for this recorder. Empty when there is no match, or when
    // the user is blank and more than one account is saved for that address.
    static QString passwordFor(const QString &configFile, const QString &ip, const QString &user);
    // Fills a blank username or password from the saved recorder with this address.
    // A recorder that shares the address but has no username, such as a zero channel, is skipped.
    static void fillLogin(const QString &configFile, const QString &ip, QString *user, QString *password);
    static QString sealRecorders(const QString &live, const QString &configFile);

    // Read Hikvision/recordersJson, move any inline passwords into the secret
    // file, and return the list with passwords filled in.
    static QString recordersFromConfig(const QString &configFile);

    // configFile is the settings ini. An empty string comes back when the
    // secret file could not be locked or written; the caller must leave the
    // previous settings value alone in that case.
    Q_INVOKABLE QString open(const QString &stored, const QString &configFile) const;
    Q_INVOKABLE QString seal(const QString &live, const QString &configFile) const;
};

#endif
