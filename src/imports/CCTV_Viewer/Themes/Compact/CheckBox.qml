/****************************************************************************
**
** Copyright (C) 2017 The Qt Company Ltd.
** Contact: http://www.qt.io/licensing/
**
** This file is part of the Qt Quick Controls 2 module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL3$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see http://www.qt.io/terms-conditions. For further
** information use the contact form at http://www.qt.io/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 3 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPLv3 included in the
** packaging of this file. Please review the following information to
** ensure the GNU Lesser General Public License version 3 requirements
** will be met: https://www.gnu.org/licenses/lgpl.html.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 2.0 or later as published by the Free
** Software Foundation and appearing in the file LICENSE.GPL included in
** the packaging of this file. Please review the following information to
** ensure the GNU General Public License version 2.0 requirements will be
** met: http://www.gnu.org/licenses/gpl-2.0.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/

import QtQuick 2.11
import QtQuick.Templates 2.15 as T
import QtQuick.Controls 2.15
import QtQuick.Controls.impl 2.15
import QtQuick.Layouts 1.11
import CCTV_Viewer.Themes 1.0

T.CheckBox {
    id: control

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             implicitContentHeight + topPadding + bottomPadding,
                             implicitIndicatorHeight + topPadding + bottomPadding)

    padding: 4
    spacing: Compact.spacing
    hoverEnabled: true

    // A long label may shrink and wrap when a layout is narrower than the words, instead of pushing the layout wider.
    Layout.minimumWidth: 0

    // keep in sync with CheckDelegate.qml (shared CheckIndicator.qml was removed for performance reasons)
    indicator: Rectangle {
        radius: Compact.radius
        implicitWidth: 18
        implicitHeight: 18

        x: control.text ? (control.mirrored ? control.width - width - control.rightPadding : control.leftPadding) : control.leftPadding + (control.availableWidth - width) / 2
        y: control.topPadding + (control.availableHeight - height) / 2

        color: control.down ? "#1c2833"
             : (control.checkState !== Qt.Unchecked ? "#102a2a"
             : (control.hovered ? "#162029" : "#0f151b"))
        border.width: (control.visualFocus || control.checkState !== Qt.Unchecked) ? 1.5 : 1
        border.color: (control.checkState !== Qt.Unchecked || control.visualFocus) ? "#00f5d4"
                    : (control.hovered ? "#5a6b7c" : "#3a4856")
        opacity: control.enabled ? 1.0 : 0.45

        Image {
            x: (parent.width - width) / 2
            y: (parent.height - height) / 2
            width: 12
            height: 12
            sourceSize: Qt.size(24, 24)
            source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2300f5d4' stroke-width='3.5' stroke-linecap='round' stroke-linejoin='round'><polyline points='20 6 9 17 4 12'></polyline></svg>"
            visible: control.checkState === Qt.Checked
        }

        Rectangle {
            x: (parent.width - width) / 2
            y: (parent.height - height) / 2
            width: 10
            height: 2
            radius: 1
            color: "#00f5d4"
            visible: control.checkState === Qt.PartiallyChecked
        }
    }

    // The words sit in a plain item that reports the width they need on one line, so the checkbox can size itself
    // from that without waiting on the label, which in turn is told the width it has and wraps inside it.
    contentItem: Item {
        implicitWidth: (control.indicator && !control.mirrored ? control.indicator.width + control.spacing : 0)
                       + (control.indicator && control.mirrored ? control.indicator.width + control.spacing : 0)
                       // A little extra, because the text field needs slightly more than the bare width of its words,
                       // and with exactly the bare width the last letter drops onto a second line.
                       + Math.ceil(oneLine.width) + 8
        implicitHeight: words.implicitHeight

        TextMetrics {
            id: oneLine
            font: control.font
            text: control.text
        }

        SelectableLabel {
            id: words
            // Starts after the tick box and covers only the words, so a click on the tick box itself is not taken.
            x: control.indicator && !control.mirrored ? control.indicator.width + control.spacing : 0
            width: parent.width - x - (control.indicator && control.mirrored ? control.indicator.width + control.spacing : 0)
            // The label takes the mouse so its words can be selected, so a click on it (not a drag) is passed on here.
            forwardClicks: true
            onClicked: {
                if (control.enabled) {
                    control.toggle()
                    control.toggled()
                    control.clicked()
                }
            }
            text: control.text
            font: control.font
            textColor: "#ffffff"
            opacity: control.enabled ? 1.0 : 0.5
        }
    }
}
