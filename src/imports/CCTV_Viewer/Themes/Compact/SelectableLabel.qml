import QtQuick 2.11
import QtQuick.Controls 2.4

// Looks like an ordinary label, but the words can be selected with the mouse (a drag, across as many
// lines as you like), and copied with Ctrl+C or with a right-click menu (Copy, Select all).
//
// Selecting is done by the mouse area below, not by the text field, so a plain click with no drag can still
// be handed on: with forwardClicks set it is sent out as clicked(), which a checkbox uses to toggle itself.
TextEdit {
    id: label

    // The colour of the words.
    property color textColor: "#ffffff"
    color: textColor

    // Set by a control that wraps the label (a checkbox) to get a click that was not a drag.
    property bool forwardClicks: false
    signal clicked()

    readOnly: true
    wrapMode: TextEdit.Wrap
    selectByMouse: false
    activeFocusOnPress: false
    selectByKeyboard: true
    persistentSelection: true
    renderType: Text.QtRendering
    selectedTextColor: "#121214"
    selectionColor: "#00f5d4"

    Keys.onPressed: {
        if (event.matches(StandardKey.Copy)) {
            if (label.selectedText !== "")
                label.copy()
            event.accepted = true
        } else if (event.matches(StandardKey.SelectAll)) {
            label.selectAll()
            event.accepted = true
        }
    }

    // One highlighted passage at a time: leaving the label (except for its own menu) clears it.
    onActiveFocusChanged: {
        if (!activeFocus && !copyMenu.visible)
            label.deselect()
    }

    Menu {
        id: copyMenu
        objectName: "copyMenu"
        onClosed: label.forceActiveFocus()

        MenuItem {
            text: qsTr("Copy")
            enabled: label.selectedText !== ""
            onTriggered: label.copy()
        }
        MenuItem {
            text: qsTr("Select all")
            onTriggered: label.selectAll()
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.leftMargin: label.leftPadding
        anchors.rightMargin: label.rightPadding
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.IBeamCursor

        property int anchorPosition: 0
        property real pressX: 0
        property real pressY: 0
        property bool dragged: false

        function positionAtPoint(x, y) {
            return label.positionAt(x + label.leftPadding, y)
        }

        onPressed: {
            label.forceActiveFocus()
            if (mouse.button === Qt.RightButton) {
                copyMenu.popup(area, mouse.x, mouse.y)
                return
            }
            pressX = mouse.x
            pressY = mouse.y
            dragged = false
            anchorPosition = positionAtPoint(mouse.x, mouse.y)
            label.deselect()
            label.cursorPosition = anchorPosition
        }

        onPositionChanged: {
            if (!(mouse.buttons & Qt.LeftButton))
                return
            if (!dragged && Math.abs(mouse.x - pressX) < 4 && Math.abs(mouse.y - pressY) < 4)
                return
            dragged = true
            label.select(anchorPosition, positionAtPoint(mouse.x, mouse.y))
        }

        onReleased: {
            if (mouse.button === Qt.LeftButton && !dragged && label.forwardClicks)
                label.clicked()
        }

        onDoubleClicked: {
            if (mouse.button === Qt.LeftButton && !label.forwardClicks)
                label.selectWord()
        }
    }
}
