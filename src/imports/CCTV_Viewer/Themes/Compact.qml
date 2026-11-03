pragma Singleton

import QtQml 2.11
import QtQuick 2.11

QtObject {
    readonly property real radius: 4
    readonly property real spacing: 6
    readonly property real buttonPadding: 6
    readonly property real contentPadding: 10

    readonly property int toolTipDelay: 500
    readonly property int toolTipTimeout: 3000
}
