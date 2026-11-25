#ifndef HIKVISIONPROBE_H
#define HIKVISIONPROBE_H

#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>
#include <QVariantMap>
#include <QVector>

class QUdpSocket;
class QNetworkInterface;
class QNetworkAddressEntry;

// LAN discovery of Hikvision devices with the SADP "Probe" protocol
// (UDP port 37020). A Probe is multicast on every active IPv4 interface, and
// also sent to each address of a small subnet, because some recorders answer
// only a packet addressed to them. The socket listens on 37020 as well: some
// cameras answer only there, not back to a random source port. The ProbeMatch
// replies are parsed. No credentials are involved.
class HikvisionProbe : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool scanning READ scanning NOTIFY scanningChanged)

public:
    explicit HikvisionProbe(QObject *parent = nullptr);
    ~HikvisionProbe() override;

    bool scanning() const { return m_scanning; }

    // Starts a scan; does nothing if one is already running.
    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();

signals:
    void scanningChanged();
    // Emitted once per distinct device. Keys: ip, name, serial, mac, kind
    // ("nvr" or "camera"), sdkPort, httpPort, activated, firmware, channels,
    // subnetMask, gateway, interfaceName, interfaceIp, sameSubnet.
    void deviceFound(const QVariantMap &device);
    // networks = interfaces the Probe was sent on, failed = those that could not be used.
    void scanFinished(int count, int networks, int failed);

private:
    struct Channel {
        QUdpSocket *socket = nullptr;
        QString name;
        quint32 ip = 0;
        quint32 mask = 0;
    };

    void addChannel(const QNetworkInterface &iface, const QNetworkAddressEntry &entry, const QByteArray &probe);
    void readPending(const Channel &channel);
    void finish();
    static QVariantMap parseProbeMatch(const QByteArray &xml);

    QVector<Channel> m_channels;
    QSet<QString> m_seen;
    QTimer m_timer;
    QString m_uuid;
    bool m_scanning = false;
    int m_count = 0;
    int m_failed = 0;
};

#endif // HIKVISIONPROBE_H
