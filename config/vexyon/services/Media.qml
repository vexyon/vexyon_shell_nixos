pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Mpris

// Current MPRIS media player (first active). UI reads state, calls transport
// controls here. `present` is false when nothing is playing/available.
Singleton {
    id: root

    readonly property var players: Mpris.players ? Mpris.players.values : []
    readonly property MprisPlayer player: {
        // prefer a playing player, else the first available
        for (var i = 0; i < root.players.length; i++)
            if (root.players[i] && root.players[i].playbackState === MprisPlaybackState.Playing)
                return root.players[i];
        return root.players.length > 0 ? root.players[0] : null;
    }
    readonly property bool present: player !== null
    readonly property bool playing: present && player.playbackState === MprisPlaybackState.Playing
    readonly property string title: present ? (player.trackTitle || "") : ""
    readonly property string artist: present ? (player.trackArtist || "") : ""
    readonly property string label: {
        if (!present) return "";
        if (title === "") return artist;
        return artist !== "" ? (artist + " — " + title) : title;
    }
    readonly property string artUrl: present ? (player.trackArtUrl || "") : ""
    readonly property string identity: present ? (player.identity || player.dbusName || "") : ""
    readonly property real length: present ? (player.length || 0) : 0
    readonly property real position: present ? (player.position || 0) : 0
    readonly property real progress: length > 0 ? Math.max(0, Math.min(1, position / length)) : 0
    readonly property bool canSeek: present && player.canSeek

    // Refcount de consumidores de POSICIÓN (solo el MediaPanel la muestra; el
    // widget de barra usa título/estado, que llegan por señales MPRIS). Sin
    // consumidores no se emite el positionChanged() de refresco cada segundo.
    property int watchers: 0
    // Al abrirse el panel, posición al día ANTES del primer frame visible —
    // idéntico a cuando el tick corría siempre.
    onWatchersChanged: if (watchers > 0 && present && player.positionSupported) player.positionChanged()

    // keep position live while something displays it
    Timer {
        interval: 1000; running: root.present && root.watchers > 0; repeat: true
        onTriggered: if (root.present && root.player.positionSupported) root.player.positionChanged()
    }

    function toggle()   { if (present && player.canTogglePlaying) player.togglePlaying(); }
    function pause()    { if (present && player.canPause) player.pause(); }
    function next()     { if (present && player.canGoNext) player.next(); }
    function previous() { if (present && player.canGoPrevious) player.previous(); }
    function seekTo(frac) { if (canSeek && length > 0) player.position = frac * length; }
    function fmtTime(s) {
        if (!s || s <= 0) return "0:00";
        var m = Math.floor(s / 60), ss = Math.floor(s % 60);
        return m + ":" + (ss < 10 ? "0" + ss : ss);
    }
}
