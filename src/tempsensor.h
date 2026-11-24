#ifndef TEMPSENSOR_H
#define TEMPSENSOR_H

#include <QString>
#include <QVector>

// One hwmon temp*_input or thermal-zone temp the scanner already read.
// celsius is negative when the file could not be read. index is the hwmon
// temp number (temp1_input is 1); thermal zones use 1.
struct TempSensorReading {
    QString path;
    QString chip;   // hwmon "name", or the thermal zone type
    QString label;  // tempN_label; for a thermal zone, the type again
    bool thermalZone = false;
    int index = 0;
    double celsius = -1;
};

enum class TempSeriesKind { Cpu = 0, Gpu = 1, Disk = 2 };

// score 0 means the sensor is not a CPU package, a GPU, or a drive.
struct TempScore {
    TempSeriesKind kind = TempSeriesKind::Cpu;
    int score = 0;
    QString shortName;
};

struct TempSeriesChoice {
    TempSeriesKind kind = TempSeriesKind::Cpu;
    QString path;
    QString shortName; // "CPU", "Tctl", "GPU", "SSD", ...
    QString detail;    // "coretemp · Package id 0"
    double celsius = -1;
};

// Rank a single sensor. Higher scores are the ones a machine monitor should
// trust: Intel package, then AMD Tctl, then the kernel package zone, then a
// board CPU pin. Wi-Fi, batteries, and drive-controller side sensors are
// ignored. Individual cores lose to the package. NVMe composite beats the
// extra on-die sensors of the same drive.
inline TempScore scoreTempSensor(const TempSensorReading &r)
{
    TempScore out;
    const QString chip = r.chip.trimmed().toLower();
    const QString label = r.label.trimmed().toLower();
    if (chip.isEmpty() && label.isEmpty())
        return out;

    const bool ignoredChip = chip.startsWith(QLatin1String("iwlwifi"))
        || chip.startsWith(QLatin1String("mt76"))
        || chip.startsWith(QLatin1String("ath"))
        || chip.startsWith(QLatin1String("mac80211"))
        || chip.startsWith(QLatin1String("rtw"))
        || chip.contains(QLatin1String("battery"))
        || chip.startsWith(QLatin1String("hidpp"))
        || chip.startsWith(QLatin1String("ucsi"))
        || chip.contains(QLatin1String("psy"))
        || chip == QLatin1String("jc42")
        || chip == QLatin1String("spd5118")
        || chip.startsWith(QLatin1String("pch_"))
        || chip.contains(QLatin1String("int3400"))
        || chip == QLatin1String("tcpu_pci");
    if (ignoredChip || label.contains(QLatin1String("fan")))
        return out;

    auto set = [&](TempSeriesKind kind, int score, const char *name) {
        out.kind = kind;
        out.score = score;
        out.shortName = QString::fromLatin1(name);
    };

    const bool gpuChip = chip == QLatin1String("amdgpu") || chip == QLatin1String("radeon")
        || chip == QLatin1String("nouveau") || chip == QLatin1String("nvidia")
        || chip == QLatin1String("i915") || chip == QLatin1String("xe");
    if (gpuChip) {
        if (label.contains(QLatin1String("junction")) || label.contains(QLatin1String("hotspot")))
            set(TempSeriesKind::Gpu, 100, "GPU");
        else if (label.contains(QLatin1String("mem")))
            set(TempSeriesKind::Gpu, 20, "GPU");
        else
            set(TempSeriesKind::Gpu, 82, "GPU");
        return out;
    }

    if (chip == QLatin1String("nvme") || chip.startsWith(QLatin1String("nvme"))) {
        if (label.contains(QLatin1String("sensor 2")) || label.contains(QLatin1String("sensor2"))
            || r.index > 1)
            set(TempSeriesKind::Disk, 55, "SSD");
        else
            set(TempSeriesKind::Disk, 80, "SSD");
        return out;
    }
    if (chip == QLatin1String("drivetemp")) {
        set(TempSeriesKind::Disk, 80, "Disk");
        return out;
    }

    if (label.startsWith(QLatin1String("package id")) || label.startsWith(QLatin1String("physical id"))) {
        set(TempSeriesKind::Cpu, 100, "CPU");
        return out;
    }
    if (label == QLatin1String("tctl")) {
        set(TempSeriesKind::Cpu, 92, "Tctl");
        return out;
    }
    if (label == QLatin1String("tdie")) {
        set(TempSeriesKind::Cpu, 90, "Tdie");
        return out;
    }
    if (label.startsWith(QLatin1String("tccd"))) {
        set(TempSeriesKind::Cpu, 50, "CPU");
        return out;
    }
    if (label == QLatin1String("cpu") || label == QLatin1String("cputin")
        || label == QLatin1String("cpu temperature") || label == QLatin1String("cpu temp")
        || label.startsWith(QLatin1String("peci"))) {
        set(TempSeriesKind::Cpu, 80, "CPU");
        return out;
    }
    if (label.startsWith(QLatin1String("core "))) {
        set(TempSeriesKind::Cpu, 40, "Core");
        return out;
    }

    const bool cpuChip = chip == QLatin1String("coretemp") || chip == QLatin1String("k10temp")
        || chip == QLatin1String("k8temp") || chip == QLatin1String("zenpower")
        || chip == QLatin1String("cpu_thermal") || chip == QLatin1String("cpu-thermal");
    // Unlabeled temp1 on these chips is the package / Tctl. Later indexes are
    // per-core or per-CCD and must not beat that when the labels are missing.
    if (cpuChip && label.isEmpty() && r.index <= 1) {
        set(TempSeriesKind::Cpu, 88, "CPU");
        return out;
    }

    if (r.thermalZone || cpuChip) {
        if (chip.contains(QLatin1String("pkg"))) {
            set(TempSeriesKind::Cpu, 93, "CPU");
            return out;
        }
        if (chip == QLatin1String("tcpu")) {
            set(TempSeriesKind::Cpu, 72, "CPU");
            return out;
        }
        if (chip.contains(QLatin1String("cpu"))) {
            set(TempSeriesKind::Cpu, 70, "CPU");
            return out;
        }
        if (chip.contains(QLatin1String("soc"))) {
            set(TempSeriesKind::Cpu, 65, "CPU");
            return out;
        }
        if (chip == QLatin1String("acpitz")) {
            set(TempSeriesKind::Cpu, 12, "Board");
            return out;
        }
    }

    if (chip == QLatin1String("acpitz"))
        set(TempSeriesKind::Cpu, 12, "Board");
    return out;
}

inline QString tempSensorDetail(const TempSensorReading &r)
{
    const QString chip = r.chip.trimmed();
    const QString label = r.label.trimmed();
    if (r.thermalZone || label.isEmpty() || label.compare(chip, Qt::CaseInsensitive) == 0)
        return chip;
    return chip + QStringLiteral(" · ") + label;
}

// At most one CPU, one GPU, and one disk. A higher score always wins. The same
// score prefers a sensor more than 2°C hotter, and otherwise the path that
// sorts first, so two similar drives do not trade places every sample.
inline QVector<TempSeriesChoice> chooseTempSeries(const QVector<TempSensorReading> &found)
{
    TempSeriesChoice best[3];
    int bestScore[3] = {0, 0, 0};
    bool have[3] = {false, false, false};

    for (const TempSensorReading &r : found) {
        if (r.path.isEmpty() || r.celsius < 1.0 || r.celsius > 140.0)
            continue;
        const TempScore scored = scoreTempSensor(r);
        if (scored.score <= 0)
            continue;
        const int k = static_cast<int>(scored.kind);
        bool better = !have[k] || scored.score > bestScore[k];
        if (!better && scored.score == bestScore[k]) {
            if (r.celsius > best[k].celsius + 2.0)
                better = true;
            else if (!(best[k].celsius > r.celsius + 2.0) && r.path < best[k].path)
                better = true;
        }
        if (!better)
            continue;
        have[k] = true;
        bestScore[k] = scored.score;
        best[k].kind = scored.kind;
        best[k].path = r.path;
        best[k].shortName = scored.shortName;
        best[k].detail = tempSensorDetail(r);
        best[k].celsius = r.celsius;
    }

    QVector<TempSeriesChoice> out;
    for (int k = 0; k < 3; ++k) {
        if (have[k])
            out.append(best[k]);
    }
    return out;
}

#endif // TEMPSENSOR_H
