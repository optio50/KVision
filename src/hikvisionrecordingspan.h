#ifndef HIKVISIONRECORDINGSPAN_H
#define HIKVISIONRECORDINGSPAN_H

#include <QHash>
#include <QObject>
#include <QString>

class QThread;

// Remembers how far back each camera's recording goes on its recorder (or on the camera itself), so the detection log
// window can show which entries still have video to open. One small search per camera ("what is your oldest recording?"),
// run on a worker thread, and not repeated more often than every ten minutes. A camera that cannot be asked simply has
// no answer, and nothing is then marked as expired.
class HikvisionRecordingSpan : public QObject
{
    Q_OBJECT
    // Changes every time new answers arrive, so a QML binding that reads it asks again.
    Q_PROPERTY(int revision READ revision NOTIFY changed)

public:
    explicit HikvisionRecordingSpan(QObject *parent = nullptr);
    ~HikvisionRecordingSpan() override;

    int revision() const { return m_revision; }

    // Asks the recorders in the saved list, unless the last round finished less than ten minutes ago or one is running.
    Q_INVOKABLE void refresh(const QString &recordersJson);
    // Start of the oldest recording of that camera (ms since 1970), or 0 when unknown.
    Q_INVOKABLE qint64 oldestMs(const QString &recorderIp, int channel) const;

signals:
    void changed();

private:
    QHash<QString, qint64> m_oldest; // "recorderIp#channel" -> ms
    qint64 m_lastDoneMs = 0;
    int m_revision = 0;
    bool m_busy = false;
    QThread *m_worker = nullptr;
};

#endif // HIKVISIONRECORDINGSPAN_H
