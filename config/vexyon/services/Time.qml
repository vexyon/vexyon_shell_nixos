pragma Singleton

import QtQuick
import Quickshell
import qs.services

// Wall clock. Single shared timer for every widget that shows time.
// Eficiencia: si NADIE muestra segundos (ssWatchers == 0) el timer despierta
// solo en el cambio de minuto (~60x menos wakeups); con algún consumidor de
// segundos (reloj de barra con showSeconds, panel calendario abierto) vuelve
// al tick de 1s. El valor mostrado es idéntico en ambos modos: HH:mm y la
// fecha solo cambian en el borde de minuto, y ahí es exactamente donde se
// dispara el timer alineado.
Singleton {
    id: root
    property string time: ""
    property string date: ""
    property var now: new Date()
    // Dígits separats per al rellotge estil DMS (amplada fixa per dígit)
    property string hh: ""
    property string mm: ""
    property string ss: ""

    // Refcount de consumidores de SEGUNDOS (widgets con :ss visible).
    property int ssWatchers: 0
    onSsWatchersChanged: {
        if (ssWatchers > 0 && tick.interval !== 1000) {
            tick.interval = 1000;
            tick.restart();
            root.update();      // el :ss recién mostrado sale al día, sin esperar
        }
    }

    function update() {
        var d = new Date();
        root.now = d;
        root.time = Qt.formatDateTime(d, "HH:mm");
        // day/month names follow the shell language, not the system locale
        root.date = d.toLocaleDateString(I18n.locale, "ddd d MMM");
        root.hh = Qt.formatDateTime(d, "HH");
        root.mm = Qt.formatDateTime(d, "mm");
        root.ss = Qt.formatDateTime(d, "ss");
    }

    // OJO: sin triggeredOnStart — el handler hace restart() y con
    // triggeredOnStart eso re-dispararía el handler en bucle. El primer
    // update sale de Component.onCompleted.
    Component.onCompleted: update()
    Timer {
        id: tick
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            root.update();
            // Próximo despertar: 1s con consumidores de segundos; si no, el
            // siguiente borde de minuto (+50ms de guarda contra disparo
            // temprano). restart() explícito: el interval nuevo aplica YA.
            var want = root.ssWatchers > 0 ? 1000 : (60050 - (Date.now() % 60000));
            if (want !== tick.interval || root.ssWatchers === 0) {
                tick.interval = want;
                tick.restart();
            }
        }
    }
}
