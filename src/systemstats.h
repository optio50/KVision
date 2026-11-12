#ifndef SYSTEMSTATS_H
#define SYSTEMSTATS_H

#include <QObject>
#include <QTimer>
#include <QVector>
#include <QHash>
#include <atomic>
#include <QElapsedTimer>
#include <QThread>
#include <QVariant>

// One point of the rolling history the statistics panel keeps. The worker
// delivers roughly one a second; the ring below keeps the last
// historyMinutes minutes of them, so the panel can be opened with a past
// instead of starting from zero.
struct StatsSample {
    qint64 timestampMs = 0;
    double cpu = 0.0;   // per cent
    double ram = 0.0;   // MiB
    double gpu = 0.0;   // per cent
    double vram = 0.0;  // MiB
    double net = 0.0;   // Mbps
    double gpuDec = 0.0;          // per cent, the GPU's decode engine (NVIDIA only; 0 when unavailable)
    int busiestCore = 0;          // per cent, the machine's busiest CPU core (0 while unknown)
    int rtspStreams = 0;          // FFmpeg (QmlAV) streams currently open
    int sdkStreams = 0;           // Hikvision SDK play sessions currently open
    double dropsPerSecond = 0.0;  // frames thrown away this tick because a decoder queue was full
    double errorsPerSecond = 0.0; // demux or decode failures this tick
};
Q_DECLARE_METATYPE(StatsSample)

class StatsWorker : public QObject
{
    Q_OBJECT
public:
    explicit StatsWorker(QObject *parent = nullptr);
    ~StatsWorker() override;

    void setUiActive(bool active) { m_uiActive.store(active, std::memory_order_relaxed); }

public slots:
    void doWork();
    void emitLatest();

signals:
    void workDone(const StatsSample &sample);

private:
    QVector<qint64> getProgramPids();
    void calculateCpuAndRam(const QVector<qint64> &pids, double &cpu, double &ram, int &busiestCorePct);
    void calculateGpuAndVram(const QVector<qint64> &pids, double &gpu, double &vram, double &dec);
    void calculateNetUsage(const QVector<qint64> &pids, double &net);

    struct NvmlContext;
    NvmlContext *m_nvml = nullptr;

    QHash<QString, qint64> m_prevDrmEngineTimes;
    QElapsedTimer m_gpuTimer;

    qint64 m_prevTotalCpuTime = 0;
    QHash<qint64, qint64> m_prevProcessCpuTimes;
    QHash<int, qint64> m_prevCoreTotal;  // per-core machine totals from /proc/stat, for the busiest-core reading
    QHash<int, qint64> m_prevCoreBusy;
    QElapsedTimer m_netTimer;

    QVector<qint64> m_cachedPids;
    int m_pidCacheTicks = 0;

    StatsSample m_lastSample;
    qint64 m_lastDropsTotal = 0;   // the drop and error counters only ever grow; the samples carry
    qint64 m_lastErrorsTotal = 0;  // only what appeared since the previous tick

    std::atomic<bool> m_uiActive{false};
};

class SystemStats : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(double cpuUsage READ cpuUsage NOTIFY statsChanged)
    Q_PROPERTY(double gpuUsage READ gpuUsage NOTIFY statsChanged)
    Q_PROPERTY(double ramUsage READ ramUsage NOTIFY statsChanged)
    Q_PROPERTY(double vramUsage READ vramUsage NOTIFY statsChanged)
    Q_PROPERTY(double netUsage READ netUsage NOTIFY statsChanged)
    Q_PROPERTY(int historyMinutes READ historyMinutes WRITE setHistoryMinutes NOTIFY historyMinutesChanged)
    Q_PROPERTY(double gpuDecodeUsage READ gpuDecodeUsage NOTIFY statsChanged)
    Q_PROPERTY(int busiestCoreUsage READ busiestCoreUsage NOTIFY statsChanged)
    Q_PROPERTY(int rtspStreams READ rtspStreams NOTIFY statsChanged)
    Q_PROPERTY(int sdkStreams READ sdkStreams NOTIFY statsChanged)
    Q_PROPERTY(qint64 decDropsTotal READ decDropsTotal NOTIFY statsChanged)
    Q_PROPERTY(qint64 decErrorsTotal READ decErrorsTotal NOTIFY statsChanged)

public:
    explicit SystemStats(QObject *parent = nullptr);
    ~SystemStats() override;

    double cpuUsage() const { return m_cpuUsage; }
    double gpuUsage() const { return m_gpuUsage; }
    double ramUsage() const { return m_ramUsage; }
    double vramUsage() const { return m_vramUsage; }
    double netUsage() const { return m_netUsage; }

    int historyMinutes() const { return m_historyMinutes; }
    void setHistoryMinutes(int minutes);

    // The kept history, oldest sample first, decimated down to maxPoints by
    // averaging bins, so a whole window fits the charts' fixed slot count.
    Q_INVOKABLE QVariantList historySnapshot(const QString &metric, int maxPoints) const;

    double gpuDecodeUsage() const { return m_gpuDecodeUsage; }
    int busiestCoreUsage() const { return m_busiestCoreUsage; }
    int rtspStreams() const { return m_rtspStreams; }
    int sdkStreams() const { return m_sdkStreams; }
    qint64 decDropsTotal() const { return m_decDropsTotal; }
    qint64 decErrorsTotal() const { return m_decErrorsTotal; }

    bool active() const;
    void setActive(bool active);

signals:
    void activeChanged();
    void statsChanged();
    void historyMinutesChanged();

private slots:
    void onWorkDone(const StatsSample &sample);

private:
    void appendHistory(const StatsSample &sample);

    double m_cpuUsage = 0.0;
    double m_gpuUsage = 0.0;
    double m_ramUsage = 0.0;
    double m_vramUsage = 0.0;
    double m_netUsage = 0.0;
    double m_gpuDecodeUsage = 0.0;
    int m_busiestCoreUsage = 0;
    int m_rtspStreams = 0;
    int m_sdkStreams = 0;
    qint64 m_decDropsTotal = 0;   // since KVision started, for the panel's counter; the ring keeps per-tick rates
    qint64 m_decErrorsTotal = 0;
    bool m_active = false;

    // The rolling window of collected samples (see StatsSample).
    int m_historyMinutes = 0;
    QVector<StatsSample> m_history; // ring; one slot per second of the chosen window
    int m_historyHead = 0;          // where the next sample is written
    int m_historyCount = 0;         // kept samples; grows up to the ring's size

    QTimer *m_timer;
    QThread *m_workerThread;
    StatsWorker *m_worker;
};

#endif // SYSTEMSTATS_H
