import QtQuick
import Quickshell.Widgets

// ============================================================================
//  AppIcon — IconImage para iconos de aplicaciones (lanzador) que esquiva un
//  bug de Qt 6.11 con escala fraccional.
//
//  Con cualquier salida a 1.25/1.5 el DPR global de Qt pasa a ser el entero
//  del wl_output (2) y QIconLoaderEngine::entryForSize ya no encuentra
//  coincidencia exacta: cae en su heurística de distancias, que en hicolor
//  (256x256/apps es Type=Scalable MinSize=64 → distancia 0) deja que un
//  directorio Threshold MÁS PEQUEÑO evaluado después pise esa coincidencia.
//  Resultado medido: una app con PNG {16,32,48,256} y sin 128 recibe el de
//  16 px estirado a 58-69 px — "solo algunos iconos pixelados". Los SVG (casi
//  todo Papirus) y los sets con 128 px no se ven afectados.
//
//  Arreglo acotado: si el pixmap llega MÁS PEQUEÑO de lo que se dibuja, se
//  vuelve a pedir UNA vez a 130 px lógicos (≥260 px efectivos para Qt, fuera
//  del rango 64..256 que dispara el bug), con mipmap para reducir sin
//  aliasing. Solo pagan memoria extra los iconos afectados; el resto pide
//  exactamente su tamaño en pantalla, como antes.
// ============================================================================
IconImage {
    id: root

    property bool retried: false
    // diferido (callLater): cambiar sourceSize recarga la imagen y vuelve a
    // emitir status dentro del mismo ciclo — evaluado en caliente es un bucle
    function checkSize() {
        if (!root.retried && root.backer.status === Image.Ready && root.actualSize > 0
                && root.backer.implicitWidth < root.actualSize)
            root.retried = true;
    }
    Connections {
        target: root.backer
        function onStatusChanged() { Qt.callLater(root.checkSize); }
    }
    onSourceChanged: root.retried = false

    backer.sourceSize.width: root.retried ? 130 : root.actualSize
    backer.sourceSize.height: root.retried ? 130 : root.actualSize
    mipmap: root.retried
}
