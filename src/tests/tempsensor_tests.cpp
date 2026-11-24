#include "tempsensor.h"

#include <gtest/gtest.h>

namespace {

TempSensorReading reading(const char *path, const char *chip, const char *label, double celsius,
                           int index = 1, bool thermalZone = false)
{
    TempSensorReading r;
    r.path = QString::fromLatin1(path);
    r.chip = QString::fromLatin1(chip);
    r.label = QString::fromLatin1(label);
    r.celsius = celsius;
    r.index = index;
    r.thermalZone = thermalZone;
    return r;
}

const TempSeriesChoice *findKind(const QVector<TempSeriesChoice> &chosen, TempSeriesKind kind)
{
    for (const TempSeriesChoice &c : chosen) {
        if (c.kind == kind)
            return &c;
    }
    return nullptr;
}

} // namespace

// The NUC this runs on publishes the package, a second kernel package zone,
// a board zone, a dummy ACPI zone, the NVMe, and the Wi-Fi card. The graph
// should follow Package id 0 and the NVMe, and nothing else.
TEST(TempSensor, IntelPackageBeatsBoardZonesCoresAndWifi)
{
    const QVector<TempSeriesChoice> chosen = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon6/temp1_input", "coretemp", "Package id 0", 102, 1),
        reading("/sys/class/hwmon/hwmon6/temp2_input", "coretemp", "Core 0", 99, 2),
        reading("/sys/class/thermal/thermal_zone6/temp", "x86_pkg_temp", "x86_pkg_temp", 98, 1, true),
        reading("/sys/class/thermal/thermal_zone3/temp", "TCPU", "TCPU", 100, 1, true),
        reading("/sys/class/thermal/thermal_zone4/temp", "TCPU_PCI", "TCPU_PCI", 101, 1, true),
        reading("/sys/class/thermal/thermal_zone0/temp", "acpitz", "acpitz", 40, 1, true),
        reading("/sys/class/thermal/thermal_zone1/temp", "acpitz", "acpitz", 100, 1, true),
        reading("/sys/class/hwmon/hwmon2/temp1_input", "nvme", "Composite", 40, 1),
        reading("/sys/class/hwmon/hwmon5/temp1_input", "iwlwifi_1", "", 84, 1),
    });

    ASSERT_EQ(chosen.size(), 2);
    const TempSeriesChoice *cpu = findKind(chosen, TempSeriesKind::Cpu);
    const TempSeriesChoice *disk = findKind(chosen, TempSeriesKind::Disk);
    ASSERT_NE(cpu, nullptr);
    ASSERT_NE(disk, nullptr);
    EXPECT_EQ(cpu->path.toStdString(), "/sys/class/hwmon/hwmon6/temp1_input");
    EXPECT_EQ(cpu->shortName.toStdString(), "CPU");
    EXPECT_EQ(cpu->detail.toStdString(), "coretemp · Package id 0");
    EXPECT_EQ(disk->shortName.toStdString(), "SSD");
    EXPECT_EQ(findKind(chosen, TempSeriesKind::Gpu), nullptr);
}

TEST(TempSensor, AmdUsesTctlAndGpuJunction)
{
    const QVector<TempSeriesChoice> chosen = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon0/temp1_input", "k10temp", "Tctl", 70, 1),
        reading("/sys/class/hwmon/hwmon0/temp2_input", "k10temp", "Tdie", 75, 2),
        reading("/sys/class/hwmon/hwmon0/temp3_input", "k10temp", "Tccd1", 80, 3),
        reading("/sys/class/hwmon/hwmon1/temp1_input", "amdgpu", "edge", 60, 1),
        reading("/sys/class/hwmon/hwmon1/temp2_input", "amdgpu", "junction", 90, 2),
        reading("/sys/class/hwmon/hwmon2/temp1_input", "nvme", "Composite", 32, 1),
    });

    const TempSeriesChoice *cpu = findKind(chosen, TempSeriesKind::Cpu);
    const TempSeriesChoice *gpu = findKind(chosen, TempSeriesKind::Gpu);
    const TempSeriesChoice *disk = findKind(chosen, TempSeriesKind::Disk);
    ASSERT_NE(cpu, nullptr);
    ASSERT_NE(gpu, nullptr);
    ASSERT_NE(disk, nullptr);
    EXPECT_EQ(cpu->shortName.toStdString(), "Tctl");
    EXPECT_EQ(cpu->path.toStdString(), "/sys/class/hwmon/hwmon0/temp1_input");
    EXPECT_EQ(gpu->path.toStdString(), "/sys/class/hwmon/hwmon1/temp2_input");
    EXPECT_EQ(disk->shortName.toStdString(), "SSD");
}

TEST(TempSensor, UnlabeledAmdTemp1BeatsAHotterLaterSensor)
{
    const QVector<TempSeriesChoice> chosen = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon0/temp1_input", "k10temp", "", 55, 1),
        reading("/sys/class/hwmon/hwmon0/temp2_input", "k10temp", "", 90, 2),
    });

    ASSERT_EQ(chosen.size(), 1);
    EXPECT_EQ(chosen[0].path.toStdString(), "/sys/class/hwmon/hwmon0/temp1_input");
    EXPECT_EQ(chosen[0].shortName.toStdString(), "CPU");
}

TEST(TempSensor, HotterPackageWinsAndAClosePairStaysOnTheFirstPath)
{
    const QVector<TempSeriesChoice> hot = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon0/temp1_input", "coretemp", "Package id 0", 50, 1),
        reading("/sys/class/hwmon/hwmon1/temp1_input", "coretemp", "Package id 1", 88, 1),
    });
    ASSERT_EQ(hot.size(), 1);
    EXPECT_EQ(hot[0].path.toStdString(), "/sys/class/hwmon/hwmon1/temp1_input");

    const QVector<TempSeriesChoice> close = chooseTempSeries({
        reading("/sys/class/hwmon/hwmonB/temp1_input", "coretemp", "Package id 1", 70, 1),
        reading("/sys/class/hwmon/hwmonA/temp1_input", "coretemp", "Package id 0", 71, 1),
    });
    ASSERT_EQ(close.size(), 1);
    EXPECT_EQ(close[0].path.toStdString(), "/sys/class/hwmon/hwmonA/temp1_input");
}

TEST(TempSensor, AcpitzFallbackUsesTheHotterZone)
{
    const QVector<TempSeriesChoice> chosen = chooseTempSeries({
        reading("/sys/class/thermal/thermal_zone0/temp", "acpitz", "acpitz", 40, 1, true),
        reading("/sys/class/thermal/thermal_zone1/temp", "acpitz", "acpitz", 100, 1, true),
        reading("/sys/class/hwmon/hwmon5/temp1_input", "iwlwifi_1", "", 90, 1),
    });

    ASSERT_EQ(chosen.size(), 1);
    EXPECT_EQ(chosen[0].shortName.toStdString(), "Board");
    EXPECT_EQ(chosen[0].path.toStdString(), "/sys/class/thermal/thermal_zone1/temp");
}

TEST(TempSensor, HottestCoreIsUsedWhenThePackageIsMissing)
{
    const QVector<TempSeriesChoice> chosen = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon0/temp2_input", "coretemp", "Core 0", 40, 2),
        reading("/sys/class/hwmon/hwmon0/temp5_input", "coretemp", "Core 3", 88, 5),
    });

    ASSERT_EQ(chosen.size(), 1);
    EXPECT_EQ(chosen[0].shortName.toStdString(), "Core");
    EXPECT_EQ(chosen[0].path.toStdString(), "/sys/class/hwmon/hwmon0/temp5_input");
}

TEST(TempSensor, NvmeCompositeBeatsItsOwnHotterExtraSensor)
{
    const QVector<TempSeriesChoice> chosen = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon2/temp1_input", "nvme", "Composite", 40, 1),
        reading("/sys/class/hwmon/hwmon2/temp2_input", "nvme", "Sensor 2", 90, 2),
    });

    ASSERT_EQ(chosen.size(), 1);
    EXPECT_EQ(chosen[0].path.toStdString(), "/sys/class/hwmon/hwmon2/temp1_input");
    EXPECT_EQ(chosen[0].shortName.toStdString(), "SSD");
}

TEST(TempSensor, HotterDiskWinsAcrossDrives)
{
    const QVector<TempSeriesChoice> chosen = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon2/temp1_input", "nvme", "Composite", 32, 1),
        reading("/sys/class/hwmon/hwmon3/temp1_input", "drivetemp", "", 60, 1),
    });

    ASSERT_EQ(chosen.size(), 1);
    EXPECT_EQ(chosen[0].shortName.toStdString(), "Disk");
    EXPECT_EQ(chosen[0].path.toStdString(), "/sys/class/hwmon/hwmon3/temp1_input");
}

TEST(TempSensor, CpuThermalZoneAndBoardPinAreRecognized)
{
    const QVector<TempSeriesChoice> zone = chooseTempSeries({
        reading("/sys/class/thermal/thermal_zone0/temp", "cpu-thermal", "cpu-thermal", 62, 1, true),
    });
    ASSERT_EQ(zone.size(), 1);
    EXPECT_EQ(zone[0].shortName.toStdString(), "CPU");

    const QVector<TempSeriesChoice> pin = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon0/temp2_input", "nct6798", "CPUTIN", 58, 2),
        reading("/sys/class/hwmon/hwmon0/temp1_input", "nct6798", "SYSTIN", 40, 1),
    });
    ASSERT_EQ(pin.size(), 1);
    EXPECT_EQ(pin[0].shortName.toStdString(), "CPU");
    EXPECT_EQ(pin[0].path.toStdString(), "/sys/class/hwmon/hwmon0/temp2_input");
}

TEST(TempSensor, WifiAloneIsNotATemperature)
{
    const QVector<TempSeriesChoice> chosen = chooseTempSeries({
        reading("/sys/class/hwmon/hwmon5/temp1_input", "iwlwifi_1", "", 84, 1),
    });
    EXPECT_TRUE(chosen.isEmpty());
}
