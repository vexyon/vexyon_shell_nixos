import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

// ============================================================================
//  QuickSettingsPanel — anchored dropdown for the right-side bar cluster
//  (network / bluetooth / audio / mic / system). Opens below whichever widget
//  triggered it. Profile header, volume + brightness sliders, and a grid of
//  toggle tiles. Network/audio/mic tiles open the SAME canonical panels the
//  dedicated bar widgets use (NetworkPanel / VolumePanel) — no duplicated
//  drill-down views in here. All theme-token driven, live.
// ============================================================================
AnchoredPanel {
    id: qs
    panelKey: "quickSettings"
    ns: "vexyon-quicksettings"
    panelWidth: 460
    accentColor: Theme.blue    // acento ilyamiro del panel de red/sistema

    onShownChanged: if (shown) uptimeProc.running = true

    property string uptime: ""
    Process {
        id: uptimeProc
        command: ["bash", "-c", "uptime -p | sed 's/^up //'"]
        stdout: StdioCollector { onStreamFinished: qs.uptime = this.text.trim() }
    }

    // dark/light toggle memory
    property string lastDark: "crimson-voltage"

    content: Component {
        ColumnLayout {
            id: body
            width: qs.panelWidth - qs.contentMargin * 2
            spacing: 12
            // fases de la intro escalonada (las empuja AnchoredPanel)
            property real introHeader: 1
            property real introContent: 1

            // profile header (fase introHeader — entra con OutBack)
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                opacity: body.introHeader
                transform: Translate { y: 16 * (1 - body.introHeader) }
                Avatar { Layout.preferredWidth: 46; Layout.preferredHeight: 46; size: 46 }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 0
                    Text {
                        text: Quickshell.env("USER") || "user"; color: Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 2; font.bold: true
                    }
                    Text {
                        text: qs.uptime !== "" ? "up " + qs.uptime : "Hyprland"; color: Theme.subtext0
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; elide: Text.ElideRight
                    }
                }
                IconButton { icon: Icons.lock;  onClicked: { qs.close(); Lock.lock(); } }
                IconButton { icon: Icons.power; onClicked: { qs.close(); Panels.open("powermenu"); } }
                IconButton { icon: Icons.gear;  onClicked: { qs.close(); Panels.settings = true; } }
            }

            // volume
            RowLayout {
                Layout.fillWidth: true; spacing: 12
                opacity: body.introContent
                IconButton {
                    icon: Audio.muted ? Icons.volumeMute : Icons.volumeHigh
                    iconColor: Audio.muted ? Theme.overlay2 : Theme.text
                    onClicked: Audio.toggleMute()
                }
                Slider {
                    Layout.fillWidth: true; value: Audio.volume; fillColor: Theme.accent
                    onMoved: function(v) { Audio.setVolume(v); }
                }
            }
            // brightness
            RowLayout {
                Layout.fillWidth: true; visible: Brightness.available; spacing: 12
                opacity: body.introContent
                Text {
                    text: Icons.sun; color: Theme.text; font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 2; Layout.preferredWidth: 30; horizontalAlignment: Text.AlignHCenter
                }
                Slider {
                    Layout.fillWidth: true; value: Brightness.percent / 100; fillColor: Theme.yellow
                    onMoved: function(v) { Brightness.set(v * 100); }
                }
            }

            // toggle tile grid (fase introContent). Los tiles de red/bt/audio/mic
            // abren el panel canónico correspondiente (el mismo que el widget
            // dedicado de la barra) conservando el anclaje actual del panel.
            GridLayout {
                Layout.fillWidth: true; columns: 2; columnSpacing: 10; rowSpacing: 10
                opacity: body.introContent
                transform: Translate { y: 18 * (1 - body.introContent) }

                QuickTile {
                    Layout.fillWidth: true
                    icon: Network.kind === "wifi" ? Icons.wifi : Icons.ethernet
                    title: Network.ethernetUp ? "Ethernet" : I18n.t("Network")
                    subtitle: Network.kind === "disconnected" ? I18n.t("Disconnected")
                              : Network.kind === "ethernet" ? I18n.t("Connected")
                              : (Network.name || "Wi-Fi") + " · " + Network.strength + "%"
                    active: Network.kind !== "disconnected"
                    onClicked: {
                        Panels.networkInitTab = Network.kind === "ethernet" ? "eth" : "wifi";
                        Panels.open("networkPanel");
                    }
                }
                QuickTile {
                    Layout.fillWidth: true
                    icon: Icons.bluetooth
                    title: "Bluetooth"
                    subtitle: !Bluetooth.present ? I18n.t("No adapter")
                              : !Bluetooth.enabled ? I18n.t("Disabled")
                              : Bluetooth.connectedCount > 0 ? Bluetooth.firstDeviceName : I18n.t("Enabled")
                    active: Bluetooth.present && Bluetooth.enabled
                    onClicked: {
                        Panels.networkInitTab = "bt";
                        Panels.open("networkPanel");
                    }
                    onSecondaryClicked: Bluetooth.toggle()
                }
                QuickTile {
                    Layout.fillWidth: true
                    icon: Audio.muted ? Icons.volumeMute : Icons.volumeHigh
                    title: Audio.sinkName || I18n.t("Audio output")
                    subtitle: Audio.muted ? I18n.t("Muted") : Audio.percent + "%"
                    active: !Audio.muted
                    onClicked: {
                        Panels.volumeInitTab = "outputs";
                        Panels.open("volumePanel");
                    }
                    onSecondaryClicked: Audio.toggleMute()
                }
                QuickTile {
                    Layout.fillWidth: true
                    icon: Mic.muted ? Icons.micOff : Icons.microphone
                    title: Mic.sourceName || I18n.t("Microphone")
                    subtitle: Mic.muted ? I18n.t("Muted") : Mic.percent + "%"
                    active: Mic.present && !Mic.muted
                    onClicked: {
                        Panels.volumeInitTab = "inputs";
                        Panels.open("volumePanel");
                    }
                    onSecondaryClicked: Mic.toggleMute()
                }
                QuickTile {
                    Layout.fillWidth: true
                    icon: Icons.moon
                    title: I18n.t("Night mode")
                    subtitle: Config.get("appearance", "nightLight", false) ? I18n.t("Warm") : I18n.t("Off")
                    active: Config.get("appearance", "nightLight", false)
                    onClicked: {
                        var on = !Config.get("appearance", "nightLight", false);
                        Config.set("appearance", "nightLight", on);
                        Quickshell.execDetached(["bash", "-c",
                            on ? "pkill hyprsunset; sleep 0.2; hyprsunset -t 3600 &"
                               : "pkill hyprsunset; sleep 0.2; hyprsunset &"]);
                    }
                }
                QuickTile {
                    Layout.fillWidth: true
                    icon: Icons.moon
                    title: I18n.t("Dark mode")
                    subtitle: Theme.meta.dark === false ? I18n.t("Light") : I18n.t("Dark")
                    active: Theme.meta.dark !== false
                    onClicked: {
                        if (Theme.meta.dark !== false) { qs.lastDark = Theme.activeId; Theme.apply("catppuccin-latte"); }
                        else { Theme.apply(qs.lastDark || "crimson-voltage"); }
                    }
                }
            }
        }
    }
}
