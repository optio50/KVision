import QtQuick 2.11

// Draws like an ordinary label, but the words can be dragged over and copied with Ctrl+C.
// A plain click is handed back to whatever is underneath, so a checkbox still toggles when its
// label is clicked. Only a drag, which selects the words, is kept.
TextEdit {
    id: label

    // Fill exactly the width it is given, so the words wrap at the edge of the box instead of running
    // past it. A text field otherwise sizes itself to its text and spills out of the section.
    width: parent ? parent.width : implicitWidth

    // The text colour. Set straight on the text field, so it shows instead of the default black.
    property color textColor: "#ffffff"
    color: textColor

    // Keep the words inside the box they are given, so a long line never spills past its edge.
    clip: true

    readOnly: true
    // So a note can be switched over from Text without changing its lines.
    property var wrapMode: TextEdit.WordWrap
    selectByMouse: true
    selectByKeyboard: true
    persistentSelection: true
    activeFocusOnPress: false
    renderType: Text.QtRendering
    selectedTextColor: "#121214"
    selectionColor: "#00f5d4"

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: parent.selectionStart !== parent.selectionEnd ? Qt.IBeamCursor : Qt.ArrowCursor
        propagateComposedEvents: true
        property real pressX: 0
        property real pressY: 0
        onPressed: {
            if (mouse.button === Qt.RightButton) {
                mouse.accepted = false
                return
            }
            pressX = mouse.x
            pressY = mouse.y
            mouse.accepted = false
        }
        onPositionChanged: {
            // The pointer has moved, so this is a drag to select, not a click. Keep it.
            if (Math.abs(mouse.x - pressX) > 3 || Math.abs(mouse.y - pressY) > 3)
                mouse.accepted = true
        }
    }
}
