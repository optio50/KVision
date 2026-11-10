#include "hikvisiontalk.h"

#include <QAudioDeviceInfo>
#include <QAudioFormat>
#include <QAudioInput>
#include <QCoreApplication>
#include <QDebug>
#include <QFileInfo>
#include <QPointer>
#include <QAuthenticator>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits.h>
#include <unistd.h>

namespace {

// The Hikvision voice-talk component loads libopenal.so.1 and libAudioRender.so by the
// relative path "./", so the process working directory must be the SDK library folder while a
// session is opened. Only one thread may change the directory at a time.
std::mutex g_cwdMutex;

std::atomic<long> g_talkReturnedPackets{0};

void CALLBACK talkReceiveCallback(LONG, char *, DWORD, BYTE, void *)
{
    // Audio coming back from the camera is not played; the normal live stream carries it.
    // It is only counted, as proof that the camera really opened a talk session.
    ++g_talkReturnedPackets;
}

} // namespace

QString HikvisionTalk::sdkLibDir()
{
    const QString appDir = QCoreApplication::applicationDirPath();
    const QStringList candidates = {
        appDir + QStringLiteral("/../src/hikvision_sdk/lib"),
        appDir + QStringLiteral("/../lib/kvision"),
        appDir + QStringLiteral("/../lib64/kvision"),
        QStringLiteral("/usr/lib/kvision"),
    };
    for (const QString &dir : candidates) {
        if (QFileInfo::exists(dir + QStringLiteral("/libopenal.so.1")))
            return QFileInfo(dir).canonicalFilePath();
    }
    return QString();
}

HikvisionTalk::HikvisionTalk(SessionProvider provider, QObject *parent)
    : QObject(parent)
    , m_provider(std::move(provider))
    , m_resampler(48000, 8000)
    , m_processor(8000)
{
    m_connectTimeout.setSingleShot(true);
    m_connectTimeout.setInterval(12000);
    connect(&m_connectTimeout, &QTimer::timeout, this, [this]() {
        if (m_active && !m_live)
            endSession(tr("The camera did not answer the talk request in time."));
    });

    // Safety net: if the button release is ever missed, never leave the microphone open.
    m_maxDuration.setSingleShot(true);
    m_maxDuration.setInterval(90000);
    connect(&m_maxDuration, &QTimer::timeout, this, [this]() {
        if (m_active)
            endSession(tr("Talk stopped after 90 seconds."));
    });
}

HikvisionTalk::~HikvisionTalk()
{
    releaseCapture();
    if (m_job) {
        m_job->stop = true;
        m_job->cv.notify_all();
        // Give the worker a moment to close the session; never block shutdown for long.
        for (int i = 0; i < 20 && !m_job->done; ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

QStringList HikvisionTalk::microphones() const
{
    QStringList names;
    const auto devices = QAudioDeviceInfo::availableDevices(QAudio::AudioInput);
    for (const QAudioDeviceInfo &d : devices) {
        const QString name = d.deviceName();
        if (name.contains(QStringLiteral(".monitor"), Qt::CaseInsensitive))
            continue; // loopback of a speaker, not a real microphone
        names << name;
    }
    // With the PulseAudio/PipeWire backend the real microphones are listed by their
    // "alsa_input" / "bluez_input" names. The raw ALSA plugin names that Qt can also report
    // (lavrate, jack, hw:CARD=..., ...) are not useful choices, so hide them when real ones exist.
    QStringList real;
    for (const QString &n : qAsConst(names)) {
        if (n.contains(QStringLiteral("_input.")) || n.startsWith(QStringLiteral("alsa_input")))
            real << n;
    }
    return real.isEmpty() ? names : real;
}

bool HikvisionTalk::start(const QString &key, const QString &ip, int port, const QString &user,
                          const QString &pass, const QString &micName, double gain, double boostDb)
{
    if (m_active) {
        qWarning() << "[Talk] A talk session is already active";
        return false;
    }
    if (m_job && !m_job->done) {
        qWarning() << "[Talk] The previous talk session is still closing";
        emit finished(key, tr("The previous talk session is still closing. Try again in a moment."));
        return false;
    }
    if (sdkLibDir().isEmpty()) {
        qWarning() << "[Talk] Hikvision voice components were not found";
        emit finished(key, tr("The Hikvision voice components were not found."));
        return false;
    }

    // Pick the microphone.
    QAudioDeviceInfo device = QAudioDeviceInfo::defaultInputDevice();
    if (!micName.isEmpty()) {
        for (const QAudioDeviceInfo &d : QAudioDeviceInfo::availableDevices(QAudio::AudioInput)) {
            if (d.deviceName() == micName) {
                device = d;
                break;
            }
        }
    }
    if (device.isNull()) {
        emit finished(key, tr("No microphone was found."));
        return false;
    }

    QAudioFormat fmt;
    fmt.setSampleRate(48000);
    fmt.setChannelCount(1);
    fmt.setSampleSize(16);
    fmt.setCodec(QStringLiteral("audio/pcm"));
    fmt.setByteOrder(QAudioFormat::LittleEndian);
    fmt.setSampleType(QAudioFormat::SignedInt);
    if (!device.isFormatSupported(fmt))
        fmt = device.nearestFormat(fmt);
    if (fmt.sampleSize() != 16 || fmt.sampleType() != QAudioFormat::SignedInt
        || fmt.byteOrder() != QAudioFormat::LittleEndian || fmt.channelCount() != 1
        || fmt.sampleRate() < 8000) {
        qWarning() << "[Talk] Unsupported microphone format" << fmt;
        emit finished(key, tr("The microphone does not offer a supported audio format."));
        return false;
    }

    m_inputRate = fmt.sampleRate();
    m_gain = std::max(0.1, std::min(8.0, gain));
    m_boostDb = boostDb;
    configureAudioChain(FormatUlaw, 8000); // until the camera tells us what it wants

    m_input = new QAudioInput(device, fmt, this);
    m_input->setBufferSize(m_inputRate / 10 * 2); // about 100 ms
    m_io = m_input->start();
    if (!m_io || m_input->error() != QAudio::NoError) {
        qWarning() << "[Talk] Could not open the microphone" << (m_input ? m_input->error() : -1);
        releaseCapture();
        emit finished(key, tr("Could not open the microphone."));
        return false;
    }
    connect(m_io, &QIODevice::readyRead, this, &HikvisionTalk::onAudioReady);

    auto job = std::make_shared<Job>();
    job->ip = ip;
    job->port = port;
    job->user = user;
    job->pass = pass;
    m_job = job;

    m_active = true;
    m_live = false;
    m_activeKey = key;
    m_level = 0.0;
    m_levelTicks = 0;
    emit activeChanged();
    emit liveChanged();

    m_connectTimeout.start();
    m_maxDuration.start();

    std::thread([this, job]() { workerMain(job); }).detach();
    qDebug() << "[Talk] Started for" << ip << "using microphone" << device.deviceName();
    return true;
}

void HikvisionTalk::stop()
{
    if (!m_active)
        return;
    endSession(QString());
}

void HikvisionTalk::endSession(const QString &message)
{
    if (!m_active)
        return;
    const QString key = m_activeKey;
    m_connectTimeout.stop();
    m_maxDuration.stop();
    releaseCapture();
    if (m_job) {
        m_job->stop = true;
        m_job->cv.notify_all();
    }
    m_active = false;
    m_live = false;
    m_activeKey.clear();
    m_level = 0.0;
    emit activeChanged();
    emit liveChanged();
    emit levelChanged();
    emit finished(key, message);
    qDebug() << "[Talk] Ended" << (message.isEmpty() ? QStringLiteral("normally") : message);
}

// Sets up resampling, levelling and encoding for the format the camera asked for.
bool HikvisionTalk::configureAudioChain(int format, int outRate)
{
    m_format = static_cast<Format>(format);
    m_outRate = outRate;
    m_resampler = TalkAudio::Resampler(m_inputRate, outRate);
    m_processor = TalkAudio::VoiceProcessor(outRate);
    m_processor.setGain(m_gain);
    m_processor.setOutputBoostDb(m_boostDb);
    m_pending.clear();
    m_aac.reset();

    int frameMs = 20; // G.711 is sent in 20 ms frames
    if (m_format == FormatAac) {
        m_aac.reset(new TalkAacEncoder());
        if (!m_aac->open(outRate, 32000)) {
            m_aac.reset();
            return false;
        }
        frameMs = std::max(1, m_aac->frameSize() * 1000 / outRate);
    }
    m_maxQueued = static_cast<size_t>(std::max(8, 1000 / frameMs)); // about one second at most
    return true;
}

void HikvisionTalk::releaseCapture()
{
    if (m_input) {
        if (m_io)
            disconnect(m_io, nullptr, this, nullptr);
        m_input->stop();
        m_input->deleteLater();
        m_input = nullptr;
        m_io = nullptr;
    }
    m_pending.clear();
}

void HikvisionTalk::onAudioReady()
{
    if (!m_io || !m_active)
        return;
    const QByteArray raw = m_io->readAll();
    const int count = raw.size() / 2;
    if (count <= 0)
        return;

    std::vector<float> in(static_cast<size_t>(count));
    const int16_t *src = reinterpret_cast<const int16_t *>(raw.constData());
    for (int i = 0; i < count; ++i)
        in[static_cast<size_t>(i)] = src[i] / 32768.0f;

    std::vector<float> out;
    out.reserve(static_cast<size_t>(count) * static_cast<size_t>(m_outRate) / static_cast<size_t>(m_inputRate) + 2);
    m_resampler.process(in.data(), count, out);
    if (out.empty())
        return;

    const float peak = m_processor.process(out.data(), static_cast<int>(out.size()));

    // Smooth level for the on-screen meter, about 10 updates per second.
    m_level = std::max(static_cast<double>(peak), m_level * 0.8);
    if (++m_levelTicks >= 3) {
        m_levelTicks = 0;
        emit levelChanged();
    }

    // Until the camera has accepted the session, audio is dropped so nothing is delayed.
    if (!m_live || !m_job)
        return;

    if (m_format == FormatAac) {
        if (!m_aac)
            return;
        std::vector<int16_t> pcm(out.size());
        for (size_t i = 0; i < out.size(); ++i)
            pcm[i] = static_cast<int16_t>(std::max(-32768, std::min(32767, static_cast<int>(std::lrintf(out[i] * 32767.0f)))));
        std::vector<std::vector<uint8_t>> frames;
        m_aac->encode(pcm.data(), static_cast<int>(pcm.size()), frames);
        if (frames.empty())
            return;
        {
            std::lock_guard<std::mutex> lock(m_job->m);
            for (auto &f : frames)
                m_job->frames.push_back(std::move(f));
            while (m_job->frames.size() > m_maxQueued)
                m_job->frames.pop_front();
        }
        m_job->cv.notify_one();
        return;
    }

    // G.711, sent in 20 ms (160 byte) frames.
    for (float s : out) {
        int v = static_cast<int>(std::lrintf(s * 32767.0f));
        v = std::max(-32768, std::min(32767, v));
        m_pending.push_back(m_format == FormatAlaw ? TalkAudio::linearToAlaw(static_cast<int16_t>(v))
                                                   : TalkAudio::linearToUlaw(static_cast<int16_t>(v)));
    }
    const size_t frame = 160;
    size_t offset = 0;
    {
        std::lock_guard<std::mutex> lock(m_job->m);
        while (m_pending.size() - offset >= frame) {
            m_job->frames.emplace_back(m_pending.begin() + static_cast<long>(offset),
                                       m_pending.begin() + static_cast<long>(offset + frame));
            offset += frame;
        }
        while (m_job->frames.size() > m_maxQueued)
            m_job->frames.pop_front();
    }
    if (offset > 0)
        m_pending.erase(m_pending.begin(), m_pending.begin() + static_cast<long>(offset));
    m_job->cv.notify_one();
}

void HikvisionTalk::onWorkerLive(const std::shared_ptr<Job> &job, int format, int outRate)
{
    if (!m_active || job != m_job || m_live)
        return;
    if (!configureAudioChain(format, outRate)) {
        endSession(tr("KVision could not start the audio encoder this camera needs."));
        return;
    }
    m_connectTimeout.stop();
    m_live = true;
    emit liveChanged();
}

void HikvisionTalk::onWorkerFailed(const std::shared_ptr<Job> &job, const QString &message)
{
    if (!m_active || job != m_job)
        return;
    endSession(message);
}

void HikvisionTalk::workerMain(std::shared_ptr<Job> job)
{
    QPointer<HikvisionTalk> self(this);
    auto post = [self](std::function<void(HikvisionTalk *)> fn) {
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, fn]() {
            if (self)
                fn(self.data());
        }, Qt::QueuedConnection);
    };
    auto fail = [&](const QString &msg) {
        job->done = true;
        post([job, msg](HikvisionTalk *t) { t->onWorkerFailed(job, msg); });
    };

    const LONG userId = m_provider(job->ip, job->port, job->user, job->pass);
    if (userId < 0) {
        fail(tr("Could not log in to the camera."));
        return;
    }
    if (job->stop) {
        job->done = true;
        return;
    }

    // Ask the camera which audio format it wants. Most cameras take G.711 u-law at 8 kHz, but
    // some (older doorbells, for instance) want AAC at 16 kHz.
    int format = FormatUlaw;
    int outRate = 8000;
    {
        NET_DVR_COMPRESSION_AUDIO ca;
        std::memset(&ca, 0, sizeof(ca));
        NET_DVR_AUDIO_CHANNEL ac;
        std::memset(&ac, 0, sizeof(ac));
        ac.dwChannelNum = 1;
        BOOL ok = NET_DVR_GetCurrentAudioCompress_V50(userId, &ac, &ca);
        if (!ok) {
            std::memset(&ca, 0, sizeof(ca));
            ok = NET_DVR_GetCurrentAudioCompress(userId, &ca);
        }
        if (ok) {
            static const int rates[] = {8000, 16000, 32000, 48000, 44100, 8000};
            const int rateCode = ca.byAudioSamplingRate;
            switch (ca.byAudioEncType) {
            case AUDIOTALKTYPE_G711_MU:
                format = FormatUlaw;
                outRate = 8000;
                break;
            case AUDIOTALKTYPE_G711_A:
                format = FormatAlaw;
                outRate = 8000;
                break;
            case AUDIOTALKTYPE_AAC:
                format = FormatAac;
                outRate = (rateCode >= 1 && rateCode <= 5) ? rates[rateCode] : 16000;
                break;
            default:
                qWarning() << "[Talk] Unsupported camera audio format" << ca.byAudioEncType;
                fail(tr("This camera wants an audio format KVision cannot send (code %1).").arg(ca.byAudioEncType));
                return;
            }
            qDebug() << "[Talk] Camera audio format" << ca.byAudioEncType << "rate" << outRate;
        } else {
            qWarning() << "[Talk] Could not read the camera audio format; assuming G.711 u-law 8 kHz";
        }
    }

    // Open the talk session from inside the SDK folder (see g_cwdMutex above).
    LONG handle = -1;
    DWORD err = 0;
    {
        std::lock_guard<std::mutex> lock(g_cwdMutex);
        char oldCwd[PATH_MAX] = {0};
        const bool haveOld = getcwd(oldCwd, sizeof(oldCwd)) != nullptr;
        const QByteArray dir = sdkLibDir().toLocal8Bit();
        if (!dir.isEmpty() && chdir(dir.constData()) != 0)
            qWarning() << "[Talk] Could not enter the SDK folder";
        handle = NET_DVR_StartVoiceCom_MR_V30(userId, 1, talkReceiveCallback, nullptr);
        if (handle < 0)
            err = NET_DVR_GetLastError();
        if (haveOld && chdir(oldCwd) != 0)
            qWarning() << "[Talk] Could not restore the working directory";
    }
    if (handle < 0) {
        qWarning() << "[Talk] StartVoiceCom failed, SDK error" << err;
        fail(err == NET_DVR_DVRVOICEOPENED || err == NET_ERR_VOICETALK_ONLY_SUPPORT_ONE_TALK
                 ? tr("The camera is already in a talk session.")
                 : tr("The camera did not accept the talk request (error %1).").arg(err));
        return;
    }

    if (job->stop) {
        NET_DVR_StopVoiceCom(handle);
        job->done = true;
        return;
    }
    post([job, format, outRate](HikvisionTalk *t) { t->onWorkerLive(job, format, outRate); });

    std::vector<uint8_t> frame;
    int failedSends = 0;
    long framesSent = 0, framesFailed = 0;
    g_talkReturnedPackets = 0;
    while (true) {
        {
            std::unique_lock<std::mutex> lock(job->m);
            job->cv.wait_for(lock, std::chrono::milliseconds(200),
                             [&] { return job->stop || !job->frames.empty(); });
            if (job->stop)
                break;
            if (job->frames.empty())
                continue;
            frame = std::move(job->frames.front());
            job->frames.pop_front();
        }
        if (!NET_DVR_VoiceComSendData(handle, reinterpret_cast<char *>(frame.data()),
                                      static_cast<DWORD>(frame.size()))) {
            ++framesFailed;
            if (++failedSends > 25) {
                qWarning() << "[Talk] Sending audio failed repeatedly, SDK error" << NET_DVR_GetLastError();
                NET_DVR_StopVoiceCom(handle);
                fail(tr("Sending audio to the camera failed."));
                return;
            }
        } else {
            failedSends = 0;
            ++framesSent;
        }
    }
    qDebug() << "[Talk] Sent" << framesSent << "audio frames to" << job->ip << "(" << framesFailed
             << "failed); the camera returned" << g_talkReturnedPackets.load() << "audio packets";
    NET_DVR_StopVoiceCom(handle);
    job->done = true;
}


namespace {
const char *kTalkChannelPath = "/ISAPI/System/TwoWayAudio/channels/1";
}

QNetworkReply *HikvisionTalk::sendTalkRequest(const QByteArray &verb, const QString &ip, int httpPort,
                                              const QString &user, const QString &pass, const QByteArray &body)
{
    if (!m_net) {
        m_net = new QNetworkAccessManager(this);
        connect(m_net, &QNetworkAccessManager::authenticationRequired, this,
                [](QNetworkReply *reply, QAuthenticator *auth) {
            // Credentials travel on the reply so concurrent requests to different cameras cannot mix.
            auth->setUser(reply->property("talkUser").toString());
            auth->setPassword(reply->property("talkPass").toString());
        });
    }
    QUrl url;
    url.setScheme(QStringLiteral("http"));
    url.setHost(ip.section(QLatin1Char(':'), 0, 0).trimmed());
    url.setPort(httpPort > 0 ? httpPort : 80);
    url.setPath(QString::fromLatin1(kTalkChannelPath));

    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/xml"));
    req.setTransferTimeout(6000);
    QNetworkReply *reply = body.isNull()
        ? m_net->sendCustomRequest(req, verb)
        : m_net->sendCustomRequest(req, verb, body);
    reply->setProperty("talkUser", user);
    reply->setProperty("talkPass", pass);
    return reply;
}

void HikvisionTalk::loadSpeakerVolume(const QString &ip, int httpPort, const QString &user, const QString &pass)
{
    QNetworkReply *reply = sendTalkRequest("GET", ip, httpPort, user, pass);
    connect(reply, &QNetworkReply::finished, this, [this, reply, ip]() {
        int volume = -1;
        if (reply->error() == QNetworkReply::NoError) {
            const QString xml = QString::fromUtf8(reply->readAll());
            const QRegularExpressionMatch m =
                QRegularExpression(QStringLiteral("<speakerVolume>(\\d+)</speakerVolume>")).match(xml);
            if (m.hasMatch())
                volume = m.captured(1).toInt();
        } else {
            qWarning() << "[Talk] Reading the speaker volume failed:" << reply->errorString();
        }
        reply->deleteLater();
        emit speakerVolumeLoaded(ip, volume);
    });
}

void HikvisionTalk::saveSpeakerVolume(const QString &ip, int httpPort, const QString &user, const QString &pass, int volume)
{
    volume = std::max(0, std::min(100, volume));
    // Read the camera's current two-way audio settings first and change only speakerVolume.
    QNetworkReply *get = sendTalkRequest("GET", ip, httpPort, user, pass);
    connect(get, &QNetworkReply::finished, this, [this, get, ip, httpPort, user, pass, volume]() {
        const QByteArray xml = get->readAll();
        const bool readOk = get->error() == QNetworkReply::NoError;
        get->deleteLater();
        static const QRegularExpression volRx(QStringLiteral("<speakerVolume>\\d+</speakerVolume>"));
        const QString text = QString::fromUtf8(xml);
        if (!readOk || !volRx.match(text).hasMatch()) {
            qWarning() << "[Talk] Could not read the camera's talk settings before saving";
            emit speakerVolumeSaved(ip, false, volume);
            return;
        }
        QString updated = text;
        updated.replace(volRx, QStringLiteral("<speakerVolume>%1</speakerVolume>").arg(volume));
        QNetworkReply *put = sendTalkRequest("PUT", ip, httpPort, user, pass, updated.toUtf8());
        connect(put, &QNetworkReply::finished, this, [this, put, ip, volume]() {
            const bool ok = put->error() == QNetworkReply::NoError
                            && QString::fromUtf8(put->readAll()).contains(QStringLiteral("<statusString>OK</statusString>"));
            if (!ok)
                qWarning() << "[Talk] Saving the speaker volume failed:" << put->errorString();
            put->deleteLater();
            emit speakerVolumeSaved(ip, ok, volume);
        });
    });
}
