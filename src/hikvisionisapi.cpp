#include "hikvisionisapi.h"
#include <QNetworkRequest>
#include <QUrl>
#include <QXmlStreamReader>
#include <QDebug>
#include <QThread>
#include <cstring>
#include "hikvisionmanager.h"

HikvisionISAPI::HikvisionISAPI(QObject *parent)
    : QObject(parent)
{
    m_netManager = new QNetworkAccessManager(this);
    connect(m_netManager, &QNetworkAccessManager::authenticationRequired,
            this, &HikvisionISAPI::onAuthenticationRequired);
}

void HikvisionISAPI::searchRecordings(const QVariantMap &recorderInfo, int channelId, const QDateTime &start, const QDateTime &end)
{
    QString sessionId = QUuid::createUuid().toString();
    HikvisionSearchSession session;
    session.recorderInfo = recorderInfo;
    session.channelId = channelId;
    session.startTime = start;
    session.endTime = end;
    session.isMonthSearch = false;
    session.currentPosition = 1;
    m_sessions[sessionId] = session;

    doSearchRequest(sessionId);
}

// What the recorder says a saved event was, for the colour on the timeline. Motion is its own group; the smart
// events carry a minor type (line crossing, field detection = intrusion, region entrance, region exit...).
static QString eventKind(WORD major, WORD minor)
{
    if (major == EVENT_MOT_DET)
        return QStringLiteral("motion");
    if (major == EVENT_VCA_DETECTION) {
        switch (minor) {
        case EVENT_VCA_TRAVERSE_PLANE: return QStringLiteral("line");
        case EVENT_FIELD_DETECTION: return QStringLiteral("intrusion");
        case EVENT_ENTER_REGION: return QStringLiteral("enter");
        case EVENT_EXIT_REGION: return QStringLiteral("exit");
        default: break;
        }
    }
    return QStringLiteral("other");
}

void HikvisionISAPI::searchEvents(const QVariantMap &recorderInfo, int channelId, const QDateTime &start, const QDateTime &end)
{
    HikvisionSearchSession session;
    session.recorderInfo = recorderInfo;
    session.channelId = channelId;
    session.startTime = start;
    session.endTime = end;
    session.isMonthSearch = false;

    QThread *worker = QThread::create([this, session]() {
        const QString ip = session.recorderInfo.value("ip").toString();
        const int port = session.recorderInfo.value("sdkPort").toInt() > 0
            ? session.recorderInfo.value("sdkPort").toInt()
            : session.recorderInfo.value("port").toInt();
        const QString username = session.recorderInfo.value("username").toString();
        const QString password = session.recorderInfo.value("password").toString();

        NET_DVR_DEVICEINFO_V40 deviceInfo;
        std::memset(&deviceInfo, 0, sizeof(deviceInfo));
        const LONG userId = HikvisionManager::instance()->loginShared(ip, port > 0 ? port : 8000, username, password, deviceInfo);
        QVariantList segments;
        if (userId >= 0) {
            int channel = session.channelId;
            const auto &info = deviceInfo.struDeviceV30;
            if (info.byChanNum == 0 && info.byIPChanNum > 0)
                channel = session.channelId + info.byStartDChan - 1;
            else if (info.byChanNum > 0 && session.channelId > info.byChanNum)
                channel = info.byStartDChan + (session.channelId - info.byChanNum) - 1;
            else if (info.byChanNum > 0)
                channel = session.channelId + info.byStartChan - 1;

            // Continuous files do not carry the red smart marks. Those live in the event log.
            const WORD majorTypes[] = {EVENT_MOT_DET, EVENT_VCA_DETECTION, EVENT_VCA_BEHAVIOR};
            for (WORD majorType : majorTypes) {
                NET_DVR_SEARCH_EVENT_PARAM_V40 param;
                std::memset(&param, 0, sizeof(param));
                param.wMajorType = majorType;
                param.wMinorType = 0xffff;
                param.byLockType = 0xff;
                fillSdkTime(param.struStartTime, session.startTime);
                fillSdkTime(param.struEndTime, session.endTime);
                if (majorType == EVENT_MOT_DET) {
                    param.uSeniorParam.struMotionParam.wMotDetChanNo[0] = static_cast<WORD>(channel);
                } else if (majorType == EVENT_VCA_BEHAVIOR) {
                    param.uSeniorParam.struVcaParam.wChanNo[0] = static_cast<WORD>(channel);
                    param.uSeniorParam.struVcaParam.byRuleID = 0xff;
                } else {
                    param.uSeniorParam.struVCADetect.wChanNo[0] = static_cast<WORD>(channel);
                }

                const LONG findHandle = NET_DVR_FindFileByEvent_V40(userId, &param);
                if (findHandle < 0) {
                    qDebug() << "[ISAPI] Event search failed for channel" << channel
                               << "major" << majorType << "error" << NET_DVR_GetLastError();
                    continue;
                }
                int accepted = 0;
                NET_DVR_SEARCH_EVENT_RET_V40 event;
                int guard = 0;
                while (guard++ < 4000) {
                    const LONG state = NET_DVR_FindNextEvent_V40(findHandle, &event);
                    if (state == 1000) {
                        const NET_DVR_TIME &rawStart = event.struStartTime;
                        const NET_DVR_TIME &rawEnd = event.struEndTime;
                        QDateTime eventStart(QDate(rawStart.dwYear, rawStart.dwMonth, rawStart.dwDay),
                                             QTime(rawStart.dwHour, rawStart.dwMinute, rawStart.dwSecond));
                        QDateTime eventEnd(QDate(rawEnd.dwYear, rawEnd.dwMonth, rawEnd.dwDay),
                                           QTime(rawEnd.dwHour, rawEnd.dwMinute, rawEnd.dwSecond));
                        if (!eventStart.isValid())
                            continue;
                        if (!eventEnd.isValid() || eventEnd <= eventStart)
                            eventEnd = eventStart.addSecs(10);
                        if (accepted < 5) {
                            qDebug() << "[ISAPI] Event channel" << channel
                                     << "major" << event.wMajorType << "minor" << event.wMinorType
                                     << eventStart.toString(Qt::ISODate) << eventEnd.toString(Qt::ISODate);
                        }
                        QVariantMap segment;
                        segment["startTime"] = eventStart.toMSecsSinceEpoch();
                        segment["endTime"] = eventEnd.toMSecsSinceEpoch();
                        segment["timeIsLocal"] = true;
                        segment["event"] = true;
                        segment["kind"] = eventKind(event.wMajorType, event.wMinorType);
                        segments.append(segment);
                        accepted++;
                    } else if (state == 1002) {
                        QThread::msleep(10);
                    } else {
                        break;
                    }
                }
                NET_DVR_FindClose_V30(findHandle);
                qDebug() << "[ISAPI] Event search channel" << channel << "major" << majorType << "accepted" << accepted;
            }
            qDebug() << "[ISAPI] Event search finished for channel" << channel << "events" << segments.count();
        }

        QMetaObject::invokeMethod(this, [this, session, segments]() {
            emit eventsFinished(session.recorderInfo.value("ip").toString(), session.channelId, session.startTime, segments);
        }, Qt::QueuedConnection);
    });
    connect(worker, &QThread::finished, worker, &QThread::deleteLater);
    worker->start();
}

void HikvisionISAPI::searchMonthAvailability(const QVariantMap &recorderInfo, int channelId, int year, int month)
{
    QString sessionId = QUuid::createUuid().toString();
    HikvisionSearchSession session;
    session.recorderInfo = recorderInfo;
    session.channelId = channelId;
    
    QDate firstDay(year, month, 1);
    QDate lastDay(year, month, firstDay.daysInMonth());
    
    session.startTime = QDateTime(firstDay, QTime(0, 0, 0), Qt::LocalTime);
    session.endTime = QDateTime(lastDay, QTime(23, 59, 59), Qt::LocalTime);
    session.isMonthSearch = true;
    session.year = year;
    session.month = month;
    session.currentPosition = 1;
    m_sessions[sessionId] = session;

    doSearchRequest(sessionId);
}

void HikvisionISAPI::doSearchRequest(const QString &sessionId)
{
    if (!m_sessions.contains(sessionId)) return;
    const HikvisionSearchSession &session = m_sessions[sessionId];

    QString ip = session.recorderInfo["ip"].toString();
    int port = session.recorderInfo.contains("httpPort") ? session.recorderInfo["httpPort"].toInt() : 80;
    if (port <= 0) port = 80; // fallback if invalid
    m_currentUser = session.recorderInfo["username"].toString();
    m_currentPassword = session.recorderInfo["password"].toString();

    QUrl url(QString("http://%1:%2/ISAPI/ContentMgmt/search").arg(ip).arg(port));
    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/xml");

    QString startTimeStr = session.startTime.toUTC().toString("yyyy-MM-ddThh:mm:ss") + "Z";
    QString endTimeStr = session.endTime.toUTC().toString("yyyy-MM-ddThh:mm:ss") + "Z";

    qDebug() << "[ISAPI] doSearchRequest session:" << sessionId
             << "channelId:" << session.channelId
             << "startTime (orig):" << session.startTime.toString(Qt::ISODate)
             << "startTime (local):" << session.startTime.toLocalTime().toString(Qt::ISODate)
             << "startTimeStr:" << startTimeStr
             << "endTimeStr:" << endTimeStr
             << "pos:" << session.currentPosition;

    QString xmlPayload = QString(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<CMSearchDescription xmlns=\"http://www.hikvision.com/ver20/XMLSchema\">\n"
        "  <searchID>%1</searchID>\n"
        "  <trackList>\n"
        "    <trackID>%2</trackID>\n"
        "  </trackList>\n"
        "  <timeSpanList>\n"
        "    <timeSpan>\n"
        "      <startTime>%3</startTime>\n"
        "      <endTime>%4</endTime>\n"
        "    </timeSpan>\n"
        "  </timeSpanList>\n"
        "  <maxResults>1000</maxResults>\n"
        "  <searchResultPostion>%5</searchResultPostion>\n"
        "  <metadataList>\n"
        "    <metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor>\n"
        "  </metadataList>\n"
        "</CMSearchDescription>\n"
    ).arg(sessionId).arg(session.channelId * 100 + 1).arg(startTimeStr).arg(endTimeStr).arg(session.currentPosition);

    QNetworkReply *reply = m_netManager->post(request, xmlPayload.toUtf8());
    reply->setProperty("sessionId", sessionId);
    reply->setProperty("username", m_currentUser);
    reply->setProperty("password", m_currentPassword);
    m_activeReplies[sessionId] = reply;
    connect(reply, &QNetworkReply::finished, this, &HikvisionISAPI::onReplyFinished);

    const bool standaloneCamera = session.channelId <= 1;
    if (standaloneCamera) {
        qWarning() << "[ISAPI] Standalone camera; using SDK recording search";
        startSdkSearch(sessionId);
        return;
    }
    QTimer::singleShot(8000, this, [this, sessionId]() {
        if (!m_sessions.contains(sessionId) || m_sessions[sessionId].sdkFallbackStarted)
            return;
        qWarning() << "[ISAPI] Search timed out; falling back to SDK recording search";
        if (m_activeReplies.contains(sessionId) && m_activeReplies[sessionId]) {
            m_activeReplies[sessionId]->abort();
        } else {
            startSdkSearch(sessionId);
        }
    });
}

void HikvisionISAPI::onAuthenticationRequired(QNetworkReply *reply, QAuthenticator *authenticator)
{
    if (reply) {
        QString user = reply->property("username").toString();
        QString pass = reply->property("password").toString();
        if (!user.isEmpty()) {
            authenticator->setUser(user);
            authenticator->setPassword(pass);
            return;
        }
    }
    authenticator->setUser(m_currentUser);
    authenticator->setPassword(m_currentPassword);
}

void HikvisionISAPI::onReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    QString sessionId = reply->property("sessionId").toString();
    m_activeReplies.remove(sessionId);
    reply->deleteLater();

    if (!m_sessions.contains(sessionId)) {
        return; // Session cancelled or already finished
    }
    
    HikvisionSearchSession &session = m_sessions[sessionId];
    QString recorderIp = session.recorderInfo["ip"].toString();

    if (reply->error() != QNetworkReply::NoError) {
        qWarning() << "[ISAPI] Search failed:" << reply->errorString();
        if (session.isMonthSearch) {
            QVariantList daysList;
            for (int d : session.accumulatedDays) daysList.append(d);
            emit monthAvailabilityFinished(recorderIp, session.channelId, session.year, session.month, daysList, false);
        } else {
            if (session.accumulatedSegments.count() > 0) {
                emit searchFinished(recorderIp, session.channelId, session.startTime, session.accumulatedSegments);
            } else {
                emit searchFailed(recorderIp, session.channelId, session.startTime, reply->errorString());
            }
        }
        if (!session.sdkFallbackStarted) {
            startSdkSearch(sessionId);
            return;
        }
        m_sessions.remove(sessionId);
        return;
    }

    QByteArray response = reply->readAll();
    QXmlStreamReader xml(response);

    bool inMatchList = false;
    bool inMatchItem = false;
    QString responseStatusStrg;
    
    QDateTime currentStart;
    QDateTime currentEnd;
    
    int matchItemsCount = 0;

    while (!xml.atEnd() && !xml.hasError()) {
        QXmlStreamReader::TokenType token = xml.readNext();

        if (token == QXmlStreamReader::StartElement) {
            QString name = xml.name().toString();
            if (name == "responseStatusStrg") {
                responseStatusStrg = xml.readElementText().trimmed();
            } else if (name == "matchList") {
                inMatchList = true;
            } else if (inMatchList && name == "searchMatchItem") {
                inMatchItem = true;
                matchItemsCount++;
            } else if (inMatchItem && name == "startTime") {
                QString val = xml.readElementText();
                currentStart = QDateTime::fromString(val, Qt::ISODate).toLocalTime();
            } else if (inMatchItem && name == "endTime") {
                QString val = xml.readElementText();
                currentEnd = QDateTime::fromString(val, Qt::ISODate).toLocalTime();
            }
        } else if (token == QXmlStreamReader::EndElement) {
            QString name = xml.name().toString();
            if (name == "matchList") {
                inMatchList = false;
            } else if (name == "searchMatchItem") {
                inMatchItem = false;
                if (currentStart.isValid() && currentEnd.isValid()) {
                    if (session.isMonthSearch) {
                        int day = currentStart.date().day();
                        if (!session.accumulatedDays.contains(day)) {
                            session.accumulatedDays.append(day);
                        }
                    } else {
                        QVariantMap segment;
                        segment["startTime"] = currentStart.toMSecsSinceEpoch();
                        segment["endTime"] = currentEnd.toMSecsSinceEpoch();
                        session.accumulatedSegments.append(segment);
                    }
                }
                currentStart = QDateTime();
                currentEnd = QDateTime();
            }
        }
    }

    if (xml.hasError()) {
        qWarning() << "[ISAPI] XML parsing error:" << xml.errorString();
        if (session.isMonthSearch) {
            QVariantList daysList;
            for (int d : session.accumulatedDays) daysList.append(d);
            emit monthAvailabilityFinished(recorderIp, session.channelId, session.year, session.month, daysList, false);
        } else {
            emit searchFailed(recorderIp, session.channelId, session.startTime, xml.errorString());
        }
        m_sessions.remove(sessionId);
        return;
    }

    if (matchItemsCount == 0) {
        // Done paginating
        if (session.isMonthSearch) {
            QVariantList daysList;
            for (int d : session.accumulatedDays) {
                daysList.append(d);
            }
            qDebug() << "[ISAPI] Month availability finished (no more matches) for channel:" << session.channelId << "days:" << daysList;
            emit monthAvailabilityFinished(recorderIp, session.channelId, session.year, session.month, daysList, true);
        } else {
            qDebug() << "[ISAPI] Day search finished (no more matches) for channel:" << session.channelId << "segments:" << session.accumulatedSegments.count();
            emit searchFinished(recorderIp, session.channelId, session.startTime, session.accumulatedSegments);
        }
        m_sessions.remove(sessionId);
        return;
    }

    // If responseStatusStrg is MORE, there are more pages (limit to 100000 results to avoid infinite loop)
    if (responseStatusStrg == "MORE" && session.currentPosition < 100000) {
        qDebug() << "[ISAPI] Session" << sessionId << "status MORE; paginating next page from:" << (session.currentPosition + matchItemsCount);
        session.currentPosition += matchItemsCount;
        doSearchRequest(sessionId); // Fetch next page
    } else {
        // Done paginating
        if (session.isMonthSearch) {
            QVariantList daysList;
            for (int d : session.accumulatedDays) {
                daysList.append(d);
            }
            qDebug() << "[ISAPI] Month availability finished for channel:" << session.channelId << "days:" << daysList;
            emit monthAvailabilityFinished(recorderIp, session.channelId, session.year, session.month, daysList, true);
        } else {
            qDebug() << "[ISAPI] Day search finished for channel:" << session.channelId << "segments:" << session.accumulatedSegments.count();
            emit searchFinished(recorderIp, session.channelId, session.startTime, session.accumulatedSegments);
        }
        m_sessions.remove(sessionId);
    }
}

void HikvisionISAPI::fillSdkTime(NET_DVR_TIME &out, const QDateTime &value)
{
    out.dwYear = value.date().year();
    out.dwMonth = value.date().month();
    out.dwDay = value.date().day();
    out.dwHour = value.time().hour();
    out.dwMinute = value.time().minute();
    out.dwSecond = value.time().second();
}

QDateTime HikvisionISAPI::fromSdkTime(const NET_DVR_TIME_SEARCH &value)
{
    return QDateTime(QDate(value.wYear, value.byMonth, value.byDay),
                     QTime(value.byHour, value.byMinute, value.bySecond));
}

void HikvisionISAPI::startSdkSearch(const QString &sessionId)
{
    if (!m_sessions.contains(sessionId))
        return;
    HikvisionSearchSession session = m_sessions.take(sessionId);
    if (session.sdkFallbackStarted)
        return;
    session.sdkFallbackStarted = true;

    QThread *worker = QThread::create([this, session]() {
        const QString ip = session.recorderInfo.value("ip").toString();
        const int port = session.recorderInfo.value("sdkPort").toInt() > 0
            ? session.recorderInfo.value("sdkPort").toInt()
            : session.recorderInfo.value("port").toInt();
        const QString username = session.recorderInfo.value("username").toString();
        const QString password = session.recorderInfo.value("password").toString();

        NET_DVR_DEVICEINFO_V40 deviceInfo;
        std::memset(&deviceInfo, 0, sizeof(deviceInfo));
        LONG userId = HikvisionManager::instance()->loginShared(ip, port > 0 ? port : 8000, username, password, deviceInfo);
        if (userId < 0) {
            QMetaObject::invokeMethod(this, [this, session]() {
                emit searchFailed(session.recorderInfo.value("ip").toString(), session.channelId, session.startTime, tr("SDK login failed"));
            }, Qt::QueuedConnection);
            return;
        }

        int channel = session.channelId;
        const auto &info = deviceInfo.struDeviceV30;
        if (info.byChanNum == 0 && info.byIPChanNum > 0)
            channel = session.channelId + info.byStartDChan - 1;
        else if (info.byChanNum > 0 && session.channelId > info.byChanNum)
            channel = info.byStartDChan + (session.channelId - info.byChanNum) - 1;
        else if (info.byChanNum > 0)
            channel = session.channelId + info.byStartChan - 1;

        NET_DVR_FILECOND_V40 cond;
        std::memset(&cond, 0, sizeof(cond));
        cond.lChannel = channel;
        cond.dwFileType = 0xFF;
        cond.dwIsLocked = 0xFF;
        fillSdkTime(cond.struStartTime, session.startTime);
        fillSdkTime(cond.struStopTime, session.endTime);

        QVariantList segments;
        QList<int> days;
        LONG findHandle = NET_DVR_FindFile_V40(userId, &cond);
        if (findHandle >= 0) {
            NET_DVR_FINDDATA_V50 data;
            while (true) {
                int state = NET_DVR_FindNextFile_V50(findHandle, &data);
                if (state == 1000) {
                    QDateTime start = fromSdkTime(data.struStartTime);
                    QDateTime end = fromSdkTime(data.struStopTime);
                    if (start.isValid() && end.isValid() && start < end) {
                        if (session.isMonthSearch) {
                            if (!days.contains(start.date().day()))
                                days.append(start.date().day());
                        } else {
                            QVariantMap segment;
                            segment["startTime"] = start.toMSecsSinceEpoch();
                            segment["endTime"] = end.toMSecsSinceEpoch();
                            segment["timeIsLocal"] = true;
                            segments.append(segment);
                        }
                    }
                } else if (state == 1002) {
                    QThread::msleep(10);
                } else {
                    break;
                }
            }
            NET_DVR_FindClose_V30(findHandle);
        }
        HikvisionManager::instance()->logoutShared(ip);

        QMetaObject::invokeMethod(this, [this, session, segments, days]() {
            const QString ip = session.recorderInfo.value("ip").toString();
            if (session.isMonthSearch) {
                QVariantList dayList;
                for (int day : days)
                    dayList.append(day);
                emit monthAvailabilityFinished(ip, session.channelId, session.year, session.month, dayList, true);
            } else {
                emit searchFinished(ip, session.channelId, session.startTime, segments);
            }
        }, Qt::QueuedConnection);
    });
    connect(worker, &QThread::finished, worker, &QThread::deleteLater);
    worker->start();
}

void HikvisionISAPI::cancelAllSearches()
{
    qDebug() << "[ISAPI] cancelAllSearches called. Cancelling" << m_sessions.size() << "active search sessions.";
    m_sessions.clear();
    
    // Copy the replies to a local list first to avoid iterator invalidation when they are aborted/deleted
    QList<QNetworkReply*> repliesToAbort = m_activeReplies.values();
    m_activeReplies.clear();

    for (auto* reply : repliesToAbort) {
        if (reply) {
            // Disconnect all signals to prevent onReplyFinished or authentication requests
            // from being triggered synchronously during reply->abort()
            reply->disconnect(this);
            reply->abort();
            reply->deleteLater();
        }
    }
}

