import QtQuick
import QtQuick.Layouts
import qs.services

// Compact month calendar: header (‹ Month YYYY ›), weekday row (Mon-first),
// day grid with today highlighted. Month navigable; theme-token styled.
ColumnLayout {
    id: cal
    property date today: Time.now
    property int viewYear: today.getFullYear()
    property int viewMonth: today.getMonth()   // 0-11
    spacing: 6

    readonly property var monthNames: [I18n.t("January"),I18n.t("February"),I18n.t("March"),I18n.t("April"),I18n.t("May"),I18n.t("June"),
        I18n.t("July"),I18n.t("August"),I18n.t("September"),I18n.t("October"),I18n.t("November"),I18n.t("December")]
    readonly property var dayNames: [I18n.t("Mon"),I18n.t("Tue"),I18n.t("Wed"),I18n.t("Thu"),I18n.t("Fri"),I18n.t("Sat"),I18n.t("Sun")]

    function daysInMonth(y, m) { return new Date(y, m + 1, 0).getDate(); }
    // JS getDay: 0=Sun..6=Sat → shift to Mon-first (0=Mon..6=Sun)
    function firstOffset(y, m) { var d = new Date(y, m, 1).getDay(); return (d + 6) % 7; }
    function prevMonth() {
        if (cal.viewMonth === 0) { cal.viewMonth = 11; cal.viewYear--; }
        else cal.viewMonth--;
    }
    function nextMonth() {
        if (cal.viewMonth === 11) { cal.viewMonth = 0; cal.viewYear++; }
        else cal.viewMonth++;
    }
    function isToday(day) {
        return day === cal.today.getDate()
            && cal.viewMonth === cal.today.getMonth()
            && cal.viewYear === cal.today.getFullYear();
    }

    // ---- header ----
    RowLayout {
        Layout.fillWidth: true
        Text {
            text: "‹"; color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4
            MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: cal.prevMonth() }
        }
        Text {
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            text: cal.monthNames[cal.viewMonth] + " " + cal.viewYear
            color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true
        }
        Text {
            text: "›"; color: Theme.subtext1; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 4
            MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: cal.nextMonth() }
        }
    }

    // ---- weekday header ----
    GridLayout {
        Layout.fillWidth: true; columns: 7; columnSpacing: 2; rowSpacing: 2
        Repeater {
            model: cal.dayNames
            delegate: Text {
                required property var modelData
                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                text: modelData; color: Theme.overlay2
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 4
            }
        }
    }

    // ---- day grid ----
    GridLayout {
        Layout.fillWidth: true; columns: 7; columnSpacing: 2; rowSpacing: 2
        Repeater {
            // 42 cells (6 weeks); blanks before the 1st + trailing blanks
            model: 42
            delegate: Item {
                id: cell
                required property int index
                readonly property int off: cal.firstOffset(cal.viewYear, cal.viewMonth)
                readonly property int dim: cal.daysInMonth(cal.viewYear, cal.viewMonth)
                readonly property int day: index - off + 1
                readonly property bool inMonth: day >= 1 && day <= dim
                Layout.fillWidth: true
                Layout.preferredHeight: 26
                visible: index < off + dim   // hide fully-empty trailing rows
                Rectangle {
                    anchors.centerIn: parent
                    width: 24; height: 24; radius: 12
                    visible: cell.inMonth
                    color: cell.inMonth && cal.isToday(cell.day) ? Theme.accent : "transparent"
                    Text {
                        anchors.centerIn: parent
                        text: cell.inMonth ? cell.day : ""
                        color: cell.inMonth && cal.isToday(cell.day) ? Theme.onAccent : Theme.subtext1
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2
                        font.bold: cell.inMonth && cal.isToday(cell.day)
                    }
                }
            }
        }
    }
}
