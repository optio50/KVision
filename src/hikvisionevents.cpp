#include "hikvisionevents.h"

#include <QAuthenticator>
#include <QDebug>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>

namespace {
const int kMaxFailures = 3;       // after this many failed attempts in a row, stop trying
const int kRetryMs = 15000;       // wait between attempts
const int kMaxBuffer = 256 * 1024; // pictures can ride along in an event; never keep more than this
}

HikvisionEvents::HikvisionEvents(QObject *parent)
    : QObject(parent)
{
    m_net = new QNetworkAccessManager(this);
    connect(m_net, &QNetworkAccessManager::authenticationRequired, this,
            [](QNetworkReply *reply, QAuthenticator *auth) {
        // One attempt only: when the stored password is wrong, a second try could lock the camera.
        if (reply->property("authTried").toBool()) {
            reply->abort();
            return;
        }
        reply->setProperty("authTried", true);
        auth->setUser(reply->property("evUser").toString());
        auth->setPassword(reply->property("evPass").toString());
    });
}

HikvisionEvents::~HikvisionEvents()
{
    const auto ips = m_conns.keys();
    for (const QString &ip : ips)
        close(ip);
}

void HikvisionEvents::watch(const QString &ip, int httpPort, const QString &user, const QString &pass)
{
    if (ip.isEmpty() || user.isEmpty() || pass.isEmpty())
        return; // never send a login we know is incomplete: a wrong login counts toward a camera lockout
    Conn *c = m_conns.value(ip, nullptr);
    if (!c) {
        c = new Conn;
        c->ip = ip;
        c->httpPort = httpPort > 0 ? httpPort : 80;
        c->user = user;
        c->pass = pass;
        c->retry = new QTimer(this);
        c->retry->setSingleShot(true);
        c->retry->setInterval(kRetryMs);
        connect(c->retry, &QTimer::timeout, this, [this, ip]() {
            if (m_conns.contains(ip))
                open(ip);
        });
        m_conns.insert(ip, c);
    }
    ++c->watchers;
    if (!c->reply && !c->retry->isActive() && c->failures < kMaxFailures && !c->authFailed)
        open(ip);
}

void HikvisionEvents::unwatch(const QString &ip)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c)
        return;
    if (--c->watchers <= 0)
        close(ip);
}

void HikvisionEvents::close(const QString &ip)
{
    Conn *c = m_conns.take(ip);
    if (!c)
        return;
    if (c->retry) {
        c->retry->stop();
        c->retry->deleteLater();
    }
    if (c->reply) {
        c->reply->disconnect(this);
        c->reply->abort();
        c->reply->deleteLater();
    }
    delete c;
}

void HikvisionEvents::open(const QString &ip)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->reply)
        return;
    QUrl url;
    url.setScheme(QStringLiteral("http"));
    url.setHost(ip.section(QLatin1Char(':'), 0, 0).trimmed());
    url.setPort(c->httpPort);
    url.setPath(QStringLiteral("/ISAPI/Event/notification/alertStream"));
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
    c->buffer.clear();
    qDebug() << "[Events] opening the detection stream for" << ip;
    c->reply = m_net->get(req);
    c->reply->setProperty("evUser", c->user);
    c->reply->setProperty("evPass", c->pass);
    connect(c->reply, &QIODevice::readyRead, this, [this, ip]() { onReadyRead(ip); });
    QNetworkReply *reply = c->reply;
    connect(reply, &QNetworkReply::finished, this, [this, ip, reply]() { onFinished(ip, reply); });
}

void HikvisionEvents::onReadyRead(const QString &ip)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || !c->reply)
        return;
    c->failures = 0; // data is arriving, so the login worked
    c->buffer += c->reply->readAll();
    if (c->buffer.size() > kMaxBuffer)
        c->buffer = c->buffer.right(kMaxBuffer / 2);

    static const QRegularExpression eventRx(
        QStringLiteral("<EventNotificationAlert.*?</EventNotificationAlert>"),
        QRegularExpression::DotMatchesEverythingOption);
    static const QRegularExpression typeRx(QStringLiteral("<eventType>([^<]*)</eventType>"));
    static const QRegularExpression targetRx(QStringLiteral("<targetType>([^<]*)</targetType>"));

    int consumed = 0;
    const QString text = QString::fromLatin1(c->buffer);
    QRegularExpressionMatchIterator it = eventRx.globalMatch(text);
    while (it.hasNext()) {
        const QRegularExpressionMatch m = it.next();
        consumed = m.capturedEnd();
        const QString body = m.captured(0);
        const QString type = typeRx.match(body).captured(1);
        if (type != QLatin1String("VMD")) // only motion events carry a target type
            continue;
        QString target = targetRx.match(body).captured(1).trimmed().toLower();
        if (target.isEmpty()) {
            emit motionDetected(ip);
            continue;
        }
        if (target != QLatin1String("human") && target != QLatin1String("vehicle") && target != QLatin1String("animal"))
            target = QStringLiteral("other");
        qDebug() << "[Events] report from" << ip << ":" << target;
        emit targetDetected(ip, target);
    }
    if (consumed > 0)
        c->buffer.remove(0, consumed);
}

void HikvisionEvents::onFinished(const QString &ip, QNetworkReply *reply)
{
    Conn *c = m_conns.value(ip, nullptr);
    if (!c || c->reply != reply) {
        reply->deleteLater();
        return;
    }
    const QNetworkReply::NetworkError err = reply->error();
    const int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QString errText = reply->errorString();
    const bool triedLogin = reply->property("authTried").toBool();
    c->reply = nullptr;
    reply->deleteLater();
    if (err == QNetworkReply::OperationCanceledError && c->watchers <= 0)
        return;
    qDebug() << "[Events]" << ip << "stream ended: HTTP" << httpStatus << "error" << int(err) << errText
            << "loginSent" << triedLogin << "gotData" << (c->buffer.size() > 0 || c->failures == 0 ? "maybe" : "no");
    // Only a real 401 or 403 means the camera refused our password. Anything else (a dropped
    // connection, a timeout) is retried a few times, because a wrong guess could lock the camera.
    if (httpStatus == 401 || httpStatus == 403 || err == QNetworkReply::AuthenticationRequiredError) {
        c->authFailed = true;
        qWarning() << "[Events]" << ip << "refused the login (HTTP" << httpStatus << "). Not trying again.";
        emit listenFailed(ip, tr("The camera refused the login. Check its password."));
        return;
    }
    // The camera closed the stream or the network dropped; try again a few times.
    ++c->failures;
    if (c->failures >= kMaxFailures) {
        qWarning() << "[Events] Giving up on" << ip << "after" << c->failures << "failed attempts";
        emit listenFailed(ip, tr("Could not listen to this camera's detection events."));
        return;
    }
    c->retry->start();
}
