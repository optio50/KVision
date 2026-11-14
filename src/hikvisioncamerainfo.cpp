#include "hikvisioncamerainfo.h"

#include "hikvisionmanager.h"

#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>
#include <QMetaObject>
#include <QProcess>
#include <QRegularExpression>
#include <QSettings>
#include <QThread>

namespace {
const char *kLoginGroup = "CameraLogins"; // the same per-camera logins the backup tool keeps

QString hostOf(const QString &address)
{
    return address.section(QLatin1Char(':'), 0, 0).trimmed();
}

// A camera on its own is its own "recorder" in the saved list; only a camera behind a recorder has recorder rules.
bool recIsSelf(const QString &camIp, const QString &recIp)
{
    return camIp == recIp;
}

// GET one ISAPI path with curl. Returns the HTTP status (0 = no connection) and puts the body in *body. A login is
// sent once; there is no retry here.
int curlGet(const QString &ip, int port, const QString &user, const QString &pass, const QString &path, QByteArray *body)
{
    QProcess p;
    p.start(QStringLiteral("curl"), {QStringLiteral("-s"), QStringLiteral("-k"), QStringLiteral("--anyauth"), QStringLiteral("-u"),
                                     QStringLiteral("%1:%2").arg(user, pass), QStringLiteral("--max-time"), QStringLiteral("7"),
                                     QStringLiteral("-w"), QStringLiteral("%{http_code}"),
                                     QStringLiteral("http://%1:%2%3").arg(ip).arg(port).arg(path)});
    if (!p.waitForFinished(12000)) {
        p.kill();
        return 0;
    }
    const QByteArray out = p.readAllStandardOutput();
    if (body)
        *body = out.left(qMax(0, int(out.size()) - 3));
    return out.right(3).toInt();
}

// True when the answer is a real document and not an error message (a camera answers an unsupported path with a short
// ResponseStatus or a JSON status, or an HTML "Not Found" page).
bool usable(int code, const QByteArray &b)
{
    if (code != 200 || b.size() < 40)
        return false;
    if (b.contains("<ResponseStatus") && !b.contains("<statusCode>1<"))
        return false;
    if (b.contains("\"statusCode\"") && b.contains("\"subStatusCode\""))
        return false;
    return !b.contains("Document Error");
}

QString tag(const QString &xml, const QString &name)
{
    const QRegularExpression rx(QStringLiteral("<%1>([^<]*)</%1>").arg(name));
    return rx.match(xml).captured(1).trimmed();
}

QStringList tags(const QString &xml, const QString &name)
{
    QStringList out;
    const QRegularExpression rx(QStringLiteral("<%1>([^<]*)</%1>").arg(name));
    auto it = rx.globalMatch(xml);
    while (it.hasNext())
        out << it.next().captured(1).trimmed();
    return out;
}

QVariantMap row(const QString &label, const QString &value)
{
    return QVariantMap{{QStringLiteral("label"), label}, {QStringLiteral("value"), value}};
}

QVariantMap section(const QString &title, const QVariantList &rows)
{
    return QVariantMap{{QStringLiteral("title"), title}, {QStringLiteral("rows"), rows}};
}

QString onOff(const QString &v)
{
    return v.compare(QLatin1String("true"), Qt::CaseInsensitive) == 0 ? QStringLiteral("on")
         : (v.compare(QLatin1String("false"), Qt::CaseInsensitive) == 0 ? QStringLiteral("off") : v);
}

QString uptimeText(qint64 secs)
{
    const qint64 d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60;
    return d > 0 ? QStringLiteral("%1 d %2 h %3 min").arg(d).arg(h).arg(m) : QStringLiteral("%1 h %2 min").arg(h).arg(m);
}

// "05:45" -> minutes since midnight; "24:00" -> 1440
int minutesOf(const QString &hhmm)
{
    const QStringList p = hhmm.split(QLatin1Char(':'));
    return p.size() >= 2 ? p[0].toInt() * 60 + p[1].toInt() : 0;
}

// One week of armed time from a JSON TimeRangeList ([{week, TimeRange:[{beginTime,endTime}]}]) as 7 lists of {from,to}
// in minutes. Day 1 is Monday.
QVariantList weekFromJson(const QJsonArray &list)
{
    QVariantList days;
    for (int d = 0; d < 7; ++d)
        days.append(QVariant(QVariantList())); // wrapped: append(QVariantList) would add its elements, i.e. nothing
    for (const QJsonValue &wv : list) {
        const QJsonObject w = wv.toObject();
        const int idx = w.value(QStringLiteral("week")).toInt() - 1;
        if (idx < 0 || idx > 6)
            continue;
        QVariantList ranges;
        for (const QJsonValue &rv : w.value(QStringLiteral("TimeRange")).toArray()) {
            const QJsonObject r = rv.toObject();
            ranges.append(QVariantMap{{QStringLiteral("from"), minutesOf(r.value(QStringLiteral("beginTime")).toString())},
                                      {QStringLiteral("to"), minutesOf(r.value(QStringLiteral("endTime")).toString())}});
        }
        days[idx] = QVariant(ranges);
    }
    return days;
}

// "00:00-05:45, 21:00-24:00" for one day; "all day" / "never"
QString rangesText(const QVariantList &ranges)
{
    if (ranges.isEmpty())
        return QStringLiteral("never");
    QStringList parts;
    auto hhmm = [](int m) { return QStringLiteral("%1:%2").arg(m / 60, 2, 10, QLatin1Char('0')).arg(m % 60, 2, 10, QLatin1Char('0')); };
    for (const QVariant &v : ranges) {
        const QVariantMap r = v.toMap();
        if (r.value(QStringLiteral("from")).toInt() == 0 && r.value(QStringLiteral("to")).toInt() >= 1440)
            return QStringLiteral("all day");
        parts << hhmm(r.value(QStringLiteral("from")).toInt()) + QLatin1Char('-') + hhmm(r.value(QStringLiteral("to")).toInt());
    }
    return parts.join(QStringLiteral(", "));
}

// One short sentence for a week: the same hours every day, or the days that differ.
QString weekText(const QVariantList &days)
{
    QStringList per;
    for (const QVariant &d : days)
        per << rangesText(d.toList());
    bool same = true;
    for (int i = 1; i < per.size(); ++i)
        same = same && per[i] == per[0];
    if (same)
        return per.value(0) + QStringLiteral(", every day");
    static const char *names[] = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"};
    QStringList out;
    for (int i = 0; i < per.size() && i < 7; ++i)
        out << QStringLiteral("%1 %2").arg(QLatin1String(names[i]), per[i]);
    return out.join(QStringLiteral("; "));
}
}

HikvisionCameraInfo::HikvisionCameraInfo(QObject *parent) : QObject(parent) {}

HikvisionCameraInfo::~HikvisionCameraInfo()
{
    for (QThread *t : {m_worker, m_loader}) {
        if (t) {
            t->disconnect(this);
            t->wait();
        }
    }
}

void HikvisionCameraInfo::loadCameras(const QString &recordersJson, const QString &configPath)
{
    m_configPath = configPath;
    const QByteArray json = recordersJson.toUtf8();
    if (m_loader && m_loader->isRunning()) {
        m_hasPending = true; // run again once the current lookup is done, so the newest list wins
        m_pendingJson = json;
        m_pendingPath = configPath;
        return;
    }
    startLoad(json, configPath);
}

void HikvisionCameraInfo::startLoad(const QByteArray &json, const QString &configPath)
{
    if (m_loader) {
        m_loader->wait();
        m_loader->deleteLater();
    }
    m_loader = QThread::create([this, json, configPath]() {
        QSettings saved(configPath, QSettings::IniFormat);
        saved.beginGroup(QLatin1String(kLoginGroup));
        QMap<QString, Cam> byIp;
        const QJsonArray list = QJsonDocument::fromJson(json).array();
        for (const QJsonValue &rv : list) {
            const QJsonObject rec = rv.toObject();
            const QString recIp = hostOf(rec.value(QStringLiteral("ip")).toString());
            const QString recUser = rec.value(QStringLiteral("username")).toString();
            const QString recPass = rec.value(QStringLiteral("password")).toString();
            int http = rec.value(QStringLiteral("httpPort")).toVariant().toInt();
            if (http <= 0)
                http = 80;
            QString recName = rec.value(QStringLiteral("name")).toString();
            if (recName.isEmpty())
                recName = recIp;
            const QJsonArray cams = rec.value(QStringLiteral("cameras")).toArray();
            if (recIp.isEmpty())
                continue;
            QMap<int, QString> allNames; // every channel of this recorder -> its camera's name
            for (const QJsonValue &cv : cams) {
                const QJsonObject cam = cv.toObject();
                const int ch = cam.value(QStringLiteral("channelId")).toVariant().toInt();
                QString nm = cam.value(QStringLiteral("customName")).toString();
                if (nm.isEmpty())
                    nm = cam.value(QStringLiteral("name")).toString();
                allNames.insert(ch, nm.isEmpty() ? QStringLiteral("Camera %1").arg(ch) : nm);
            }
            auto add = [&](const QString &ip, int port, const QString &name, int channel) {
                if (ip.isEmpty())
                    return;
                if (byIp.contains(ip)) { // a camera with two lenses sits on two recorder channels
                    if (channel > 0 && !recIsSelf(ip, recIp)) {
                        byIp[ip].channels << channel;
                        byIp[ip].chanNames.insert(channel, name);
                    }
                    return;
                }
                Cam c;
                if (!recIsSelf(ip, recIp)) {
                    c.recIp = recIp;
                    c.recPort = http;
                    c.recUser = recUser;
                    c.recPass = recPass;
                    c.recChanNames = allNames;
                    if (channel > 0) {
                        c.channels << channel;
                        c.chanNames.insert(channel, name);
                    }
                }
                c.name = name;
                c.ip = ip;
                c.httpPort = port;
                c.user = recUser;
                c.pass = recPass;
                // A login kept for this one camera (by the backup tool) wins over the recorder's.
                const QJsonObject own = QJsonDocument::fromJson(saved.value(ip).toString().toUtf8()).object();
                if (!own.value(QStringLiteral("user")).toString().isEmpty() && !own.value(QStringLiteral("pass")).toString().isEmpty()) {
                    c.user = own.value(QStringLiteral("user")).toString();
                    c.pass = own.value(QStringLiteral("pass")).toString();
                }
                byIp.insert(ip, c);
            };
            if (cams.size() <= 2) {
                add(recIp, http, recName, 0);
                continue;
            }
            const QHash<int, QVariantMap> proxy = HikvisionManager::fetchProxyChannels(recIp, http, recUser, recPass);
            for (const QJsonValue &cv : cams) {
                const QJsonObject cam = cv.toObject();
                const int ch = cam.value(QStringLiteral("channelId")).toVariant().toInt();
                QString nm = cam.value(QStringLiteral("customName")).toString();
                if (nm.isEmpty())
                    nm = cam.value(QStringLiteral("name")).toString();
                if (nm.isEmpty())
                    nm = QStringLiteral("Camera %1").arg(ch);
                add(proxy.value(ch).value(QStringLiteral("ip")).toString(), 80, QStringLiteral("%1 Ch.%2 %3").arg(recName).arg(ch).arg(nm), ch);
            }
        }
        const QList<Cam> found = byIp.values();
        QVariantList out;
        for (const Cam &c : found)
            out.append(QVariantMap{{QStringLiteral("name"), c.name}, {QStringLiteral("ip"), c.ip}, {QStringLiteral("user"), c.user}});
        QMetaObject::invokeMethod(this, [this, found, out]() {
            m_cams = found;
            emit camerasLoaded(out);
        }, Qt::QueuedConnection);
    });
    connect(m_loader, &QThread::finished, this, [this]() {
        if (!m_hasPending)
            return;
        m_hasPending = false;
        startLoad(m_pendingJson, m_pendingPath);
    });
    m_loader->start();
}

namespace {
using Cam = HikvisionCameraInfo::Cam;

bool fetchDoc(const Cam &cam, const QString &path, QByteArray *b, QString *why)
{
    const int code = curlGet(cam.ip, cam.httpPort, cam.user, cam.pass, path, b);
    if (code == 401 && why && why->isEmpty())
        *why = QStringLiteral("login refused: this camera needs its own username and password (set it in Camera backup)");
    if (code == 0 && why && why->isEmpty())
        *why = QStringLiteral("cannot reach the camera");
    return usable(code, *b);
}

// Device, time and network.
void deviceSections(const Cam &cam, QVariantList &out, QString *why)
{
    QByteArray b;
    if (!fetchDoc(cam, QStringLiteral("/ISAPI/System/deviceInfo"), &b, why))
        return;
    const QString dev = QString::fromUtf8(b);
    QVariantList rows;
    rows << row(QStringLiteral("Name"), tag(dev, QStringLiteral("deviceName")))
         << row(QStringLiteral("Model"), tag(dev, QStringLiteral("model")))
         << row(QStringLiteral("Serial number"), tag(dev, QStringLiteral("serialNumber")))
         << row(QStringLiteral("Firmware"), tag(dev, QStringLiteral("firmwareVersion")) + QLatin1Char(' ') + tag(dev, QStringLiteral("firmwareReleasedDate")))
         << row(QStringLiteral("MAC address"), tag(dev, QStringLiteral("macAddress")));
    if (fetchDoc(cam, QStringLiteral("/ISAPI/System/status"), &b, nullptr)) {
        const QString st = QString::fromUtf8(b);
        rows << row(QStringLiteral("Uptime"), uptimeText(tag(st, QStringLiteral("deviceUpTime")).toLongLong()))
             << row(QStringLiteral("CPU load"), tag(st, QStringLiteral("cpuUtilization")) + QStringLiteral(" %"))
             << row(QStringLiteral("Memory used"), tag(st, QStringLiteral("memoryUsage")) + QStringLiteral(" %"));
    }
    out << section(QStringLiteral("Device"), rows);

    rows.clear();
    if (fetchDoc(cam, QStringLiteral("/ISAPI/System/time"), &b, nullptr)) {
        const QString t = QString::fromUtf8(b);
        rows << row(QStringLiteral("Time mode"), tag(t, QStringLiteral("timeMode")))
             << row(QStringLiteral("Camera time"), tag(t, QStringLiteral("localTime")))
             << row(QStringLiteral("Time zone"), tag(t, QStringLiteral("timeZone")));
    }
    if (fetchDoc(cam, QStringLiteral("/ISAPI/System/time/ntpServers"), &b, nullptr)) {
        const QString x = QString::fromUtf8(b);
        const QStringList s = tags(x, QStringLiteral("ipAddress")) + tags(x, QStringLiteral("hostName"));
        if (!s.isEmpty())
            rows << row(QStringLiteral("NTP server"), s.join(QStringLiteral(", ")));
    }
    if (fetchDoc(cam, QStringLiteral("/ISAPI/System/Network/interfaces/1/ipAddress"), &b, nullptr)) {
        const QString n = QString::fromUtf8(b);
        const QStringList addrs = tags(n, QStringLiteral("ipAddress"));
        rows << row(QStringLiteral("Address mode"), tag(n, QStringLiteral("addressingType")))
             << row(QStringLiteral("IP address"), addrs.value(0))
             << row(QStringLiteral("Subnet mask"), tag(n, QStringLiteral("subnetMask")))
             << row(QStringLiteral("Gateway"), addrs.value(1))
             << row(QStringLiteral("DNS"), addrs.mid(2).join(QStringLiteral(", ")));
    }
    if (!rows.isEmpty())
        out << section(QStringLiteral("Time and network"), rows);
}
}

namespace {
// The "Image Parameters Switch": whether the camera changes its picture scene on a schedule, and which scene applies now.
void imageSwitchRows(const Cam &cam, QVariantList &rows)
{
    QByteArray b;
    if (!fetchDoc(cam, QStringLiteral("/ISAPI/Image/channels/1/displayParamSwitch"), &b, nullptr))
        return;
    const QString x = QString::fromUtf8(b);
    const QString mode = tag(x, QStringLiteral("mode"));
    const QString label = QStringLiteral("Image parameters switch");
    static const QHash<QString, QString> scenes = {
        {QStringLiteral("normal"), QStringLiteral("Basic")}, {QStringLiteral("backlight"), QStringLiteral("Back light")},
        {QStringLiteral("frontlight"), QStringLiteral("Front light")}, {QStringLiteral("lowIllumination"), QStringLiteral("Low Illumination")},
        {QStringLiteral("custom1"), QStringLiteral("Custom1")}, {QStringLiteral("custom2"), QStringLiteral("Custom2")}};
    static const QRegularExpression perRx(QStringLiteral("<Period>([\\s\\S]*?)</Period>"));
    static const QRegularExpression rngRx(QStringLiteral("<TimeRange>([\\s\\S]*?)</TimeRange>"));

    if (mode == QLatin1String("timingSwitch")) { // a PTZ: one schedule per preset
        int used = 0;
        auto it = perRx.globalMatch(x);
        while (it.hasNext()) {
            if (tag(it.next().captured(1), QStringLiteral("enabled")) == QLatin1String("true"))
                ++used;
        }
        rows << row(label, used > 0 ? QStringLiteral("Timing switch, %1 period(s) in use").arg(used)
                                    : QStringLiteral("Timing switch, no period in use"));
        return;
    }
    if (mode == QLatin1String("disable")) {
        rows << row(label, x.contains(QLatin1String("<linkScene>")) ? QStringLiteral("Not Switch (a schedule is stored but not used)")
                                                                      : QStringLiteral("Not Switch"));
        return;
    }
    if (mode != QLatin1String("month")) {
        rows << row(label, mode);
        return;
    }

    // Scheduled-Switch: one period per month, each a list of time ranges with a scene. "Now" is the camera's own clock.
    rows << row(label, QStringLiteral("Scheduled-Switch"));
    int month = 0, nowMin = -1;
    if (fetchDoc(cam, QStringLiteral("/ISAPI/System/time"), &b, nullptr)) {
        const QString t = tag(QString::fromUtf8(b), QStringLiteral("localTime")); // 2026-11-12T19:01:31-09:00
        month = t.mid(5, 2).toInt();
        nowMin = minutesOf(t.mid(11, 5));
    }
    auto pit = perRx.globalMatch(x);
    while (pit.hasNext()) {
        const QString block = pit.next().captured(1);
        if (tag(block, QStringLiteral("id")).toInt() != month)
            continue;
        QStringList spans;
        QString now;
        auto rit = rngRx.globalMatch(block);
        while (rit.hasNext()) {
            const QString r = rit.next().captured(1);
            const int from = minutesOf(tag(r, QStringLiteral("beginTime"))), to = minutesOf(tag(r, QStringLiteral("endTime")));
            const QString scene = scenes.value(tag(r, QStringLiteral("linkScene")), tag(r, QStringLiteral("linkScene")));
            spans << QStringLiteral("%1-%2 %3").arg(tag(r, QStringLiteral("beginTime")).left(5), tag(r, QStringLiteral("endTime")).left(5), scene);
            if (nowMin >= from && nowMin < to)
                now = scene;
        }
        rows << row(QStringLiteral("Scene now"), now.isEmpty() ? QStringLiteral("none set for this time") : now)
             << row(QStringLiteral("Scene schedule this month"), spans.isEmpty() ? QStringLiteral("none") : spans.join(QStringLiteral(", ")));
        break;
    }
}

// Video streams, overlays and the picture settings.
void videoSections(const Cam &cam, QVariantList &out)
{
    QByteArray b;
    QVariantList rows;
    // Ask which streams the camera has: it answers a request for one it does not have (103) with a copy of the main stream.
    QStringList ids;
    if (fetchDoc(cam, QStringLiteral("/ISAPI/Streaming/channels"), &b, nullptr)) {
        const QString list = QString::fromUtf8(b);
        static const QRegularExpression chRx(QStringLiteral("<StreamingChannel[^>]*>\\s*<id>(\\d+)</id>"));
        auto it = chRx.globalMatch(list);
        while (it.hasNext())
            ids << it.next().captured(1);
    }
    if (ids.isEmpty())
        ids << QStringLiteral("101") << QStringLiteral("102"); // an old camera that will not list them
    for (const QString &id : ids) {
        if (id.size() != 3 || !id.startsWith(QLatin1Char('1')))
            continue; // the first camera's streams only (101, 102, ...)
        if (!fetchDoc(cam, QStringLiteral("/ISAPI/Streaming/channels/") + id, &b, nullptr))
            continue;
        const QString s = QString::fromUtf8(b);
        if (tag(s, QStringLiteral("videoCodecType")).isEmpty())
            continue;
        const double fps = tag(s, QStringLiteral("maxFrameRate")).toDouble() / 100.0;
        const QString mode = tag(s, QStringLiteral("videoQualityControlType"));
        const QString rate = mode == QLatin1String("CBR") ? tag(s, QStringLiteral("constantBitRate")) : tag(s, QStringLiteral("vbrUpperCap"));
        const QString label = id == QLatin1String("101") ? QStringLiteral("Main stream")
                            : (id == QLatin1String("102") ? QStringLiteral("Sub stream") : QStringLiteral("Third stream"));
        rows << row(label, QStringLiteral("%1, %2x%3, %4 fps, %5 %6 kbps")
                               .arg(tag(s, QStringLiteral("videoCodecType")), tag(s, QStringLiteral("videoResolutionWidth")),
                                    tag(s, QStringLiteral("videoResolutionHeight")))
                               .arg(fps, 0, 'g', 4).arg(mode, rate));
        const int a = s.indexOf(QLatin1String("<Audio>"));
        if (id == QLatin1String("101"))
            rows << row(QStringLiteral("Audio"), a < 0 ? QStringLiteral("none")
                        : QStringLiteral("%1, %2").arg(onOff(tag(s.mid(a), QStringLiteral("enabled"))), tag(s, QStringLiteral("audioCompressionType"))));
    }
    if (fetchDoc(cam, QStringLiteral("/ISAPI/System/Video/inputs/channels/1/overlays"), &b, nullptr)) {
        const QString o = QString::fromUtf8(b);
        const int dt = o.indexOf(QLatin1String("<DateTimeOverlay>")), cn = o.indexOf(QLatin1String("<channelNameOverlay>"));
        rows << row(QStringLiteral("Date and time overlay"), dt >= 0 ? onOff(tag(o.mid(dt), QStringLiteral("enabled"))) : QStringLiteral("-"))
             << row(QStringLiteral("Name overlay"), cn >= 0 ? onOff(tag(o.mid(cn), QStringLiteral("enabled"))) : QStringLiteral("-"));
    }
    if (!rows.isEmpty())
        out << section(QStringLiteral("Video"), rows);

    rows.clear();
    // The picture values live in their own "Color" document. The whole image document also has a brightnessLevel inside
    // the supplement light's block, which is a different thing, so the first tag of that name must not be used.
    const bool haveColor = fetchDoc(cam, QStringLiteral("/ISAPI/Image/channels/1/color"), &b, nullptr);
    const QString color = haveColor ? QString::fromUtf8(b) : QString();
    const bool haveImage = fetchDoc(cam, QStringLiteral("/ISAPI/Image/channels/1"), &b, nullptr);
    const QString im = haveImage ? QString::fromUtf8(b) : QString();
    if (haveColor || haveImage) {
        auto pick = [&](const QString &label, const QString &name, const QString &from) {
            const QString v = tag(from, name);
            if (!v.isEmpty())
                rows << row(label, v);
        };
        const QString &pic = haveColor ? color : im;
        pick(QStringLiteral("Brightness"), QStringLiteral("brightnessLevel"), pic);
        pick(QStringLiteral("Contrast"), QStringLiteral("contrastLevel"), pic);
        pick(QStringLiteral("Saturation"), QStringLiteral("saturationLevel"), pic);
        pick(QStringLiteral("Sharpness"), QStringLiteral("SharpnessLevel"), im);
        pick(QStringLiteral("Day/night filter"), QStringLiteral("IrcutFilterType"), im);
        pick(QStringLiteral("White balance"), QStringLiteral("WhiteBalanceStyle"), im);
        pick(QStringLiteral("Mains frequency"), QStringLiteral("powerLineFrequencyMode"), im);
        imageSwitchRows(cam, rows);
        if (!rows.isEmpty())
            out << section(QStringLiteral("Image"), rows);
    }
}
}

namespace {
// What an event does on the camera itself: its own actions (record, beep, Notify Surveillance Center, light).
QString triggerActions(const Cam &cam, const QString &id)
{
    QByteArray b;
    if (!fetchDoc(cam, QStringLiteral("/ISAPI/Event/triggers/") + id, &b, nullptr))
        return QString();
    // The camera's own words for an action, in plain language.
    static const QHash<QString, QString> names = {
        {QStringLiteral("record"), QStringLiteral("record")},
        {QStringLiteral("beep"), QStringLiteral("audio warning (speaker)")},
        {QStringLiteral("center"), QStringLiteral("notify surveillance center")},
        {QStringLiteral("whiteLight"), QStringLiteral("flash white light")},
        {QStringLiteral("email"), QStringLiteral("send email")},
        {QStringLiteral("FTP"), QStringLiteral("upload to FTP")},
        {QStringLiteral("HTTP"), QStringLiteral("notify HTTP server")},
        {QStringLiteral("IO"), QStringLiteral("alarm output")},
        {QStringLiteral("ptz"), QStringLiteral("PTZ preset")},
        {QStringLiteral("audioOut"), QStringLiteral("audio output")},
        {QStringLiteral("whiteLightOut"), QStringLiteral("flash white light")},
        {QStringLiteral("cloud"), QStringLiteral("notify cloud")}};
    QStringList a = tags(QString::fromUtf8(b), QStringLiteral("notificationMethod"));
    for (QString &m : a)
        m = names.value(m, m);
    return a.isEmpty() ? QStringLiteral("no actions") : a.join(QStringLiteral(", "));
}

// Detection rules, and what each one does.
void detectionSection(const Cam &cam, QVariantList &out)
{
    QByteArray b;
    QVariantList rows;
    auto rule = [&](const QString &label, const QString &path, const QString &trig, bool hasEnabled) {
        QString state = QStringLiteral("-");
        if (hasEnabled) {
            if (!fetchDoc(cam, path, &b, nullptr))
                return;
            state = onOff(tag(QString::fromUtf8(b), QStringLiteral("enabled")));
        }
        const QString act = triggerActions(cam, trig);
        rows << row(label, act.isEmpty() ? state : QStringLiteral("%1 | actions: %2").arg(state, act));
    };
    rule(QStringLiteral("Motion detection"), QStringLiteral("/ISAPI/System/Video/inputs/channels/1/motionDetection"), QStringLiteral("VMD-1"), true);
    rule(QStringLiteral("Intrusion"), QStringLiteral("/ISAPI/Smart/FieldDetection/1"), QStringLiteral("fielddetection-1"), true);
    rule(QStringLiteral("Line crossing"), QStringLiteral("/ISAPI/Smart/LineDetection/1"), QStringLiteral("linedetection-1"), true);
    rule(QStringLiteral("Region entrance"), QStringLiteral("/ISAPI/Smart/regionEntrance/1"), QStringLiteral("regionEntrance-1"), true);
    rule(QStringLiteral("Region exit"), QStringLiteral("/ISAPI/Smart/regionExit/1"), QStringLiteral("regionExiting-1"), true);
    if (fetchDoc(cam, QStringLiteral("/ISAPI/Smart/FaceDetect/1"), &b, nullptr))
        rows << row(QStringLiteral("Face detection"), onOff(tag(QString::fromUtf8(b), QStringLiteral("enabled"))));
    if (!rows.isEmpty())
        out << section(QStringLiteral("Detection"), rows);
}

// One alarm output (audio or white light): its settings, and its hours as a week.
void alarmSection(const Cam &cam, const QString &title, const QString &path, const QString &what, QVariantList &out)
{
    QByteArray b;
    if (!fetchDoc(cam, path, &b, nullptr))
        return;
    const QJsonObject o = QJsonDocument::fromJson(b).object().value(what).toObject();
    if (o.isEmpty())
        return;
    QVariantList rows;
    if (what == QLatin1String("AudioAlarm")) {
        QString sound = QString::number(o.value(QStringLiteral("audioID")).toInt());
        QByteArray capB;
        const QString capPath = path.left(path.indexOf(QLatin1Char('?'))) + QStringLiteral("/capabilities?format=json");
        if (fetchDoc(cam, capPath, &capB, nullptr)) {
            const QJsonArray types = QJsonDocument::fromJson(capB).object().value(QStringLiteral("AudioAlarmCap")).toObject()
                                         .value(QStringLiteral("audioTypeListCap")).toArray();
            for (const QJsonValue &t : types) {
                if (t.toObject().value(QStringLiteral("audioID")).toInt() == o.value(QStringLiteral("audioID")).toInt())
                    sound = t.toObject().value(QStringLiteral("audioDescription")).toString();
            }
        }
        rows << row(QStringLiteral("Sound"), sound)
             << row(QStringLiteral("Volume"), QString::number(o.value(QStringLiteral("audioVolume")).toInt()))
             << row(QStringLiteral("Repeats"), QString::number(o.value(QStringLiteral("alarmTimes")).toInt()));
    } else {
        rows << row(QStringLiteral("Flash duration"), QStringLiteral("%1 s").arg(o.value(QStringLiteral("durationTime")).toInt()))
             << row(QStringLiteral("Flash rate"), o.value(QStringLiteral("frequency")).toString());
    }
    const QVariantList week = weekFromJson(o.value(QStringLiteral("TimeRangeList")).toArray());
    rows << row(QStringLiteral("Hours"), weekText(week));
    QVariantMap s = section(title, rows);
    s.insert(QStringLiteral("week"), week);
    out << s;
}
}

namespace {
// Storage, recording and users.
void storageSections(const Cam &cam, QVariantList &out)
{
    QByteArray b;
    QVariantList rows;
    if (fetchDoc(cam, QStringLiteral("/ISAPI/ContentMgmt/Storage/hdd"), &b, nullptr)) {
        const QString x = QString::fromUtf8(b);
        const QStringList cap = tags(x, QStringLiteral("capacity")), free = tags(x, QStringLiteral("freeSpace")),
                          st = tags(x, QStringLiteral("status")), nm = tags(x, QStringLiteral("hddName"));
        for (int i = 0; i < cap.size(); ++i) {
            rows << row(nm.value(i, QStringLiteral("Card %1").arg(i + 1)),
                        QStringLiteral("%1, %2 of %3 MB free").arg(st.value(i), free.value(i), cap.value(i)));
        }
        if (cap.isEmpty())
            rows << row(QStringLiteral("Memory card"), QStringLiteral("none"));
    }
    if (fetchDoc(cam, QStringLiteral("/ISAPI/ContentMgmt/record/tracks/101"), &b, nullptr)) {
        const QString x = QString::fromUtf8(b);
        rows << row(QStringLiteral("Recording"), onOff(tag(x, QStringLiteral("Enable"))))
             << row(QStringLiteral("Recording mode"), tag(x, QStringLiteral("DefaultRecordingMode")))
             << row(QStringLiteral("Overwrite when full"), onOff(tag(x, QStringLiteral("LoopEnable"))));
    }
    if (!rows.isEmpty())
        out << section(QStringLiteral("Storage and recording"), rows);

    rows.clear();
    if (fetchDoc(cam, QStringLiteral("/ISAPI/Security/users"), &b, nullptr)) {
        const QString x = QString::fromUtf8(b);
        const QStringList names = tags(x, QStringLiteral("userName")), levels = tags(x, QStringLiteral("userLevel"));
        for (int i = 0; i < names.size(); ++i)
            rows << row(names[i], levels.value(i)); // names and levels only, never a password
    }
    if (!rows.isEmpty())
        out << section(QStringLiteral("Users"), rows);
}

}

namespace {
// What the recorder's event rules link to each camera's speaker and white light.
struct RecLink {
    bool ok = false;
    // target channel -> (source channel, event type) for every rule that flashes that camera's light / plays its audio
    QMap<int, QList<QPair<int, QString>>> light, audio;
    // "event-channel" -> 1 on, 0 off, -2 has no switch to read; missing = it could not be read
    QMap<QString, int> enabled;
};

QString eventName(const QString &ev)
{
    static const QHash<QString, QString> names = {
        {QStringLiteral("VMD"), QStringLiteral("Motion")}, {QStringLiteral("fielddetection"), QStringLiteral("Intrusion")},
        {QStringLiteral("linedetection"), QStringLiteral("Line crossing")}, {QStringLiteral("regionEntrance"), QStringLiteral("Region entrance")},
        {QStringLiteral("regionExiting"), QStringLiteral("Region exit")}, {QStringLiteral("facedetection"), QStringLiteral("Face")},
        {QStringLiteral("shelteralarm"), QStringLiteral("Tamper")}, {QStringLiteral("IO"), QStringLiteral("Alarm input")}};
    return names.value(ev, ev);
}

// The recorder's own on/off switch for an event on a channel (empty when the event has no switch we can read).
QString enabledPath(const QString &ev, int ch)
{
    if (ev == QLatin1String("VMD"))
        return QStringLiteral("/ISAPI/System/Video/inputs/channels/%1/motionDetection").arg(ch);
    if (ev == QLatin1String("fielddetection"))
        return QStringLiteral("/ISAPI/Smart/FieldDetection/%1").arg(ch);
    if (ev == QLatin1String("linedetection"))
        return QStringLiteral("/ISAPI/Smart/LineDetection/%1").arg(ch);
    if (ev == QLatin1String("regionEntrance"))
        return QStringLiteral("/ISAPI/Smart/regionEntrance/%1").arg(ch);
    if (ev == QLatin1String("regionExiting"))
        return QStringLiteral("/ISAPI/Smart/regionExit/%1").arg(ch);
    return QString();
}

RecLink fetchRecLink(const Cam &cam)
{
    RecLink link;
    QByteArray b;
    if (!usable(curlGet(cam.recIp, cam.recPort, cam.recUser, cam.recPass, QStringLiteral("/ISAPI/Event/triggers"), &b), b))
        return link;
    const QString x = QString::fromUtf8(b);
    static const QRegularExpression trigRx(QStringLiteral("<EventTrigger>([\\s\\S]*?)</EventTrigger>"));
    static const QRegularExpression noteRx(QStringLiteral("<EventTriggerNotification>([\\s\\S]*?)</EventTriggerNotification>"));
    QSet<QString> used;
    auto it = trigRx.globalMatch(x);
    while (it.hasNext()) {
        const QString block = it.next().captured(1);
        const QString id = tag(block, QStringLiteral("id")); // the first <id> is the rule's own
        const int dash = id.lastIndexOf(QLatin1Char('-'));
        bool numeric = false;
        const int src = dash > 0 ? id.mid(dash + 1).toInt(&numeric) : 0;
        if (!numeric)
            continue;
        const QString ev = id.left(dash);
        auto nit = noteRx.globalMatch(block);
        while (nit.hasNext()) {
            const QString n = nit.next().captured(1);
            const QString method = tag(n, QStringLiteral("notificationMethod"));
            const int target = tag(n, QStringLiteral("lightAudioOutID")).toInt();
            if (target <= 0)
                continue;
            if (method == QLatin1String("whiteLightOut"))
                link.light[target].append({src, ev});
            else if (method == QLatin1String("audioOut"))
                link.audio[target].append({src, ev});
            else
                continue;
            used.insert(id);
        }
    }
    // Which of those events are switched on: a rule that is off never fires, whatever it is linked to.
    for (const QString &id : used) {
        const int dash = id.lastIndexOf(QLatin1Char('-'));
        const QString path = enabledPath(id.left(dash), id.mid(dash + 1).toInt());
        if (path.isEmpty()) {
            link.enabled.insert(id, -2);
            continue;
        }
        bool got = false;
        for (int attempt = 0; attempt < 2 && !got; ++attempt) // a recorder asked many times in a row can drop one answer
            got = usable(curlGet(cam.recIp, cam.recPort, cam.recUser, cam.recPass, path, &b), b);
        if (!got)
            continue;
        link.enabled.insert(id, tag(QString::fromUtf8(b), QStringLiteral("enabled")) == QLatin1String("true") ? 1 : 0);
    }
    link.ok = true;
    return link;
}
}


namespace {
// "Pano: Motion, Intrusion (off); FrontDoor: Motion" for the rules in `rules`; *sources gets just the camera names.
QString describeLinks(const QList<QPair<int, QString>> &rules, const RecLink &link, const QMap<int, QString> &names, QString *sources)
{
    QMap<int, QStringList> bySource;
    for (const auto &r : rules) {
        const int state = link.enabled.value(r.second + QLatin1Char('-') + QString::number(r.first), -1);
        const QString label = eventName(r.second) + (state == 0 ? QStringLiteral(" (off)")
                                                   : (state == -1 ? QStringLiteral(" (state unknown)") : QString()));
        if (!bySource[r.first].contains(label))
            bySource[r.first] << label;
    }
    QStringList parts, who;
    for (auto it = bySource.constBegin(); it != bySource.constEnd(); ++it) {
        const QString nm = names.value(it.key(), QStringLiteral("Channel %1").arg(it.key()));
        parts << nm + QStringLiteral(": ") + it.value().join(QStringLiteral(", "));
        who << nm;
    }
    if (sources)
        *sources = who.isEmpty() ? QStringLiteral("-") : who.join(QStringLiteral(", "));
    return parts.isEmpty() ? QStringLiteral("nothing on the recorder is linked to it") : parts.join(QStringLiteral("; "));
}

// The events (set on the recorder) that flash this camera's light or play its audio.
void linkSection(const Cam &cam, const RecLink &link, QVariantList &out)
{
    if (!link.ok) {
        out << section(QStringLiteral("Linked events (set on the recorder)"),
                       {row(QStringLiteral("Recorder"), QStringLiteral("its event rules could not be read"))});
        return;
    }
    QList<QPair<int, QString>> light, audio;
    for (int ch : cam.channels) {
        light << link.light.value(ch);
        audio << link.audio.value(ch);
    }
    QString lightWho, audioWho;
    QVariantList rows;
    rows << row(QStringLiteral("Flashes the light when"), describeLinks(light, link, cam.recChanNames, &lightWho))
         << row(QStringLiteral("Plays the audio when"), describeLinks(audio, link, cam.recChanNames, &audioWho));
    QString all = rows[0].toMap().value(QStringLiteral("value")).toString() + rows[1].toMap().value(QStringLiteral("value")).toString();
    if (all.contains(QLatin1String("(off)")))
        rows << row(QStringLiteral("Note"), QStringLiteral("(off) means that event is switched off on the recorder, so it never fires"));
    rows << row(QStringLiteral("Note"), QStringLiteral("The camera still applies its own audio and light hours (above) to these requests"));
    QVariantMap s = section(QStringLiteral("Linked events (set on the recorder)"), rows);
    s.insert(QStringLiteral("lightFrom"), lightWho);
    s.insert(QStringLiteral("audioFrom"), audioWho);
    out << s;
}
}

namespace {
// Everything for one camera, in the order the page shows it.
QVariantList readSections(const Cam &cam, QString *why, const RecLink *shared = nullptr)
{
    QVariantList out;
    deviceSections(cam, out, why);
    if (out.isEmpty())
        return out; // nothing answered: the reason is in *why
    videoSections(cam, out);
    detectionSection(cam, out);
    alarmSection(cam, QStringLiteral("Audio alarm (speaker)"), QStringLiteral("/ISAPI/Event/triggers/notifications/AudioAlarm?format=json"),
                 QStringLiteral("AudioAlarm"), out);
    alarmSection(cam, QStringLiteral("Light alarm (white light)"), QStringLiteral("/ISAPI/Event/triggers/notifications/WhiteLightAlarm?format=json"),
                 QStringLiteral("WhiteLightAlarm"), out);
    if (!cam.recIp.isEmpty()) {
        const RecLink own = shared ? RecLink() : fetchRecLink(cam);
        linkSection(cam, shared ? *shared : own, out);
    }
    storageSections(cam, out);
    return out;
}

// One line of the all-cameras table, taken from the sections read for that camera.
QVariantMap overviewRow(const Cam &cam, const QVariantList &sections, const QString &why)
{
    QVariantMap r{{QStringLiteral("name"), cam.name}, {QStringLiteral("ip"), cam.ip}, {QStringLiteral("error"), why},
                  {QStringLiteral("model"), QString()}, {QStringLiteral("firmware"), QString()}, {QStringLiteral("audio"), QStringLiteral("-")},
                  {QStringLiteral("light"), QStringLiteral("-")}, {QStringLiteral("motion"), QStringLiteral("-")},
                  {QStringLiteral("intrusion"), QStringLiteral("-")}, {QStringLiteral("line"), QStringLiteral("-")},
                  {QStringLiteral("lightFrom"), QStringLiteral("-")}, {QStringLiteral("audioFrom"), QStringLiteral("-")}};
    auto value = [](const QVariantMap &s, const QString &label) {
        for (const QVariant &rv : s.value(QStringLiteral("rows")).toList()) {
            if (rv.toMap().value(QStringLiteral("label")).toString() == label)
                return rv.toMap().value(QStringLiteral("value")).toString();
        }
        return QString();
    };
    for (const QVariant &sv : sections) {
        const QVariantMap s = sv.toMap();
        const QString t = s.value(QStringLiteral("title")).toString();
        if (t == QLatin1String("Device")) {
            r[QStringLiteral("model")] = value(s, QStringLiteral("Model"));
            r[QStringLiteral("firmware")] = value(s, QStringLiteral("Firmware")).section(QLatin1Char(' '), 0, 0);
        } else if (t.startsWith(QLatin1String("Audio alarm"))) {
            r[QStringLiteral("audio")] = value(s, QStringLiteral("Hours"));
        } else if (t.startsWith(QLatin1String("Light alarm"))) {
            r[QStringLiteral("light")] = value(s, QStringLiteral("Hours"));
        } else if (t.startsWith(QLatin1String("Linked events"))) {
            r[QStringLiteral("lightFrom")] = s.value(QStringLiteral("lightFrom")).toString();
            r[QStringLiteral("audioFrom")] = s.value(QStringLiteral("audioFrom")).toString();
        } else if (t == QLatin1String("Detection")) {
            r[QStringLiteral("motion")] = value(s, QStringLiteral("Motion detection")).section(QLatin1String(" | "), 0, 0);
            r[QStringLiteral("intrusion")] = value(s, QStringLiteral("Intrusion")).section(QLatin1String(" | "), 0, 0);
            r[QStringLiteral("line")] = value(s, QStringLiteral("Line crossing")).section(QLatin1String(" | "), 0, 0);
        }
    }
    return r;
}
}

void HikvisionCameraInfo::readCamera(const QString &ip, const QString &user, const QString &password)
{
    if (m_busy)
        return;
    const Cam *found = nullptr;
    for (const Cam &c : m_cams) {
        if (c.ip == ip)
            found = &c;
    }
    if (!found) {
        emit readFailed(ip, QStringLiteral("That camera is not in the list. Refresh the list and try again."));
        return;
    }
    Cam cam = *found;
    if (!user.trimmed().isEmpty() && !password.isEmpty()) {
        cam.user = user.trimmed(); // typed just now; used for this read only, never saved here
        cam.pass = password;
    }
    m_busy = true;
    emit busyChanged();
    if (m_worker) {
        m_worker->wait();
        m_worker->deleteLater();
    }
    m_worker = QThread::create([this, cam]() {
        QString why;
        const QVariantList sections = (cam.user.isEmpty() || cam.pass.isEmpty())
            ? QVariantList() : readSections(cam, &why);
        if (sections.isEmpty() && why.isEmpty())
            why = (cam.user.isEmpty() || cam.pass.isEmpty()) ? QStringLiteral("no login saved for this camera (a blank password is never sent)")
                                                              : QStringLiteral("the camera did not answer");
        QMetaObject::invokeMethod(this, [this, cam, sections, why]() {
            m_busy = false;
            emit busyChanged();
            if (sections.isEmpty())
                emit readFailed(cam.ip, why);
            else
                emit cameraRead(cam.ip, sections);
        }, Qt::QueuedConnection);
    });
    m_worker->start();
}

void HikvisionCameraInfo::readOverview()
{
    if (m_busy)
        return;
    if (m_cams.isEmpty()) {
        emit overviewRead(QVariantList());
        return;
    }
    m_busy = true;
    emit busyChanged();
    const QList<Cam> cams = m_cams;
    if (m_worker) {
        m_worker->wait();
        m_worker->deleteLater();
    }
    m_worker = QThread::create([this, cams]() {
        QVariantList rows;
        int n = 0;
        QMap<QString, RecLink> links; // one read of each recorder's rules, shared by its cameras
        for (const Cam &cam : cams) {
            QString why;
            const RecLink *shared = nullptr;
            if (!cam.recIp.isEmpty()) {
                if (!links.contains(cam.recIp))
                    links.insert(cam.recIp, fetchRecLink(cam));
                shared = &links[cam.recIp];
            }
            const QVariantList sections = (cam.user.isEmpty() || cam.pass.isEmpty()) ? QVariantList() : readSections(cam, &why, shared);
            if (sections.isEmpty() && why.isEmpty())
                why = QStringLiteral("no answer");
            rows.append(overviewRow(cam, sections, why));
            ++n;
            QMetaObject::invokeMethod(this, [this, n, total = cams.size()]() { emit overviewProgress(n, total); }, Qt::QueuedConnection);
        }
        QMetaObject::invokeMethod(this, [this, rows]() {
            m_busy = false;
            emit busyChanged();
            emit overviewRead(rows);
        }, Qt::QueuedConnection);
    });
    m_worker->start();
}

QString HikvisionCameraInfo::sectionsToText(const QVariantList &sections) const
{
    QStringList lines;
    for (const QVariant &sv : sections) {
        const QVariantMap s = sv.toMap();
        lines << QStringLiteral("== %1 ==").arg(s.value(QStringLiteral("title")).toString());
        for (const QVariant &rv : s.value(QStringLiteral("rows")).toList()) {
            const QVariantMap r = rv.toMap();
            lines << QStringLiteral("%1: %2").arg(r.value(QStringLiteral("label")).toString(), r.value(QStringLiteral("value")).toString());
        }
        lines << QString();
    }
    return lines.join(QLatin1Char('\n'));
}

QString HikvisionCameraInfo::overviewToText(const QVariantList &rows) const
{
    static const QList<QPair<QString, QString>> cols = {
        {QStringLiteral("Camera"), QStringLiteral("name")}, {QStringLiteral("Address"), QStringLiteral("ip")},
        {QStringLiteral("Model"), QStringLiteral("model")}, {QStringLiteral("Firmware"), QStringLiteral("firmware")},
        {QStringLiteral("Audio hours"), QStringLiteral("audio")}, {QStringLiteral("Light hours"), QStringLiteral("light")},
        {QStringLiteral("Audio triggered by"), QStringLiteral("audioFrom")}, {QStringLiteral("Light triggered by"), QStringLiteral("lightFrom")},
        {QStringLiteral("Motion"), QStringLiteral("motion")}, {QStringLiteral("Intrusion"), QStringLiteral("intrusion")},
        {QStringLiteral("Line crossing"), QStringLiteral("line")}, {QStringLiteral("Problem"), QStringLiteral("error")}};
    QStringList lines;
    QStringList head;
    for (const auto &c : cols)
        head << c.first;
    lines << head.join(QLatin1Char('\t'));
    for (const QVariant &rv : rows) {
        const QVariantMap r = rv.toMap();
        QStringList cells;
        for (const auto &c : cols)
            cells << r.value(c.second).toString().replace(QLatin1Char('\t'), QLatin1Char(' ')).replace(QLatin1Char('\n'), QLatin1Char(' '));
        lines << cells.join(QLatin1Char('\t'));
    }
    return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
}
