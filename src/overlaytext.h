#ifndef OVERLAYTEXT_H
#define OVERLAYTEXT_H

#include <QObject>
#include <QSet>
#include <QString>
#include <QVariantMap>
#include <functional>

class QNetworkAccessManager;
class QTimer;

// Puts a value from an MQTT topic (an outside temperature, say) into one of a camera's on-screen text overlays and keeps
// it up to date. It is the only part of KVision that writes to a camera, so it is careful: it does nothing until the
// settings ask for it, changes only the text of the one slot (the rest of the overlay is read first and written back as
// it was), writes only when the text has changed, tries a login once and stops for the session when it is refused, and
// never retries a failed write in a loop (the next try is at the next update).
class OverlayText : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)

public:
    explicit OverlayText(QObject *parent = nullptr);

    QString status() const { return m_status; }

    // Replaces what the overlay does. settings holds: enabled, host, port (broker), user, pass, topic, field (the name in
    // a JSON message, empty for a plain number), camera (address), httpPort, camUser, camPass, slot (text overlay id),
    // template (for example "Outside {temp} {unit}"), unit ("C" or "F"), decimals, minutes. A change takes effect at once.
    Q_INVOKABLE void apply(const QVariantMap &settings);
    // Removes the chosen text overlay from the camera (switches it off and empties its text, which these cameras take as
    // "delete this entry") and stops the updates. Result goes to clearDone.
    Q_INVOKABLE void clearSlot(const QVariantMap &settings);
    // Reads the value and shows what would be written, without writing anything. Result goes to testDone.
    Q_INVOKABLE void test(const QVariantMap &settings);
    // The text for a value in Celsius: the template with {temp} and {unit} replaced.
    Q_INVOKABLE static QString formatText(double celsius, const QString &templ, const QString &unit, int decimals);
    // The number in an MQTT message: a plain number, or the field of a JSON object. ok says whether one was found.
    static double parseValue(const QString &payload, const QString &field, bool *ok = nullptr);

signals:
    void statusChanged();
    void testDone(bool ok, const QString &text, const QString &message);
    void clearDone(bool ok, const QString &message);

private:
    void runOnce(bool writeIt);
    void readCamera(const QString &text, bool writeIt);
    void writeCamera(const QString &xml, const QString &text, const QString &path);
    void setStatus(const QString &s);
    void request(const QString &method, const QString &path, const QByteArray &body, std::function<void(int, const QByteArray &)> done);
    static QString setSlotText(const QString &xml, int slot, const QString &text, bool *found);
    // The overlay XML with one text entry switched off and emptied; found says whether the entry was there.
    static QString removeSlot(const QString &xml, int slot, bool *found);

    QNetworkAccessManager *m_net = nullptr;
    QTimer *m_timer = nullptr;
    QVariantMap m_s;
    QString m_status;
    QString m_lastText;      // what was last written, so an unchanged value is not written again
    QSet<QString> m_refused; // cameras that refused the login this session
    bool m_busy = false;
};

#endif // OVERLAYTEXT_H
