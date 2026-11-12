#include "overlaytext.h"

#include "mqttonce.h"

#include <QAuthenticator>
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QLocale>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QTimer>
#include <QUrl>
#include <functional>

namespace {
const int kRequestTimeoutMs = 15000;
}

OverlayText::OverlayText(QObject *parent)
    : QObject(parent)
{
    m_net = new QNetworkAccessManager(this);
    connect(m_net, &QNetworkAccessManager::authenticationRequired, this, [](QNetworkReply *reply, QAuthenticator *auth) {
        // One attempt only: a second try with a wrong password could lock the camera.
        if (reply->property("authTried").toBool()) {
            reply->setProperty("refused", true);
            reply->abort();
            return;
        }
        reply->setProperty("authTried", true);
        auth->setUser(reply->property("camUser").toString());
        auth->setPassword(reply->property("camPass").toString());
    });
    m_timer = new QTimer(this);
    m_timer->setSingleShot(false);
    connect(m_timer, &QTimer::timeout, this, [this]() { runOnce(true); });
}

void OverlayText::setStatus(const QString &s)
{
    if (m_status == s)
        return;
    m_status = s;
    emit statusChanged();
}

QString OverlayText::formatText(double celsius, const QString &templ, const QString &unit, int decimals)
{
    const bool f = unit.compare(QStringLiteral("F"), Qt::CaseInsensitive) == 0;
    const double v = f ? celsius * 9.0 / 5.0 + 32.0 : celsius;
    QString num = QString::number(v, 'f', qBound(0, decimals, 3));
    if (num.startsWith(QLatin1String("-0")) && num.toDouble() == 0.0)
        num = num.mid(1); // "-0" and "-0.0" read as nonsense on a thermometer
    QString t = templ.isEmpty() ? QStringLiteral("{temp} {unit}") : templ;
    t.replace(QStringLiteral("{temp}"), num);
    t.replace(QStringLiteral("{unit}"), f ? QStringLiteral("F") : QStringLiteral("C"));
    return t;
}

double OverlayText::parseValue(const QString &payload, const QString &field, bool *ok)
{
    if (ok)
        *ok = false;
    const QString p = payload.trimmed();
    bool isNum = false;
    const double plain = p.toDouble(&isNum);
    if (isNum && field.trimmed().isEmpty()) {
        if (ok) *ok = true;
        return plain;
    }
    const QJsonDocument doc = QJsonDocument::fromJson(p.toUtf8());
    if (doc.isObject()) {
        QJsonValue v = doc.object();
        const QString f = field.trimmed().isEmpty() ? QStringLiteral("value") : field.trimmed();
        for (const QString &part : f.split(QLatin1Char('.'))) { // "a.b" reaches into nested objects
            if (!v.isObject())
                return 0;
            v = v.toObject().value(part);
        }
        if (v.isDouble()) {
            if (ok) *ok = true;
            return v.toDouble();
        }
        if (v.isString()) {
            bool good = false;
            const double d = v.toString().toDouble(&good);
            if (ok) *ok = good;
            return d;
        }
    }
    if (isNum) {
        if (ok) *ok = true;
        return plain;
    }
    return 0;
}

// Changes the text of one slot in the overlay XML and leaves everything else as it was.
QString OverlayText::setSlotText(const QString &xml, int slot, const QString &text, bool *found)
{
    static const QRegularExpression blockRx(QStringLiteral("<TextOverlay>.*?</TextOverlay>"), QRegularExpression::DotMatchesEverythingOption);
    QString escaped = text.toHtmlEscaped();
    QString out = xml;
    QRegularExpressionMatchIterator it = blockRx.globalMatch(xml);
    if (found)
        *found = false;
    while (it.hasNext()) {
        const QRegularExpressionMatch m = it.next();
        const QString block = m.captured(0);
        const QRegularExpressionMatch idm = QRegularExpression(QStringLiteral("<id>(\\d+)</id>")).match(block);
        if (!idm.hasMatch() || idm.captured(1).toInt() != slot)
            continue;
        QString nb = block;
        static const QRegularExpression txRx(QStringLiteral("<displayText>.*?</displayText>"), QRegularExpression::DotMatchesEverythingOption);
        if (txRx.match(nb).hasMatch())
            nb.replace(txRx, QStringLiteral("<displayText>") + escaped + QStringLiteral("</displayText>"));
        else
            nb.replace(QStringLiteral("</TextOverlay>"), QStringLiteral("<displayText>") + escaped + QStringLiteral("</displayText></TextOverlay>"));
        // A slot that is switched off shows nothing, so the text would never be seen.
        nb.replace(QRegularExpression(QStringLiteral("<enabled>false</enabled>")), QStringLiteral("<enabled>true</enabled>"));
        out.replace(m.capturedStart(0), m.capturedLength(0), nb);
        if (found)
            *found = true;
        return out;
    }
    // The slot is not in the list. These cameras leave an unused slot out of it (a slot switched off disappears too), and
    // they accept a new entry, so it is added, at the place the first existing text sits (or the usual corner).
    if (slot < 1 || slot > 4)
        return xml;
    QString px = QStringLiteral("0"), py = QStringLiteral("480");
    const QRegularExpressionMatch first = blockRx.match(xml);
    if (first.hasMatch()) {
        const QRegularExpressionMatch mx = QRegularExpression(QStringLiteral("<positionX>(\\d+)</positionX>")).match(first.captured(0));
        const QRegularExpressionMatch my = QRegularExpression(QStringLiteral("<positionY>(\\d+)</positionY>")).match(first.captured(0));
        if (mx.hasMatch()) px = mx.captured(1);
        if (my.hasMatch()) py = my.captured(1);
    }
    const QString entry = QStringLiteral("<TextOverlay><id>%1</id><enabled>true</enabled><positionX>%2</positionX><positionY>%3</positionY>"
                                         "<displayText>%4</displayText><directAngle></directAngle></TextOverlay>")
                              .arg(slot).arg(px, py, escaped);
    if (out.contains(QLatin1String("</TextOverlayList>"))) {
        out.insert(out.lastIndexOf(QLatin1String("</TextOverlayList>")), entry);
    } else {
        static const QRegularExpression selfRx(QStringLiteral("<TextOverlayList([^>]*?)\\s*/>"));
        const QRegularExpressionMatch sm = selfRx.match(out);
        if (!sm.hasMatch())
            return xml; // no list to add to
        out.replace(sm.capturedStart(0), sm.capturedLength(0), QStringLiteral("<TextOverlayList%1>%2</TextOverlayList>").arg(sm.captured(1), entry));
    }
    if (found)
        *found = true;
    return out;
}

// The overlay settings of the camera's own channel (1 for a single-lens camera; the second lens of a two-lens camera is 2).
static QString overlayPath(const QVariantMap &s)
{
    const int ch = s.value(QStringLiteral("camChannel")).toInt();
    return QStringLiteral("/ISAPI/System/Video/inputs/channels/%1/overlays").arg(ch > 0 ? ch : 1);
}

void OverlayText::request(const QString &method, const QString &path, const QByteArray &body, std::function<void(int, const QByteArray &)> done)
{
    const QString host = m_s.value(QStringLiteral("camera")).toString().section(QLatin1Char(':'), 0, 0).trimmed();
    const QString user = m_s.value(QStringLiteral("camUser")).toString();
    const QString pass = m_s.value(QStringLiteral("camPass")).toString();
    if (host.isEmpty() || user.isEmpty() || pass.isEmpty()) { // never send a login we know is incomplete
        QTimer::singleShot(0, this, [done]() { done(-1, QByteArray()); });
        return;
    }
    if (m_refused.contains(host)) { // refused earlier this session: do not try again
        QTimer::singleShot(0, this, [done]() { done(401, QByteArray()); });
        return;
    }
    QUrl url;
    url.setScheme(QStringLiteral("http"));
    url.setHost(host);
    url.setPort(m_s.value(QStringLiteral("httpPort")).toInt() > 0 ? m_s.value(QStringLiteral("httpPort")).toInt() : 80);
    url.setPath(path);
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
    if (!body.isEmpty())
        req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/xml"));
    QNetworkReply *reply = method == QLatin1String("PUT") ? m_net->put(req, body) : m_net->get(req);
    reply->setProperty("camUser", user);
    reply->setProperty("camPass", pass);
    QTimer::singleShot(kRequestTimeoutMs, reply, [reply]() { if (reply->isRunning()) reply->abort(); });
    connect(reply, &QNetworkReply::finished, this, [this, reply, host, done]() {
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const bool refused = reply->property("refused").toBool() || status == 401 || reply->error() == QNetworkReply::AuthenticationRequiredError;
        const QByteArray data = reply->isOpen() ? reply->readAll() : QByteArray();
        reply->deleteLater();
        if (refused) {
            m_refused.insert(host);
            done(401, data);
            return;
        }
        done(status, data);
    });
}

QString OverlayText::removeSlot(const QString &xml, int slot, bool *found)
{
    static const QRegularExpression blockRx(QStringLiteral("<TextOverlay>.*?</TextOverlay>"), QRegularExpression::DotMatchesEverythingOption);
    if (found)
        *found = false;
    QRegularExpressionMatchIterator it = blockRx.globalMatch(xml);
    while (it.hasNext()) {
        const QRegularExpressionMatch m = it.next();
        QString b = m.captured(0);
        const QRegularExpressionMatch idm = QRegularExpression(QStringLiteral("<id>(\\d+)</id>")).match(b);
        if (!idm.hasMatch() || idm.captured(1).toInt() != slot)
            continue;
        b.replace(QRegularExpression(QStringLiteral("<enabled>[^<]*</enabled>")), QStringLiteral("<enabled>false</enabled>"));
        b.replace(QRegularExpression(QStringLiteral("<displayText>.*?</displayText>"), QRegularExpression::DotMatchesEverythingOption),
                  QStringLiteral("<displayText></displayText>"));
        QString out = xml;
        out.replace(m.capturedStart(0), m.capturedLength(0), b);
        if (found)
            *found = true;
        return out;
    }
    return xml;
}

void OverlayText::clearSlot(const QVariantMap &settings)
{
    m_s = settings;
    m_timer->stop();           // an update must not write the slot again right after it is removed
    m_busy = true;
    const int slot = m_s.value(QStringLiteral("slot")).toInt();
    request(QStringLiteral("GET"), overlayPath(m_s), QByteArray(), [this, slot](int status, const QByteArray &data) {
        if (status != 200) {
            m_busy = false;
            emit clearDone(false, status == 401 ? tr("The camera refused the login. Nothing was changed.")
                                                : status == -1 ? tr("Choose a camera first.")
                                                               : tr("Could not read the camera's overlay (answer %1). Nothing was changed.").arg(status));
            return;
        }
        bool found = false;
        const QString changed = removeSlot(QString::fromUtf8(data), slot, &found);
        if (!found) {
            m_busy = false;
            m_lastText.clear();
            setStatus(QString());
            emit clearDone(true, tr("The camera has no text overlay number %1, so there is nothing to remove.").arg(slot));
            return;
        }
        request(QStringLiteral("PUT"), overlayPath(m_s), changed.toUtf8(), [this, slot](int st, const QByteArray &) {
            if (st != 200) {
                m_busy = false;
                emit clearDone(false, tr("The camera did not take the change (answer %1).").arg(st));
                return;
            }
            request(QStringLiteral("GET"), overlayPath(m_s), QByteArray(), [this, slot](int st2, const QByteArray &d) {
                m_busy = false;
                m_lastText.clear();
                setStatus(QString());
                bool still = false;
                const QString xml = QString::fromUtf8(d);
                static const QRegularExpression blockRx(QStringLiteral("<TextOverlay>.*?</TextOverlay>"), QRegularExpression::DotMatchesEverythingOption);
                QRegularExpressionMatchIterator it = blockRx.globalMatch(xml);
                while (it.hasNext()) {
                    const QString b = it.next().captured(0);
                    const QRegularExpressionMatch idm = QRegularExpression(QStringLiteral("<id>(\\d+)</id>")).match(b);
                    if (idm.hasMatch() && idm.captured(1).toInt() == slot
                        && (b.contains(QLatin1String("<enabled>true</enabled>")) || !QRegularExpression(QStringLiteral("<displayText></displayText>|<displayText/>")).match(b).hasMatch()))
                        still = true;
                }
                if (st2 == 200 && !still)
                    emit clearDone(true, tr("Text overlay number %1 was removed from the camera.").arg(slot));
                else
                    emit clearDone(false, tr("Sent the change, but the camera still shows overlay number %1.").arg(slot));
            });
        });
    });
}

void OverlayText::apply(const QVariantMap &settings)
{
    m_s = settings;
    m_timer->stop();
    m_busy = false;
    if (!m_s.value(QStringLiteral("enabled")).toBool()) {
        setStatus(QString());
        return;
    }
    const int minutes = qBound(1, m_s.value(QStringLiteral("minutes")).toInt(), 1440);
    m_timer->start(minutes * 60 * 1000);
    QTimer::singleShot(3000, this, [this]() { runOnce(true); }); // the first one soon after the start, not after a full period
}

void OverlayText::test(const QVariantMap &settings)
{
    m_s = settings;
    runOnce(false);
}

// Reads the value from the broker, then (when writeIt) puts it into the camera.
void OverlayText::runOnce(bool writeIt)
{
    if (m_busy && writeIt)
        return; // the last round has not finished
    m_busy = true;
    auto *mq = new MqttOnce(m_s.value(QStringLiteral("host")).toString(), m_s.value(QStringLiteral("port")).toInt(),
                            m_s.value(QStringLiteral("user")).toString(), m_s.value(QStringLiteral("pass")).toString(),
                            m_s.value(QStringLiteral("topic")).toString(), 20000, this);
    connect(mq, &MqttOnce::finished, this, [this, mq, writeIt](bool ok, const QString &payload, const QString &error) {
        mq->deleteLater();
        if (!ok) {
            m_busy = false;
            const QString msg = tr("Could not read the value: %1").arg(error);
            setStatus(msg);
            if (!writeIt)
                emit testDone(false, QString(), msg);
            return;
        }
        bool good = false;
        const double c = parseValue(payload, m_s.value(QStringLiteral("field")).toString(), &good);
        if (!good) {
            m_busy = false;
            const QString msg = tr("The message has no number to use: %1").arg(payload.left(80));
            setStatus(msg);
            if (!writeIt)
                emit testDone(false, QString(), msg);
            return;
        }
        const QString text = formatText(c, m_s.value(QStringLiteral("template")).toString(), m_s.value(QStringLiteral("unit")).toString(),
                                        m_s.value(QStringLiteral("decimals")).toInt());
        if (!writeIt) {
            m_busy = false;
            emit testDone(true, text, tr("The broker gave %1 (Celsius). This is what would be written.").arg(QString::number(c, 'f', 2)));
            return;
        }
        if (text == m_lastText) { // unchanged: leave the camera alone
            m_busy = false;
            setStatus(tr("%1  (unchanged, checked %2)").arg(text, QDateTime::currentDateTime().toString(QStringLiteral("HH:mm"))));
            return;
        }
        readCamera(text, true);
    });
    mq->start();
}

void OverlayText::readCamera(const QString &text, bool writeIt)
{
    Q_UNUSED(writeIt)
    request(QStringLiteral("GET"), overlayPath(m_s), QByteArray(), [this, text](int status, const QByteArray &data) {
        if (status != 200) {
            m_busy = false;
            setStatus(status == 401 ? tr("The camera refused the login. Not trying again until KVision is restarted.")
                                    : status == -1 ? tr("The camera address or login is missing.")
                                                   : tr("Could not read the camera's overlay (answer %1).").arg(status));
            return;
        }
        bool found = false;
        const QString xml = QString::fromUtf8(data);
        const QString changed = setSlotText(xml, m_s.value(QStringLiteral("slot")).toInt(), text, &found);
        if (!found) {
            m_busy = false;
            setStatus(tr("Could not add text overlay number %1 to the camera. Try another number.").arg(m_s.value(QStringLiteral("slot")).toInt()));
            return;
        }
        writeCamera(changed, text, overlayPath(m_s));
    });
}

void OverlayText::writeCamera(const QString &xml, const QString &text, const QString &path)
{
    request(QStringLiteral("PUT"), path, xml.toUtf8(), [this, text, path](int status, const QByteArray &) {
        if (status != 200) {
            m_busy = false;
            setStatus(status == 401 ? tr("The camera refused the login. Not trying again until KVision is restarted.")
                                    : tr("The camera did not take the text (answer %1). Will try again at the next update.").arg(status));
            return;
        }
        // Read it back, so the status says what the camera really holds.
        request(QStringLiteral("GET"), path, QByteArray(), [this, text](int st, const QByteArray &data) {
            m_busy = false;
            const QString now = QDateTime::currentDateTime().toString(QStringLiteral("HH:mm"));
            bool shown = false;
            if (st == 200) {
                static const QRegularExpression slotRx(QStringLiteral("<TextOverlay>.*?</TextOverlay>"), QRegularExpression::DotMatchesEverythingOption);
                QRegularExpressionMatchIterator it = slotRx.globalMatch(QString::fromUtf8(data));
                while (it.hasNext()) {
                    const QString b = it.next().captured(0);
                    const QRegularExpressionMatch idm = QRegularExpression(QStringLiteral("<id>(\\d+)</id>")).match(b);
                    if (idm.hasMatch() && idm.captured(1).toInt() == m_s.value(QStringLiteral("slot")).toInt())
                        shown = b.contains(text.toHtmlEscaped());
                }
            }
            if (shown) {
                m_lastText = text;
                setStatus(tr("%1  (written %2)").arg(text, now));
            } else {
                setStatus(tr("Sent \"%1\" but the camera does not show it. Will try again at the next update.").arg(text));
            }
        });
    });
}
