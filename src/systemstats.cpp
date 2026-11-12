#include "systemstats.h"
#include "context.h"
#include "qmlav/src/qmlavdemuxer.h"
#include <QDir>
#include <QFile>
#include <QTextStream>
#include <QDebug>
#include <QProcess>
#include <QFileInfo>
#include <QRegularExpression>
#include <QLibrary>
#include <QSettings>
#include <QDateTime>
#include <cstring>
#include <unistd.h>
#include <sys/types.h>

// NVML Types
typedef void* nvmlDevice_t;
typedef enum nvmlReturn_enum {
    NVML_SUCCESS = 0,
    NVML_ERROR_NOT_SUPPORTED = 3,
} nvmlReturn_t;

typedef struct nvmlUtilization_st {
    unsigned int gpu;
    unsigned int memory;
} nvmlUtilization_t;

typedef struct nvmlProcessInfo_st {
    unsigned int pid;
    unsigned long long usedGpuMemory;
} nvmlProcessInfo_t;

typedef struct nvmlProcessUtilizationSample_st {
    unsigned int pid;
    unsigned long long timeStamp;
    unsigned int smUtil;
    unsigned int memUtil;
    unsigned int encUtil;
    unsigned int decUtil;
} nvmlProcessUtilizationSample_t;

typedef nvmlReturn_t (*fn_nvmlInit)(void);
typedef nvmlReturn_t (*fn_nvmlShutdown)(void);
typedef nvmlReturn_t (*fn_nvmlDeviceGetCount)(unsigned int *deviceCount);
typedef nvmlReturn_t (*fn_nvmlDeviceGetHandleByIndex)(unsigned int index, nvmlDevice_t *device);
typedef nvmlReturn_t (*fn_nvmlDeviceGetUtilizationRates)(nvmlDevice_t device, nvmlUtilization_t *rates);
typedef nvmlReturn_t (*fn_nvmlDeviceGetGraphicsRunningProcesses)(nvmlDevice_t device, unsigned int *infoCount, nvmlProcessInfo_t *infos);
typedef nvmlReturn_t (*fn_nvmlDeviceGetComputeRunningProcesses)(nvmlDevice_t device, unsigned int *infoCount, nvmlProcessInfo_t *infos);
typedef nvmlReturn_t (*fn_nvmlDeviceGetProcessUtilization)(nvmlDevice_t device, nvmlProcessUtilizationSample_t *utilization, unsigned int *processSamplesCount, unsigned long long lastSeenTimeStamp);

struct StatsWorker::NvmlContext {
    QLibrary lib;
    bool initialized = false;
    bool loadFailed = false;

    fn_nvmlInit nvmlInit = nullptr;
    fn_nvmlShutdown nvmlShutdown = nullptr;
    fn_nvmlDeviceGetCount nvmlDeviceGetCount = nullptr;
    fn_nvmlDeviceGetHandleByIndex nvmlDeviceGetHandleByIndex = nullptr;
    fn_nvmlDeviceGetUtilizationRates nvmlDeviceGetUtilizationRates = nullptr;
    fn_nvmlDeviceGetGraphicsRunningProcesses nvmlDeviceGetGraphicsRunningProcesses = nullptr;
    fn_nvmlDeviceGetComputeRunningProcesses nvmlDeviceGetComputeRunningProcesses = nullptr;
    fn_nvmlDeviceGetProcessUtilization nvmlDeviceGetProcessUtilization = nullptr;

    ~NvmlContext() {
        if (initialized && nvmlShutdown) {
            nvmlShutdown();
        }
        if (lib.isLoaded()) {
            lib.unload();
        }
    }

    bool ensureInitialized() {
        if (initialized) return true;
        if (loadFailed) return false;

        const QStringList candidates = {
            "nvidia-ml",
            "libnvidia-ml.so.1"
        };
        bool loaded = false;
        for (const QString &name : candidates) {
            lib.setFileName(name);
            if (lib.load()) {
                loaded = true;
                break;
            }
        }
        if (!loaded) {
            loadFailed = true;
            return false;
        }

        nvmlInit = (fn_nvmlInit)lib.resolve("nvmlInit_v2");
        if (!nvmlInit) nvmlInit = (fn_nvmlInit)lib.resolve("nvmlInit");

        nvmlShutdown = (fn_nvmlShutdown)lib.resolve("nvmlShutdown");

        nvmlDeviceGetCount = (fn_nvmlDeviceGetCount)lib.resolve("nvmlDeviceGetCount_v2");
        if (!nvmlDeviceGetCount) nvmlDeviceGetCount = (fn_nvmlDeviceGetCount)lib.resolve("nvmlDeviceGetCount");

        nvmlDeviceGetHandleByIndex = (fn_nvmlDeviceGetHandleByIndex)lib.resolve("nvmlDeviceGetHandleByIndex_v2");
        if (!nvmlDeviceGetHandleByIndex) nvmlDeviceGetHandleByIndex = (fn_nvmlDeviceGetHandleByIndex)lib.resolve("nvmlDeviceGetHandleByIndex");

        nvmlDeviceGetUtilizationRates = (fn_nvmlDeviceGetUtilizationRates)lib.resolve("nvmlDeviceGetUtilizationRates");

        nvmlDeviceGetGraphicsRunningProcesses = (fn_nvmlDeviceGetGraphicsRunningProcesses)lib.resolve("nvmlDeviceGetGraphicsRunningProcesses");
        if (!nvmlDeviceGetGraphicsRunningProcesses) nvmlDeviceGetGraphicsRunningProcesses = (fn_nvmlDeviceGetGraphicsRunningProcesses)lib.resolve("nvmlDeviceGetGraphicsRunningProcesses_v2");

        nvmlDeviceGetComputeRunningProcesses = (fn_nvmlDeviceGetComputeRunningProcesses)lib.resolve("nvmlDeviceGetComputeRunningProcesses");
        if (!nvmlDeviceGetComputeRunningProcesses) nvmlDeviceGetComputeRunningProcesses = (fn_nvmlDeviceGetComputeRunningProcesses)lib.resolve("nvmlDeviceGetComputeRunningProcesses_v2");

        nvmlDeviceGetProcessUtilization = (fn_nvmlDeviceGetProcessUtilization)lib.resolve("nvmlDeviceGetProcessUtilization");

        if (!nvmlInit || !nvmlShutdown || !nvmlDeviceGetCount || !nvmlDeviceGetHandleByIndex ||
            !nvmlDeviceGetUtilizationRates || !nvmlDeviceGetGraphicsRunningProcesses || !nvmlDeviceGetComputeRunningProcesses) {
            lib.unload();
            loadFailed = true;
            return false;
        }

        if (nvmlInit() != NVML_SUCCESS) {
            lib.unload();
            loadFailed = true;
            return false;
        }

        initialized = true;
        return true;
    }
};


StatsWorker::StatsWorker(QObject *parent)
    : QObject(parent)
{
    m_netTimer.start();
    m_gpuTimer.start();
    m_nvml = new NvmlContext();
}

StatsWorker::~StatsWorker()
{
    delete m_nvml;

    qint64 selfPid = getpid();
    uid_t myUid = getuid();
    QString shmDir = "/dev/shm";
    if (!QDir(shmDir).exists() || !QFileInfo(shmDir).isWritable()) {
        shmDir = QDir::tempPath();
    }
    QString myNetFile = QString("%1/kvision-net-%2-%3").arg(shmDir).arg(myUid).arg(selfPid);
    QString myGpuFile = QString("%1/kvision-gpu-%2-%3").arg(shmDir).arg(myUid).arg(selfPid);
    QString myVramFile = QString("%1/kvision-vram-%2-%3").arg(shmDir).arg(myUid).arg(selfPid);
    QFile::remove(myNetFile);
    QFile::remove(myGpuFile);
    QFile::remove(myVramFile);
}

void StatsWorker::doWork()
{
    if (m_pidCacheTicks <= 0) {
        m_cachedPids = getProgramPids();
        m_pidCacheTicks = 5; // Refresh PID list every 5 seconds to reduce CPU/RAM overhead
    }
    m_pidCacheTicks--;

    QVector<qint64> pids = m_cachedPids;

    StatsSample sample;
    sample.timestampMs = QDateTime::currentMSecsSinceEpoch();

    // Full fidelity at all times: while the panel is closed the history buffer
    // collects the same numbers an open panel would show, so the past it keeps
    // is not a downgraded view of what happened.
    calculateCpuAndRam(pids, sample.cpu, sample.ram, sample.busiestCore);
    calculateGpuAndVram(pids, sample.gpu, sample.vram, sample.gpuDec);
    calculateNetUsage(pids, sample.net);

    // Streams open right now, and what the ever-growing counters gained this tick.
    sample.rtspStreams = g_rtspStreams.load(std::memory_order_relaxed);
    sample.sdkStreams = g_sdkStreams.load(std::memory_order_relaxed);
    const qint64 dropsTotal = g_framesDropped.load(std::memory_order_relaxed);
    const qint64 errorsTotal = g_decodeErrors.load(std::memory_order_relaxed);
    sample.dropsPerSecond = double(qMax<qint64>(0, dropsTotal - m_lastDropsTotal));
    sample.errorsPerSecond = double(qMax<qint64>(0, errorsTotal - m_lastErrorsTotal));
    m_lastDropsTotal = dropsTotal;
    m_lastErrorsTotal = errorsTotal;

    m_lastSample = sample;

    // Always emit: the rolling buffer in SystemStats gathers the samples even
    // while the panel is closed.
    emit workDone(sample);
}

void StatsWorker::emitLatest()
{
    emit workDone(m_lastSample);
}

SystemStats::SystemStats(QObject *parent)
    : QObject(parent)
{
    // The history window is a saved setting so every KVision process (the
    // main window and the auxiliary ones) starts with the same length. Set
    // before anything else so the ring exists before the first sample arrives.
    {
        QSettings settings(Context::config() ? Context::config()->fileName() : QSettings().fileName(),
                           QSettings::IniFormat);
        setHistoryMinutes(settings.value("statsHistoryMinutes", 15).toInt());
    }

    // The worker thread delivers whole samples through a queued connection,
    // so the type must be known to the metatype system.
    qRegisterMetaType<StatsSample>("StatsSample");

    m_worker = new StatsWorker();
    m_workerThread = new QThread(this);
    m_worker->moveToThread(m_workerThread);

    connect(m_workerThread, &QThread::finished, m_worker, &QObject::deleteLater);

    m_timer = new QTimer(this);
    connect(m_timer, &QTimer::timeout, m_worker, &StatsWorker::doWork);
    connect(m_worker, &StatsWorker::workDone, this, &SystemStats::onWorkDone);

    m_workerThread->start();
    m_timer->start(1000); // Always run the timer to report background stats!
}

SystemStats::~SystemStats()
{
    m_timer->stop();
    m_workerThread->quit();
    m_workerThread->wait();
}

void SystemStats::onWorkDone(const StatsSample &sample)
{
    m_cpuUsage = sample.cpu;
    m_gpuUsage = sample.gpu;
    m_ramUsage = sample.ram;
    m_vramUsage = sample.vram;
    m_netUsage = sample.net;
    m_gpuDecodeUsage = sample.gpuDec;
    m_busiestCoreUsage = sample.busiestCore;
    m_rtspStreams = sample.rtspStreams;
    m_sdkStreams = sample.sdkStreams;

    // Since-start counters for the panel; the ring keeps the per-tick rates.
    m_decDropsTotal += qint64(sample.dropsPerSecond);
    m_decErrorsTotal += qint64(sample.errorsPerSecond);

    appendHistory(sample);

    emit statsChanged();
}

bool SystemStats::active() const
{
    return m_active;
}

void SystemStats::setActive(bool active)
{
    if (m_active == active) return;
    m_active = active;
    m_worker->setUiActive(active);

    if (m_active) {
        QMetaObject::invokeMethod(m_worker, "emitLatest", Qt::QueuedConnection);
    } else {
        m_cpuUsage = 0.0;
        m_gpuUsage = 0.0;
        m_ramUsage = 0.0;
        m_vramUsage = 0.0;
        m_netUsage = 0.0;
        m_gpuDecodeUsage = 0.0;
        m_busiestCoreUsage = 0;
        m_rtspStreams = 0;
        m_sdkStreams = 0;
        emit statsChanged();
    }
    emit activeChanged();
}

static double sampleMetric(const StatsSample &s, const QString &metric)
{
    if (metric == QLatin1String("cpu"))
        return s.cpu;
    if (metric == QLatin1String("ram"))
        return s.ram;
    if (metric == QLatin1String("gpu"))
        return s.gpu;
    if (metric == QLatin1String("vram"))
        return s.vram;
    if (metric == QLatin1String("net"))
        return s.net;
    if (metric == QLatin1String("gpuDec"))
        return s.gpuDec;
    if (metric == QLatin1String("busiestCore"))
        return s.busiestCore;
    if (metric == QLatin1String("rtsp"))
        return s.rtspStreams;
    if (metric == QLatin1String("sdk"))
        return s.sdkStreams;
    if (metric == QLatin1String("drops"))
        return s.dropsPerSecond;
    if (metric == QLatin1String("errors"))
        return s.errorsPerSecond;
    return 0.0;
}

void SystemStats::setHistoryMinutes(int minutes)
{
    minutes = qMax(1, minutes);
    if (minutes == m_historyMinutes)
        return;

    // Move the newest samples that still fit into the new ring.
    const int newSize = minutes * 60;
    QVector<StatsSample> next(newSize);
    const int keep = qMin(m_historyCount, newSize);
    const int oldSize = m_history.size();
    for (int i = 0; i < keep && oldSize > 0; ++i) {
        const int src = (m_historyHead - keep + i + oldSize) % oldSize;
        next[i] = m_history[src];
    }
    m_history = next;
    m_historyHead = keep % newSize;
    m_historyCount = keep;
    m_historyMinutes = minutes;
    emit historyMinutesChanged();
}

void SystemStats::appendHistory(const StatsSample &sample)
{
    if (m_history.isEmpty())
        return;
    m_history[m_historyHead] = sample;
    m_historyHead = (m_historyHead + 1) % m_history.size();
    m_historyCount = qMin(m_historyCount + 1, m_history.size());
}

QVariantList SystemStats::historySnapshot(const QString &metric, int maxPoints) const
{
    QVariantList out;
    const int total = m_historyCount;
    const int size = m_history.size();
    if (total <= 0 || size <= 0)
        return out;

    // One averaged point per bin; bins are at least one sample wide.
    const int pts = qBound(1, maxPoints, total);
    const int start = (m_historyHead - total + size) % size;
    for (int p = 0; p < pts; ++p) {
        const qint64 b0 = (qint64)p * total / pts;
        const qint64 b1 = (qint64)(p + 1) * total / pts;
        const int count = int(b1 - b0);
        if (count > 0) {
            double sum = 0.0;
            for (qint64 i = b0; i < b1; ++i)
                sum += sampleMetric(m_history[(start + int(i)) % size], metric);
            out.append(sum / count);
        } else {
            out.append(sampleMetric(m_history[(start + int(b0)) % size], metric));
        }
    }
    return out;
}

QVector<qint64> StatsWorker::getProgramPids()
{
    QVector<qint64> pids;
    qint64 selfPid = getpid();
    pids.append(selfPid);

    uid_t myUid = getuid();
    QString selfExe = QFile::symLinkTarget(QString("/proc/%1/exe").arg(selfPid));

    struct ProcessInfo {
        qint64 pid;
        qint64 ppid;
        uid_t uid;
        QString name;
        QString exePath;
    };
    QVector<ProcessInfo> allProcs;

    QDir procDir("/proc");
    QStringList entries = procDir.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &entry : entries) {
        bool ok = false;
        qint64 pid = entry.toLongLong(&ok);
        if (!ok || pid == selfPid) continue;

        ProcessInfo info;
        info.pid = pid;
        info.ppid = -1;
        info.uid = -1;

        QFile statusFile(QString("/proc/%1/status").arg(pid));
        if (statusFile.open(QIODevice::ReadOnly)) {
            QString content = QString::fromUtf8(statusFile.readAll());
            statusFile.close();
            QStringList lines = content.split('\n');
            for (const QString &line : lines) {
                if (line.startsWith("Uid:")) {
                    int colonIdx = line.indexOf(':');
                    if (colonIdx != -1) {
                        QString valStr = line.mid(colonIdx + 1).trimmed();
                        int firstWsIdx = -1;
                        for (int i = 0; i < valStr.length(); ++i) {
                            if (valStr[i].isSpace()) {
                                firstWsIdx = i;
                                break;
                            }
                        }
                        if (firstWsIdx != -1) {
                            valStr = valStr.left(firstWsIdx);
                        }
                        info.uid = valStr.toUInt();
                    }
                } else if (line.startsWith("PPid:")) {
                    int colonIdx = line.indexOf(':');
                    if (colonIdx != -1) {
                        QString valStr = line.mid(colonIdx + 1).trimmed();
                        int firstWsIdx = -1;
                        for (int i = 0; i < valStr.length(); ++i) {
                            if (valStr[i].isSpace()) {
                                firstWsIdx = i;
                                break;
                            }
                        }
                        if (firstWsIdx != -1) {
                            valStr = valStr.left(firstWsIdx);
                        }
                        info.ppid = valStr.toLongLong();
                    }
                }
            }
        }

        if (info.uid != myUid) continue;

        // check executable name via symlink first
        QString exePath = QFile::symLinkTarget(QString("/proc/%1/exe").arg(pid));
        info.exePath = exePath;
        info.name = QFileInfo(exePath).fileName();

        // fallback to cmdline
        if (info.name.isEmpty()) {
            QFile cmdFile(QString("/proc/%1/cmdline").arg(pid));
            if (cmdFile.open(QIODevice::ReadOnly)) {
                QByteArray cmdline = cmdFile.readAll();
                cmdFile.close();
                if (cmdline.contains("kvision") || cmdline.contains("cctv-viewer2") || cmdline.contains("cctv-viewer")) {
                    info.name = "kvision";
                }
            }
        }

        allProcs.append(info);
    }

    // Pass 1: Find all direct cctv-viewer processes or same executable instances
    for (const ProcessInfo &info : allProcs) {
        bool matches = false;
        if (!selfExe.isEmpty() && !info.exePath.isEmpty() && info.exePath == selfExe) {
            matches = true;
        } else if (info.name == "kvision" || info.name == "cctv-viewer2" || info.name == "cctv-viewer") {
            matches = true;
        }

        if (matches) {
            if (!pids.contains(info.pid)) {
                pids.append(info.pid);
            }
        }
    }

    // Pass 2: Iteratively add all child processes of any PID currently in our pids list
    bool addedAny = true;
    while (addedAny) {
        addedAny = false;
        for (const ProcessInfo &info : allProcs) {
            if (!pids.contains(info.pid) && pids.contains(info.ppid)) {
                pids.append(info.pid);
                addedAny = true;
            }
        }
    }

    return pids;
}

void StatsWorker::calculateCpuAndRam(const QVector<qint64> &pids, double &cpu, double &ram, int &busiestCorePct)
{
    qint64 totalCpuTime = 0;
    qint64 processCpuTimeSum = 0;
    double ramUsageSum = 0.0;
    QHash<qint64, qint64> currentProcessCpuTimes;

    // 1. Read the system CPU times: the first "cpu " line is the whole machine,
    //    and the "cpu0", "cpu1"... lines after it give each core, so the panel
    //    can also show the busiest one.
    int busiestCorePctLocal = 0;
    QHash<int, qint64> coreBusyNow, coreTotalNow;
    QFile statFile("/proc/stat");
    if (statFile.open(QIODevice::ReadOnly)) {
        QTextStream stream(&statFile);
        // /proc files report a size of zero, so atEnd() would say "end" before
        // a single line was read; a null readLine() is the real end.
        while (true) {
            const QString line = stream.readLine();
            if (line.isNull())
                break;
            if (line.startsWith("cpu ")) {
                QString valStr = line.mid(4).trimmed();
#if QT_VERSION >= QT_VERSION_CHECK(5, 14, 0)
                QStringList parts = valStr.split(QChar(' '), Qt::SkipEmptyParts);
#else
                QStringList parts = valStr.split(QChar(' '), QString::SkipEmptyParts);
#endif
                for (int i = 0; i < parts.size() && i < 8; ++i) { // sum user to dirty/steal
                    totalCpuTime += parts[i].toLongLong();
                }
            } else if (line.startsWith("cpu")) {
                // "cpu0 user nice system idle iowait irq softirq steal ..."
#if QT_VERSION >= QT_VERSION_CHECK(5, 14, 0)
                QStringList fields = line.split(QChar(' '), Qt::SkipEmptyParts);
#else
                QStringList fields = line.split(QChar(' '), QString::SkipEmptyParts);
#endif
                bool coreOk = false;
                const int core = fields.value(0).mid(3).toInt(&coreOk);
                if (coreOk && fields.size() >= 5) {
                    qint64 coreTotal = 0;
                    for (int i = 1; i < fields.size() && i < 9; ++i)
                        coreTotal += fields[i].toLongLong();
                    // idle is field 4 and iowait is field 5 (iowait missing reads as 0)
                    const qint64 coreIdle = fields.value(4).toLongLong() + fields.value(5).toLongLong();
                    coreTotalNow[core] = coreTotal;
                    coreBusyNow[core] = coreTotal - coreIdle;
                }
            }
        }
        statFile.close();
    }

    // 2. Read process CPU times and RSS
    for (qint64 pid : pids) {
        // Read /proc/<pid>/stat
        QFile pStatFile(QString("/proc/%1/stat").arg(pid));
        if (pStatFile.open(QIODevice::ReadOnly)) {
            QTextStream stream(&pStatFile);
            QString content = stream.readAll();
            pStatFile.close();

            QStringList parts = content.split(' ');
            if (parts.size() > 17) {
                // utime=14, stime=15, cutime=16, cstime=17 (0-based: 13, 14, 15, 16)
                qint64 utime = parts[13].toLongLong();
                qint64 stime = parts[14].toLongLong();
                qint64 cutime = parts[15].toLongLong();
                qint64 cstime = parts[16].toLongLong();
                qint64 procTime = utime + stime + cutime + cstime;
                currentProcessCpuTimes[pid] = procTime;

                if (m_prevProcessCpuTimes.contains(pid)) {
                    processCpuTimeSum += (procTime - m_prevProcessCpuTimes[pid]);
                }
            }
        }

        // Read /proc/<pid>/status for RAM (VmRSS)
        QFile pStatusFile(QString("/proc/%1/status").arg(pid));
        if (pStatusFile.open(QIODevice::ReadOnly)) {
            QString content = QString::fromUtf8(pStatusFile.readAll());
            pStatusFile.close();
            QStringList lines = content.split('\n');
            for (const QString &line : lines) {
                if (line.startsWith("VmRSS:")) {
                    int colonIdx = line.indexOf(':');
                    if (colonIdx != -1) {
                        QString valStr = line.mid(colonIdx + 1).trimmed();
                        int spaceIdx = valStr.indexOf(' ');
                        if (spaceIdx != -1) {
                            valStr = valStr.left(spaceIdx);
                        }
                        ramUsageSum += valStr.toDouble() / 1024.0; // convert kB to MB
                    }
                }
            }
        }
    }

    // Calculate CPU %
    if (m_prevTotalCpuTime > 0 && totalCpuTime > m_prevTotalCpuTime) {
        qint64 sysDelta = totalCpuTime - m_prevTotalCpuTime;
        cpu = (static_cast<double>(processCpuTimeSum) / sysDelta) * 100.0;
        if (cpu < 0.0) cpu = 0.0;
        if (cpu > 100.0) cpu = 100.0;
    } else {
        cpu = 0.0;
    }

    // The busiest core of the machine, this tick against the previous one.
    if (!coreTotalNow.isEmpty()) {
        for (auto it = coreTotalNow.constBegin(); it != coreTotalNow.constEnd(); ++it) {
            const int core = it.key();
            if (!m_prevCoreTotal.contains(core))
                continue;
            const qint64 dTotal = it.value() - m_prevCoreTotal[core];
            if (dTotal <= 0)
                continue;
            const qint64 dBusy = coreBusyNow[core] - m_prevCoreBusy[core];
            const int pct = int((qMax<qint64>(0, dBusy) * 100.0 + dTotal / 2) / dTotal);
            busiestCorePctLocal = qMax(busiestCorePctLocal, qMin(100, pct));
        }
    }
    m_prevCoreTotal = coreTotalNow;
    m_prevCoreBusy = coreBusyNow;

    m_prevTotalCpuTime = totalCpuTime;
    m_prevProcessCpuTimes = currentProcessCpuTimes;
    ram = ramUsageSum;
    busiestCorePct = busiestCorePctLocal;
}

void StatsWorker::calculateGpuAndVram(const QVector<qint64> &pids, double &gpu, double &vram, double &dec)
{
    gpu = 0.0;
    vram = 0.0;
    dec = 0.0;

    qint64 selfPid = getpid();
    uid_t myUid = getuid();
    QString shmDir = "/dev/shm";
    if (!QDir(shmDir).exists() || !QFileInfo(shmDir).isWritable()) {
        shmDir = QDir::tempPath();
    }

    // Step A: Calculate OWN GPU and VRAM (and the decode-engine load, where NVML offers it)
    double ownGpu = 0.0;
    double ownVram = 0.0;
    double ownDec = 0.0;

    // 1. Try Nvidia NVML first for selfPid
    if (m_nvml && m_nvml->ensureInitialized()) {
        unsigned int devCount = 0;
        if (m_nvml->nvmlDeviceGetCount(&devCount) == NVML_SUCCESS && devCount > 0) {
            double vramSum = 0.0;
            double gpuSum = 0.0;
            double decSum = 0.0;
            bool processGpuSuccess = false;

            for (unsigned int i = 0; i < devCount; ++i) {
                nvmlDevice_t device = nullptr;
                if (m_nvml->nvmlDeviceGetHandleByIndex(i, &device) != NVML_SUCCESS) continue;

                // Sum process memory (VRAM)
                unsigned int procCount = 128;
                nvmlProcessInfo_t procInfos[128];
                
                // Graphics processes
                if (m_nvml->nvmlDeviceGetGraphicsRunningProcesses(device, &procCount, procInfos) == NVML_SUCCESS) {
                    for (unsigned int p = 0; p < procCount; ++p) {
                        if (procInfos[p].pid == static_cast<unsigned int>(selfPid) &&
                            procInfos[p].usedGpuMemory != ~0ULL &&
                            procInfos[p].usedGpuMemory < (1ULL << 44)) {
                            vramSum += procInfos[p].usedGpuMemory / (1024.0 * 1024.0); // B to MiB
                        }
                    }
                }
                
                // Compute processes
                procCount = 128;
                if (m_nvml->nvmlDeviceGetComputeRunningProcesses(device, &procCount, procInfos) == NVML_SUCCESS) {
                    for (unsigned int p = 0; p < procCount; ++p) {
                        if (procInfos[p].pid == static_cast<unsigned int>(selfPid) &&
                            procInfos[p].usedGpuMemory != ~0ULL &&
                            procInfos[p].usedGpuMemory < (1ULL << 44)) {
                            vramSum += procInfos[p].usedGpuMemory / (1024.0 * 1024.0); // B to MiB
                        }
                    }
                }

                // Process specific GPU utilization
                if (m_nvml->nvmlDeviceGetProcessUtilization) {
                    unsigned int sampleCount = 128;
                    nvmlProcessUtilizationSample_t samples[128];
                    if (m_nvml->nvmlDeviceGetProcessUtilization(device, samples, &sampleCount, 0) == NVML_SUCCESS) {
                        double devGpuSum = 0.0;
                        double devDecSum = 0.0;
                        int selfSamplesCount = 0;
                        for (unsigned int s = 0; s < sampleCount; ++s) {
                            if (samples[s].pid == static_cast<unsigned int>(selfPid)) {
                                devGpuSum += samples[s].smUtil + samples[s].decUtil + samples[s].encUtil; // Combined GPU % (SM + Decoder + Encoder)
                                devDecSum += samples[s].decUtil; // keeping the decoder's share for its own reading
                                selfSamplesCount++;
                                processGpuSuccess = true;
                            }
                        }
                        if (selfSamplesCount > 0) {
                            gpuSum += (devGpuSum / selfSamplesCount);
                            decSum += (devDecSum / selfSamplesCount);
                        }
                    }
                }
            }

            ownVram = vramSum;
            ownDec = decSum;
            if (ownDec > 100.0) ownDec = 100.0;

            if (processGpuSuccess) {
                ownGpu = gpuSum;
                if (ownGpu > 100.0) ownGpu = 100.0;
            }
        }
    }

    // 2. Try DRM Client Stats (for AMD, Intel, and fallback Nvidia) for selfPid
    if (ownGpu <= 0.0) {
        qint64 totalEngineDeltaNs = 0;
        bool hasDrmClients = false;
        // The same DRM client appears behind several open file descriptors with the
        // same counters, and each engine has its own key. Adding everything up counts
        // a client's load once per fd — a busy card pins itself to a flat 100% — so
        // per client keep the largest (freshest) reading of every engine, and add the
        // clients up.
        QHash<QString, QHash<QString, qint64>> clientEngineTimes;
        QHash<QString, double> clientVramMiB;

        QString fdInfoPath = QString("/proc/%1/fdinfo").arg(selfPid);
        QDir dir(fdInfoPath);
        if (dir.exists()) {
            QStringList files = dir.entryList(QDir::Files);
            for (const QString &fdName : files) {
                QFile f(dir.absoluteFilePath(fdName));
                if (!f.open(QIODevice::ReadOnly)) continue;

                QTextStream stream(&f);
                bool isDrm = false;
                QString clientId;
                QHash<QString, qint64> fdEngineTimes;
                double fdVramMiB = 0.0;

                // fdinfo lives under /proc, where files report a size of zero, so atEnd()
                // would say "end" before a single line was read; a null readLine() is
                // the real end. (This loop never ran at all before, which made the
                // AMD/Intel GPU reading always report zero.)
                while (true) {
                    const QString line = stream.readLine().trimmed();
                    if (line.isNull())
                        break;
                    const int colonIdx = line.indexOf(':');
                    if (colonIdx == -1)
                        continue;
                    const QString key = line.left(colonIdx).trimmed();
                    const QString valStr = line.mid(colonIdx + 1).trimmed();
                    const QString firstToken = valStr.section(QLatin1Char(' '), 0, 0);
                    const QString unit = valStr.section(QLatin1Char(' '), 1, 1).toLower();

                    if (key == QLatin1String("drm-driver")) {
                        isDrm = true;
                        hasDrmClients = true;
                    } else if (key == QLatin1String("drm-client-id")) {
                        clientId = firstToken;
                    } else if (key.startsWith(QLatin1String("drm-engine-"))
                               && !key.startsWith(QLatin1String("drm-engine-capacity"))) {
                        // drm-engine-render / -copy / -video / ... : cumulative busy time, ns.
                        // The drm-engine-capacity-* keys count engines, not time.
                        bool numOk = false;
                        const qint64 val = firstToken.toLongLong(&numOk);
                        if (numOk && val >= 0) {
                            const QString engine = key.mid(QStringLiteral("drm-engine-").size());
                            fdEngineTimes[engine] = qMax(fdEngineTimes.value(engine, 0), val);
                        }
                    } else if (key == QLatin1String("drm-memory-vram")
                               || key == QLatin1String("drm-total-system0")) {
                        // amdgpu calls its video memory "drm-memory-vram"; the Intel iGPU
                        // keeps its graphics buffers in system RAM ("drm-total-system0"),
                        // and showing that in the VRAM row is just as useful.
                        bool numOk = false;
                        const double val = firstToken.toDouble(&numOk);
                        if (numOk && val > 0.0) {
                            if (unit == QLatin1String("kib") || unit.isEmpty())
                                fdVramMiB += val / 1024.0;
                            else if (unit == QLatin1String("mib"))
                                fdVramMiB += val;
                            else if (unit == QLatin1String("gib"))
                                fdVramMiB += val * 1024.0;
                            else if (unit == QLatin1String("b"))
                                fdVramMiB += val / (1024.0 * 1024.0);
                        }
                    }
                }
                f.close();

                if (!isDrm)
                    continue;
                // A driver that does not name its clients: count each fd as a client.
                const QString client = clientId.isEmpty() ? (QLatin1String("fd:") + fdName)
                                                          : (QLatin1String("c:") + clientId);
                QHash<QString, qint64> &engines = clientEngineTimes[client];
                for (auto it = fdEngineTimes.cbegin(); it != fdEngineTimes.cend(); ++it)
                    engines[it.key()] = qMax(engines.value(it.key(), 0), it.value());
                double &vram = clientVramMiB[client];
                vram = qMax(vram, fdVramMiB);
            }
        }

        qint64 elapsedMs = m_gpuTimer.restart();
        if (elapsedMs <= 0) elapsedMs = 1000;
        const qint64 elapsedNs = elapsedMs * 1000 * 1000;

        QHash<QString, qint64> nextDrmEngineTimes;
        for (auto cit = clientEngineTimes.cbegin(); cit != clientEngineTimes.cend(); ++cit) {
            for (auto eit = cit.value().cbegin(); eit != cit.value().cend(); ++eit) {
                const QString prevKey = cit.key() + QLatin1Char('|') + eit.key();
                nextDrmEngineTimes[prevKey] = eit.value();
                if (m_prevDrmEngineTimes.contains(prevKey)) {
                    const qint64 delta = eit.value() - m_prevDrmEngineTimes.value(prevKey);
                    // A counter starts over with a new client id; only honest ticks add up.
                    if (delta > 0 && delta <= elapsedNs + elapsedNs / 2)
                        totalEngineDeltaNs += delta;
                }
            }
        }

        m_prevDrmEngineTimes = nextDrmEngineTimes;

        if (hasDrmClients) {
            double drmVramSum = 0.0;
            for (auto it = clientVramMiB.cbegin(); it != clientVramMiB.cend(); ++it)
                drmVramSum += it.value();
            if (ownVram <= 0.0) {
                ownVram = drmVramSum;
            }

            double drmGpu = 0.0;
            if (totalEngineDeltaNs > 0) {
                drmGpu = (static_cast<double>(totalEngineDeltaNs) / (elapsedMs * 1000000.0)) * 100.0;
                if (drmGpu > 100.0) drmGpu = 100.0;
            }
            ownGpu = drmGpu;
        }
    }

    // 3. Try System-wide NVML Fallback (if we are Nvidia but have no process stats)
    if (ownGpu <= 0.0 && m_nvml && m_nvml->initialized) {
        unsigned int devCount = 0;
        if (m_nvml->nvmlDeviceGetCount(&devCount) == NVML_SUCCESS && devCount > 0) {
            nvmlDevice_t device = nullptr;
            if (m_nvml->nvmlDeviceGetHandleByIndex(0, &device) == NVML_SUCCESS) {
                nvmlUtilization_t utilization;
                if (m_nvml->nvmlDeviceGetUtilizationRates(device, &utilization) == NVML_SUCCESS) {
                    ownGpu = utilization.gpu;
                }
            }
        }
    }

    // 4. Try AMD/Intel System-wide sysfs fallback
    if (ownGpu <= 0.0) {
        QFile amdGpuBusy("/sys/class/drm/card0/device/gpu_busy_percent");
        if (amdGpuBusy.exists() && amdGpuBusy.open(QIODevice::ReadOnly)) {
            QTextStream stream(&amdGpuBusy);
            ownGpu = stream.readAll().trimmed().toDouble();
            amdGpuBusy.close();

            if (ownVram <= 0.0) {
                QFile amdVram("/sys/class/drm/card0/device/mem_info_vram_used");
                if (amdVram.exists() && amdVram.open(QIODevice::ReadOnly)) {
                    QTextStream vramStream(&amdVram);
                    ownVram = vramStream.readAll().trimmed().toDouble() / (1024.0 * 1024.0); // B to MiB
                    amdVram.close();
                }
            }
        }
    }

    // Step B: Write OWN GPU and VRAM to shared memory files (the GPU file also
    //         carries the decode-engine load, so all KVision windows can be summed)
    QString myGpuFile = QString("%1/kvision-gpu-%2-%3").arg(shmDir).arg(myUid).arg(selfPid);
    QFile fGpu(myGpuFile);
    if (fGpu.open(QIODevice::WriteOnly)) {
        QTextStream stream(&fGpu);
        stream << QString::number(ownGpu, 'f', 2) << ' ' << QString::number(ownDec, 'f', 2);
        fGpu.close();
    }

    QString myVramFile = QString("%1/kvision-vram-%2-%3").arg(shmDir).arg(myUid).arg(selfPid);
    QFile fVram(myVramFile);
    if (fVram.open(QIODevice::WriteOnly)) {
        QTextStream stream(&fVram);
        stream << QString::number(ownVram, 'f', 2);
        fVram.close();
    }

    // Step C: Sum GPU and VRAM of all active PIDs
    double totalGpu = 0.0;
    double totalVram = 0.0;
    double totalDec = 0.0;

    for (qint64 pid : pids) {
        if (pid == selfPid) {
            totalGpu += ownGpu;
            totalVram += ownVram;
            totalDec += ownDec;
        } else {
            QString otherGpuFile = QString("%1/kvision-gpu-%2-%3").arg(shmDir).arg(myUid).arg(pid);
            QFile fOtherGpu(otherGpuFile);
            if (fOtherGpu.open(QIODevice::ReadOnly)) {
                double otherGpu = 0.0;
                double otherDec = 0.0;
                QTextStream streamOther(&fOtherGpu);
                streamOther >> otherGpu >> otherDec;
                totalGpu += otherGpu;
                totalDec += otherDec; // an older build wrote one number only; this then reads 0
                fOtherGpu.close();
            }

            QString otherVramFile = QString("%1/kvision-vram-%2-%3").arg(shmDir).arg(myUid).arg(pid);
            QFile fOtherVram(otherVramFile);
            if (fOtherVram.open(QIODevice::ReadOnly)) {
                double otherVram = 0.0;
                QTextStream streamOther(&fOtherVram);
                streamOther >> otherVram;
                totalVram += otherVram;
                fOtherVram.close();
            }
        }
    }

    if (totalGpu > 100.0) totalGpu = 100.0;
    gpu = totalGpu;
    vram = totalVram;
    if (totalDec > 100.0) totalDec = 100.0;
    dec = totalDec;
}

void StatsWorker::calculateNetUsage(const QVector<qint64> &pids, double &net)
{
    qint64 diffBytes = g_networkBytesAccumulator.exchange(0, std::memory_order_relaxed);
    qint64 elapsedMs = m_netTimer.restart();
    if (elapsedMs <= 0) elapsedMs = 1000;

    // Convert to bits per second (bps)
    double bps = (static_cast<double>(diffBytes) * 8.0) / (elapsedMs / 1000.0);

    qint64 selfPid = getpid();
    uid_t myUid = getuid();

    // Determine secure shared memory directory
    QString shmDir = "/dev/shm";
    if (!QDir(shmDir).exists() || !QFileInfo(shmDir).isWritable()) {
        shmDir = QDir::tempPath();
    }

    // Write own network bps to shared file
    QString myNetFile = QString("%1/kvision-net-%2-%3").arg(shmDir).arg(myUid).arg(selfPid);
    QFile f(myNetFile);
    if (f.open(QIODevice::WriteOnly)) {
        QTextStream stream(&f);
        stream << QString::number(bps, 'f', 1);
        f.close();
    }

    // Sum network bps of all active pids
    double totalBps = 0.0;
    for (qint64 pid : pids) {
        if (pid == selfPid) {
            totalBps += bps;
        } else {
            QString otherNetFile = QString("%1/kvision-net-%2-%3").arg(shmDir).arg(myUid).arg(pid);
            QFile fOther(otherNetFile);
            if (fOther.open(QIODevice::ReadOnly)) {
                double otherBps = 0.0;
                QTextStream streamOther(&fOther);
                streamOther >> otherBps;
                totalBps += otherBps;
                fOther.close();
            }
        }
    }

    // Convert to Megabits per second (Mbps)
    net = totalBps / 1000000.0;

    // Clean up stale shared files of processes that are no longer running
    static int cleanTicks = 0;
    if (++cleanTicks >= 10) {
        cleanTicks = 0;
        QDir dir(shmDir);
        QString prefixNet = QString("kvision-net-%1-").arg(myUid);
        QString prefixGpu = QString("kvision-gpu-%1-").arg(myUid);
        QString prefixVram = QString("kvision-vram-%1-").arg(myUid);
        
        QStringList netFiles = dir.entryList(QStringList() << prefixNet + "*", QDir::Files);
        for (const QString &fileName : netFiles) {
            QString pidPart = fileName.mid(prefixNet.length());
            bool ok = false;
            qint64 pid = pidPart.toLongLong(&ok);
            if (ok && !pids.contains(pid) && pid != selfPid) {
                dir.remove(fileName);
            }
        }
        
        QStringList gpuFiles = dir.entryList(QStringList() << prefixGpu + "*", QDir::Files);
        for (const QString &fileName : gpuFiles) {
            QString pidPart = fileName.mid(prefixGpu.length());
            bool ok = false;
            qint64 pid = pidPart.toLongLong(&ok);
            if (ok && !pids.contains(pid) && pid != selfPid) {
                dir.remove(fileName);
            }
        }

        QStringList vramFiles = dir.entryList(QStringList() << prefixVram + "*", QDir::Files);
        for (const QString &fileName : vramFiles) {
            QString pidPart = fileName.mid(prefixVram.length());
            bool ok = false;
            qint64 pid = pidPart.toLongLong(&ok);
            if (ok && !pids.contains(pid) && pid != selfPid) {
                dir.remove(fileName);
            }
        }
    }
}
