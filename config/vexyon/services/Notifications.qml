pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import qs.services

// Notification center state: a live freedesktop notification server whose
// notifications are tracked (kept in a history list) plus the Do-Not-Disturb
// flag (persisted in shell.json). The notification-center panel renders the
// list; the bar widget surfaces DND + unread count.
Singleton {
    id: root

    readonly property bool dnd: Config.get("notifications", "dnd", false)
    property int unread: 0

    // tracked notifications (kept in history), exposed to the panel
    readonly property var list: server.trackedNotifications ? server.trackedNotifications.values : []
    readonly property int count: root.list.length

    // Tope del histórico retenido. Era ILIMITADO: cada notificación (con su
    // imagen, si trae) vivía en RAM para siempre — el "RAM sube con las
    // horas". El modelo de Quickshell APPENDEA (verificado en su fuente:
    // ObjectModel::insertObject con index -1 = al final), así que values es
    // oldest-first y el panel (slice(0,8)) enseña los índices 0..7: podar por
    // la COLA (índices ≥ MAX) no toca jamás nada visible. 100 retenidas dan
    // margen de sobra y acotan la memoria.
    readonly property int maxTracked: 100

    NotificationServer {
        id: server
        keepOnReload: false
        bodySupported: true
        imageSupported: true
        actionsSupported: true
        onNotification: function(n) {
            n.tracked = true;              // keep it in the history list
            if (!root.dnd) root.unread++;  // count toward the badge unless DND
            // poda de la cola: dismiss() saca la notificación del modelo y
            // libera su imagen; bucle re-leyendo values porque el modelo muta
            var guard = 0;
            while (server.trackedNotifications.values.length > root.maxTracked && guard++ < 50) {
                var l = server.trackedNotifications.values;
                if (l[l.length - 1]) l[l.length - 1].dismiss(); else break;
            }
        }
    }

    function toggleDnd() { Config.set("notifications", "dnd", !root.dnd); }
    function clear() { root.unread = 0; }
    function dismiss(n) { if (n) n.dismiss(); }
    function clearAll() {
        var l = root.list.slice();
        for (var i = 0; i < l.length; i++) if (l[i]) l[i].dismiss();
        root.unread = 0;
    }
}
