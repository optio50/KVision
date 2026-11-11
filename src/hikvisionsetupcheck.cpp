#include "hikvisionsetupcheck.h"

#include "hikvisionevents.h"

#include <QAuthenticator>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QLocale>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QTextStream>
#include <QTimer>
#include <QUrl>
#include <algorithm>

namespace {
const int kTimeoutMs = 8000; // give up on one request after this long
const int kGapMs = 300;      // wait before each request so a recorder is never hammered

QString tagValue(const QString &xml, const QString &tag)
{
    const QRegularExpression rx(QStringLiteral("<%1>([^<]*)</%1>").arg(tag));
    return rx.match(xml).captured(1).trimmed();
}

// "V5.7.23 build 260320" -> 50723. Returns 0 when there is no version in the text.
int versionNumber(const QString &text)
{
    const QRegularExpressionMatch m = QRegularExpression(QStringLiteral("V(\\d+)\\.(\\d+)\\.(\\d+)")).match(text);
    return m.hasMatch() ? m.captured(1).toInt() * 10000 + m.captured(2).toInt() * 100 + m.captured(3).toInt() : 0;
}

// An answer that means "this device does not have that setting", as opposed to "your login is wrong" (401).
bool notOffered(int code)
{
    return code == 403 || code == 404 || code == 400 || code == 501;
}
}

HikvisionSetupCheck::HikvisionSetupCheck(QObject *parent)
    : QObject(parent)
{
    m_net = new QNetworkAccessManager(this);
    connect(m_net, &QNetworkAccessManager::authenticationRequired, this,
            [](QNetworkReply *reply, QAuthenticator *auth) {
        // One attempt only: a second try with a wrong password could lock the camera.
        if (reply->property("authTried").toBool()) {
            reply->setProperty("scRefused", true); // the login was sent once and refused: remember it before aborting
            reply->abort();
            return;
        }
        reply->setProperty("authTried", true);
        auth->setUser(reply->property("scUser").toString());
        auth->setPassword(reply->property("scPass").toString());
    });
}

void HikvisionSetupCheck::add(const JobPtr &j, const QString &id, const QString &label, const QString &state, const QString &detail)
{
    QVariantMap m;
    m.insert(QStringLiteral("id"), id);
    m.insert(QStringLiteral("label"), label);
    m.insert(QStringLiteral("state"), state);
    m.insert(QStringLiteral("detail"), detail);
    j->items.append(m);
}

void HikvisionSetupCheck::get(const QString &host, int port, const QString &path, const QString &user, const QString &pass,
                              std::function<void(int, const QString &)> done)
{
    if (host.isEmpty() || user.isEmpty() || pass.isEmpty()) { // never send a login we know is incomplete
        QTimer::singleShot(0, this, [done]() { done(-1, QString()); });
        return;
    }
    if (m_refused.contains(host)) { // refused earlier this session: do not try again
        QTimer::singleShot(0, this, [done]() { done(401, QString()); });
        return;
    }
    QTimer::singleShot(kGapMs, this, [this, host, port, path, user, pass, done]() {
        QUrl url;
        url.setScheme(QStringLiteral("http"));
        url.setHost(host);
        url.setPort(port > 0 ? port : 80);
        url.setPath(path);
        QNetworkRequest req(url);
        req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("KVision"));
        QNetworkReply *reply = m_net->get(req);
        reply->setProperty("scUser", user);
        reply->setProperty("scPass", pass);
        QTimer::singleShot(kTimeoutMs, reply, [reply]() { if (reply->isRunning()) reply->abort(); });
        connect(reply, &QNetworkReply::finished, this, [this, reply, host, done]() {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QNetworkReply::NetworkError err = reply->error();
            const bool refused = reply->property("scRefused").toBool();
            const QString body = reply->isOpen() ? QString::fromUtf8(reply->readAll()) : QString();
            reply->deleteLater();
            int code = status;
            if (refused || err == QNetworkReply::AuthenticationRequiredError || status == 401)
                code = 401;
            else if (err != QNetworkReply::NoError && status == 0)
                code = 0; // no answer at all
            if (code == 401)
                m_refused.insert(host);
            done(code, body);
        });
    });
}

// ---------------------------------------------------------------------------------------------------------
// The queue
// ---------------------------------------------------------------------------------------------------------

void HikvisionSetupCheck::check(const QString &key, const QString &name, const QString &recorderIp, int httpPort,
                                const QString &user, const QString &pass, int channel, bool behindRecorder,
                                bool throughRecorder, const QString &configDir)
{
    if (m_activeKey == key)
        return;
    for (const JobPtr &q : m_queue)
        if (q->key == key)
            return;
    JobPtr j(new Job);
    j->key = key;
    j->name = name;
    j->recorderIp = recorderIp.section(QLatin1Char(':'), 0, 0).trimmed();
    j->httpPort = httpPort > 0 ? httpPort : 80;
    j->user = user;
    j->pass = pass;
    j->channel = channel;
    j->behindRecorder = behindRecorder;
    j->through = throughRecorder;
    j->configDir = configDir;
    j->camIp = behindRecorder ? QString() : j->recorderIp; // a camera's own address is the recorder address
    j->camPort = j->httpPort;
    j->camId = behindRecorder ? 1 : (channel > 0 ? channel : 1);
    m_queue.append(j);
    emit queueChanged();
    if (!m_running)
        startNext();
}

void HikvisionSetupCheck::startNext()
{
    if (m_queue.isEmpty()) {
        m_running = false;
        m_activeKey.clear();
        emit queueChanged();
        return;
    }
    m_running = true;
    JobPtr j = m_queue.takeFirst();
    m_activeKey = j->key;
    emit queueChanged();
    if (j->behindRecorder)
        stepRecorderList(j);
    else
        stepDeviceInfo(j);
}

bool HikvisionSetupCheck::isChecking(const QString &key) const
{
    if (m_activeKey == key)
        return true;
    for (const JobPtr &q : m_queue)
        if (q->key == key)
            return true;
    return false;
}

QVariantMap HikvisionSetupCheck::resultFor(const QString &key) const
{
    return m_results.value(key);
}

QVariantList HikvisionSetupCheck::results() const
{
    QList<QVariantMap> all = m_results.values();
    std::sort(all.begin(), all.end(), [](const QVariantMap &a, const QVariantMap &b) {
        return a.value(QStringLiteral("name")).toString().toLower() < b.value(QStringLiteral("name")).toString().toLower();
    });
    QVariantList out;
    for (const QVariantMap &m : all)
        out.append(m);
    return out;
}

// ---------------------------------------------------------------------------------------------------------
// The steps. Each one asks for one thing, notes what it found, and starts the next.
// ---------------------------------------------------------------------------------------------------------

// 1. For a camera behind a recorder: the recorder's list gives this camera's address, model and firmware.
void HikvisionSetupCheck::stepRecorderList(const JobPtr &j)
{
    get(j->recorderIp, j->httpPort, QStringLiteral("/ISAPI/ContentMgmt/InputProxy/channels/%1").arg(j->channel),
        j->user, j->pass, [this, j](int code, const QString &body) {
        if (code == 401) {
            add(j, QStringLiteral("login"), tr("Recorder login"), QStringLiteral("problem"),
                tr("The recorder refused the saved login. Nothing more was asked, to avoid a lock-out. Check the password."));
            finish(j);
            return;
        }
        if (code != 200) {
            add(j, QStringLiteral("recorder"), tr("Recorder"), QStringLiteral("problem"),
                code == 0 ? tr("The recorder did not answer.") : tr("The recorder could not give this camera's details (HTTP %1).").arg(code));
            finish(j);
            return;
        }
        j->camIp = tagValue(body, QStringLiteral("ipAddress"));
        j->model = tagValue(body, QStringLiteral("model"));
        j->firmware = tagValue(body, QStringLiteral("firmwareVersion"));
        j->camPort = 80;
        if (j->camIp.isEmpty()) {
            add(j, QStringLiteral("address"), tr("Camera address"), QStringLiteral("problem"),
                tr("The recorder did not say this camera's address. It may be an analogue channel or not added."));
            finish(j);
            return;
        }
        add(j, QStringLiteral("address"), tr("Camera address"), QStringLiteral("ok"), j->camIp);
        stepOnline(j);
    });
}

// 2. Is the camera online as far as the recorder can tell?
void HikvisionSetupCheck::stepOnline(const JobPtr &j)
{
    get(j->recorderIp, j->httpPort, QStringLiteral("/ISAPI/ContentMgmt/InputProxy/channels/%1/status").arg(j->channel),
        j->user, j->pass, [this, j](int code, const QString &body) {
        const QString online = tagValue(body, QStringLiteral("online"));
        if (code == 200 && online == QLatin1String("false")) {
            add(j, QStringLiteral("online"), tr("Camera online"), QStringLiteral("problem"),
                tr("The recorder reports this camera offline."));
            finish(j);
            return;
        }
        if (code == 200 && online == QLatin1String("true"))
            add(j, QStringLiteral("online"), tr("Camera online"), QStringLiteral("ok"), QString());
        else
            add(j, QStringLiteral("online"), tr("Camera online"), QStringLiteral("unknown"), tr("The recorder did not say."));
        stepDeviceInfo(j);
    });
}

// 3. Model and firmware. A 2347 on firmware older than V5.7.23 sends plain motion only.
void HikvisionSetupCheck::stepDeviceInfo(const JobPtr &j)
{
    get(j->camIp, j->camPort, QStringLiteral("/ISAPI/System/deviceInfo"), j->user, j->pass,
        [this, j](int code, const QString &body) {
        if (code == 401) {
            add(j, QStringLiteral("login"), tr("Camera login"), QStringLiteral("problem"),
                tr("The camera refused the saved login. Nothing more was asked, to avoid a lock-out. The recorder's login may not be the camera's."));
            finish(j);
            return;
        }
        if (code != 200) {
            add(j, QStringLiteral("reach"), tr("Camera reachable"), QStringLiteral("problem"),
                code == 0 ? tr("The camera did not answer from this computer.") : tr("The camera answered with HTTP %1.").arg(code));
            finish(j);
            return;
        }
        add(j, QStringLiteral("reach"), tr("Camera reachable"), QStringLiteral("ok"), QString());
        const QString model = tagValue(body, QStringLiteral("model"));
        const QString fw = tagValue(body, QStringLiteral("firmwareVersion"));
        if (!model.isEmpty())
            j->model = model;
        if (!fw.isEmpty())
            j->firmware = fw;
        const int v = versionNumber(j->firmware);
        if (v == 0)
            add(j, QStringLiteral("firmware"), tr("Firmware"), QStringLiteral("unknown"), j->firmware);
        else if (j->model.contains(QStringLiteral("2347G2")) && v < 50723)
            add(j, QStringLiteral("firmware"), tr("Firmware"), QStringLiteral("problem"),
                tr("%1 is older than V5.7.23, which this camera needs to say human or vehicle. Older firmware sends plain motion only.").arg(j->firmware));
        else
            add(j, QStringLiteral("firmware"), tr("Firmware"), QStringLiteral("ok"), j->firmware);
        stepMetadata(j);
    });
}

// 4. The smart-event metadata switch. A recorder only passes smart events on when it is on.
void HikvisionSetupCheck::stepMetadata(const JobPtr &j)
{
    get(j->camIp, j->camPort, QStringLiteral("/ISAPI/Streaming/channels/%1/metadata").arg(j->camId * 100 + 1), j->user, j->pass,
        [this, j](int code, const QString &body) {
        static const QRegularExpression rx(QStringLiteral("<type>behaviorAnalysis</type>\\s*<enable>(\\w+)</enable>"));
        const QRegularExpressionMatch m = rx.match(body);
        if (code == 200 && m.hasMatch()) {
            if (m.captured(1) == QLatin1String("true"))
                add(j, QStringLiteral("metadata"), tr("Smart-event metadata"), QStringLiteral("ok"), QString());
            else
                add(j, QStringLiteral("metadata"), tr("Smart-event metadata"), j->through ? QStringLiteral("problem") : QStringLiteral("note"),
                    j->through ? tr("Switched off in the camera (Configuration, General Settings, Metadata, Smart Event). The recorder passes no smart events on without it.")
                               : tr("Switched off in the camera. Not needed when each camera reports on its own, but a recorder needs it."));
        } else {
            add(j, QStringLiteral("metadata"), tr("Smart-event metadata"), QStringLiteral("unknown"),
                notOffered(code) ? tr("This camera has no such setting.") : tr("Could not read it."));
        }
        stepMotion(j);
    });
}

// 5. Motion detection: switched on, and a zone drawn. The camera keeps the zone as a grid of squares (a hex map on
// the motionDetection page): any square set counts. A camera without a grid keeps corner points instead, and a region
// whose points are all zero is not a zone.
void HikvisionSetupCheck::stepMotion(const JobPtr &j)
{
    get(j->camIp, j->camPort, QStringLiteral("/ISAPI/System/Video/inputs/channels/%1/motionDetection").arg(j->camId),
        j->user, j->pass, [this, j](int code, const QString &body) {
        if (code != 200) {
            add(j, QStringLiteral("motion"), tr("Motion detection"), QStringLiteral("unknown"),
                notOffered(code) ? tr("This camera has no such setting.") : tr("Could not read it."));
            stepSmart(j, 0);
            return;
        }
        const bool on = tagValue(body, QStringLiteral("enabled")) == QLatin1String("true");
        bool zone = false;
        const QString grid = tagValue(body, QStringLiteral("gridMap"));
        for (const QChar ch : grid) {
            if (ch != QLatin1Char('0') && ch.isLetterOrNumber()) { zone = true; break; }
        }
        if (grid.isEmpty()) {
            const QRegularExpression ptRx(QStringLiteral("<positionX>(\\d+)</positionX>\\s*<positionY>(\\d+)</positionY>"));
            auto p = ptRx.globalMatch(body);
            while (p.hasNext() && !zone) {
                const auto m = p.next();
                if (m.captured(1) != QLatin1String("0") || m.captured(2) != QLatin1String("0"))
                    zone = true;
            }
        }
        j->motionSet = on && zone;
        if (!on)
            add(j, QStringLiteral("motion"), tr("Motion detection"), QStringLiteral("problem"),
                tr("Switched off. Without it the camera sends no motion reports."));
        else if (!zone)
            add(j, QStringLiteral("motion"), tr("Motion detection"), QStringLiteral("problem"),
                tr("Switched on but no zone is drawn, so the camera never reports motion. Draw an area in the camera's Motion Detection page and save."));
        else
            add(j, QStringLiteral("motion"), tr("Motion detection"), QStringLiteral("ok"), tr("on, with a zone"));
        stepSmart(j, 0);
    });
}

// 6. The smart rules, one kind at a time: switched on, and a line or area drawn.
static const char *const kSmartPath[] = {"LineDetection", "FieldDetection", "RegionEntrance", "RegionExiting"};
static const char *const kSmartEvent[] = {"linedetection", "fielddetection", "regionEntrance", "regionExiting"};
static const char *const kSmartItem[] = {"LineItem", "FieldDetectionRegion", "RegionEntranceRegion", "RegionExitingRegion"};
static const char *const kSmartLabel[] = {"Line crossing", "Intrusion", "Region entrance", "Region exit"};

void HikvisionSetupCheck::stepSmart(const JobPtr &j, int index)
{
    if (index >= 4) {
        if (j->smartSet.isEmpty() && !j->motionSet)
            add(j, QStringLiteral("rules"), tr("Anything to report"), QStringLiteral("problem"),
                tr("No motion zone and no line or area is drawn, so this camera has nothing to report."));
        // The centre action matters only when the settings send reports through the recorder.
        if (j->behindRecorder && j->through) {
            QStringList events;
            if (j->motionSet)
                events << QStringLiteral("VMD");
            for (const QString &e : j->smartSet)
                events << e;
            if (events.isEmpty())
                events << QStringLiteral("VMD") << QStringLiteral("linedetection") << QStringLiteral("fielddetection");
            for (const QString &e : events)
                j->trig.append({j->recorderIp, QString::number(j->httpPort),
                                QStringLiteral("/ISAPI/Event/triggers/%1-%2").arg(e).arg(j->channel), e});
            stepTriggers(j, 0);
        } else {
            finish(j);
        }
        return;
    }
    const QString path = QStringLiteral("/ISAPI/Smart/%1/%2").arg(QLatin1String(kSmartPath[index])).arg(j->camId);
    get(j->camIp, j->camPort, path, j->user, j->pass, [this, j, index](int code, const QString &body) {
        const QString label = tr(kSmartLabel[index]);
        if (code != 200) {
            if (!notOffered(code))
                add(j, QStringLiteral("smart%1").arg(index), label, QStringLiteral("unknown"), tr("Could not read it."));
            stepSmart(j, index + 1); // a camera without this kind is fine: say nothing
            return;
        }
        const bool overall = tagValue(body, QStringLiteral("enabled")) == QLatin1String("true");
        bool drawn = false;
        const QRegularExpression itemRx(QStringLiteral("<%1[ >].*?</%1>").arg(QLatin1String(kSmartItem[index])),
                                        QRegularExpression::DotMatchesEverythingOption);
        const QRegularExpression ptRx(QStringLiteral("<positionX>(\\d+)</positionX>\\s*<positionY>(\\d+)</positionY>"));
        auto it = itemRx.globalMatch(body);
        while (it.hasNext() && !drawn) {
            auto p = ptRx.globalMatch(it.next().captured(0));
            while (p.hasNext()) {
                const auto m = p.next();
                if (m.captured(1) != QLatin1String("0") || m.captured(2) != QLatin1String("0")) { drawn = true; break; }
            }
        }
        if (drawn)
            j->smartSet << QLatin1String(kSmartEvent[index]);
        const QString id = QStringLiteral("smart%1").arg(index);
        if (!drawn && !overall) {
            stepSmart(j, index + 1); // nothing set up for this kind: not a problem, nothing to say
            return;
        }
        if (drawn && overall)
            add(j, id, label, QStringLiteral("ok"), tr("on, with a line or area"));
        else if (drawn)
            add(j, id, label, QStringLiteral("problem"), tr("A line or area is drawn but the feature is switched off. Switch it on and save."));
        else
            add(j, id, label, QStringLiteral("problem"), tr("Switched on but no line or area is drawn, so it never fires."));
        stepSmart(j, index + 1);
    });
}

// 7. The recorder's centre action for each event this camera reports. Without it a recorder sends nothing on.
void HikvisionSetupCheck::stepTriggers(const JobPtr &j, int index)
{
    if (index >= j->trig.size()) {
        if (j->recMissing.isEmpty() && !j->recOk.isEmpty())
            add(j, QStringLiteral("center"), tr("Recorder centre action"), QStringLiteral("ok"), j->recOk.join(QStringLiteral(", ")));
        else if (!j->recMissing.isEmpty())
            add(j, QStringLiteral("center"), tr("Recorder centre action"), QStringLiteral("problem"),
                tr("Not switched on for: %1. In the recorder's event settings tick \"Notify Surveillance Center\" for this camera.")
                    .arg(j->recMissing.join(QStringLiteral(", "))));
        finish(j);
        return;
    }
    const QStringList t = j->trig.at(index);
    get(t.at(0), t.at(1).toInt(), t.at(2), j->user, j->pass, [this, j, index, t](int code, const QString &body) {
        if (code == 200) {
            if (body.contains(QStringLiteral("<notificationMethod>center</notificationMethod>")))
                j->recOk << t.at(3);
            else
                j->recMissing << t.at(3);
        } else if (code == 401) {
            add(j, QStringLiteral("login"), tr("Recorder login"), QStringLiteral("problem"),
                tr("The recorder refused the saved login part way through. Nothing more was asked."));
            finish(j);
            return;
        }
        stepTriggers(j, index + 1);
    });
}

// ---------------------------------------------------------------------------------------------------------
// The result
// ---------------------------------------------------------------------------------------------------------

void HikvisionSetupCheck::finish(const JobPtr &j)
{
    // The pictures sent with line and area events: with the camera's "overlay rule frame and target frame" switch
    // off they are clean photos, which show less when an alarm is looked at later.
    if (m_events && !j->smartSet.isEmpty() && !j->camIp.isEmpty()) {
        const QString label = tr("Event pictures");
        const QVariantMap pf = m_events->pictureFrames(j->camIp);
        const QString state = pf.value(QStringLiteral("state")).toString();
        if (state == QLatin1String("on"))
            add(j, QStringLiteral("pictures"), label, QStringLiteral("ok"), tr("show the rule and target frames (seen at %1)").arg(pf.value(QStringLiteral("time")).toString()));
        else if (state == QLatin1String("off"))
            add(j, QStringLiteral("pictures"), label, QStringLiteral("note"),
                tr("The last picture (%1) was a clean photo with no frame on the target. On the camera's page, under Configuration > Event > Smart Event > Metadata (or the rule's settings), tick \"Overlay Rule Frame and Target Frame on Background Picture\".").arg(pf.value(QStringLiteral("time")).toString()));
        else
            add(j, QStringLiteral("pictures"), label, QStringLiteral("note"),
                tr("Not known yet. It is learned from the next line or area event KVision receives from this camera, then check again."));
    }
    int problems = 0;
    for (const QVariant &v : j->items)
        if (v.toMap().value(QStringLiteral("state")).toString() == QLatin1String("problem"))
            ++problems;
    QVariantMap r;
    r.insert(QStringLiteral("key"), j->key);
    r.insert(QStringLiteral("name"), j->name);
    r.insert(QStringLiteral("time"), QLocale::c().toString(QDateTime::currentDateTime(), QStringLiteral("dd MMM yyyy HH:mm:ss")));
    r.insert(QStringLiteral("model"), j->model);
    r.insert(QStringLiteral("firmware"), j->firmware);
    r.insert(QStringLiteral("problems"), problems);
    r.insert(QStringLiteral("summary"), problems == 0 ? tr("Set up for detection") : tr("%n thing(s) to fix", nullptr, problems));
    r.insert(QStringLiteral("items"), j->items);
    m_results.insert(j->key, r);

    // A plain-text copy next to the detection log, so a check can be read later or sent to someone.
    if (!j->configDir.isEmpty()) {
        const QString dir = j->configDir + QStringLiteral("/logs");
        QDir().mkpath(dir);
        QFile f(dir + QStringLiteral("/SetupCheck.log"));
        if (f.open(QIODevice::Append | QIODevice::Text)) {
            QTextStream out(&f);
            out << r.value(QStringLiteral("time")).toString() << ", " << j->name << ", " << r.value(QStringLiteral("summary")).toString() << "\n";
            for (const QVariant &v : j->items) {
                const QVariantMap m = v.toMap();
                if (m.value(QStringLiteral("state")).toString() != QLatin1String("ok"))
                    out << "    " << m.value(QStringLiteral("state")).toString() << ": " << m.value(QStringLiteral("label")).toString()
                        << (m.value(QStringLiteral("detail")).toString().isEmpty() ? QString() : QStringLiteral(" - ") + m.value(QStringLiteral("detail")).toString()) << "\n";
            }
        }
    }
    qDebug() << "[SetupCheck]" << j->name << "->" << problems << "problem(s)";
    emit resultReady(j->key);
    startNext();
}
