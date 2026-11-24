[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

# QmlAV
FFmpeg-based real-time QML stream player

### To use in your project, you must follow these steps:

1. Get dependencies:

* For Debian, Ubuntu and Linux Mint. KVision's install.sh installs these.

```
# apt-get install libva-dev libglx-dev libavformat-dev libavcodec-dev libavutil-dev libswscale-dev libswresample-dev libavdevice-dev libgtest-dev
```

2. Setup your project (Roughly. For details, see https://github.com/iEvgeny/cctv-viewer):

```
find_package(Qt5 5.12 COMPONENTS Core Quick Multimedia REQUIRED)

add_subdirectory(qmlav)

add_executable(${TARGET} ${PROJ_FILES} ${QMLAV_FILES})

target_include_directories(${TARGET} PRIVATE ${QMLAV_INCLUDE})

target_link_libraries(${TARGET} PRIVATE avformat avcodec avutil swscale swresample avdevice)
```

3. Register the QML type before using:

```
#include "qmlavplayer.h"

qmlRegisterType<QmlAVPlayer>("QmlAV.Multimedia", 1, 0, "QmlAVPlayer");

...
```

4. And use this in your QML code:

```
import QtQuick 2.0
import QtMultimedia 5.0
import QmlAV.Multimedia 1.0

Item {
    VideoOutput {
        id: videoOutput

        source: qmlAvPlayer
        anchors.fill: parent
    }

    QmlAVPlayer {
        id: qmlAvPlayer

        autoPlay: true
        loops: MediaPlayer.Infinite
        source: rtmp://example.ru/stream/name

        avOptions: {
            'probesize': 500000,  // 500 KB
            'analyzeduration': 0  // 0 µs
        }
    }
}
```
