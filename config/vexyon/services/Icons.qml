pragma Singleton

import QtQuick
import Quickshell

// Central glyph map for "JetBrainsMono Nerd Font". Values are literal Font
// Awesome glyphs in the Nerd Font private-use ranges (U+F0xx/F1xx/F2xx), which
// the full ttf-jetbrains-mono-nerd build covers. One place to fix or swap a
// glyph. Verified: every entry renders (no blanks) across bar / control center /
// file manager / power menu on the current font build.
Singleton {
    id: root

    // navigation / window chrome
    readonly property string back:        ""  // chevron-left
    readonly property string forward:     ""  // chevron-right
    readonly property string up:          ""  // arrow-up
    readonly property string refresh:     ""
    readonly property string close:       ""  // times
    readonly property string search:      ""
    readonly property string check:       ""
    readonly property string gear:        ""  // cog
    readonly property string sliders:     ""
    readonly property string grid:        ""  // th
    readonly property string list:        ""
    readonly property string plus:        ""
    readonly property string palette:     ""  // tint (theme)
    readonly property string keyboard:    ""
    readonly property string chevronDown: ""
    readonly property string chevronRight:""

    // places / files
    readonly property string home:        ""
    readonly property string folder:      ""
    readonly property string file:        ""
    readonly property string archive:     ""  // file-archive (zip)
    readonly property string download:    ""
    readonly property string image:       ""
    readonly property string video:       ""  // film
    readonly property string music:       ""
    readonly property string documents:   ""  // file-text
    readonly property string trash:       ""
    readonly property string desktop:     ""
    readonly property string drive:       ""  // hdd
    readonly property string star:        ""

    // system indicators
    readonly property string volumeHigh:  ""
    readonly property string volumeLow:   ""
    readonly property string volumeMute:  ""
    readonly property string brightness:  ""  // sun
    readonly property string wifi:        ""
    readonly property string ethernet:    ""  // sitemap
    readonly property string noNetwork:   ""  // ban
    readonly property string battery:     ""  // battery-full
    readonly property string batteryLow:  ""  // battery-quarter
    readonly property string charging:    ""  // bolt

    // session / power
    readonly property string power:       ""  // power-off
    readonly property string lock:        ""
    readonly property string suspend:     ""   // moon
    readonly property string reboot:      ""   // refresh
    readonly property string logout:      ""   // sign-out

    // quick-settings tiles / settings
    readonly property string pencil:      ""   // edit
    readonly property string bluetooth:   ""
    readonly property string microphone:  ""
    readonly property string micOff:      ""
    readonly property string bell:        ""
    readonly property string bellOff:     ""
    readonly property string moon:        ""
    readonly property string sun:         ""
    readonly property string clipboard:   ""
    readonly property string info:        ""
    readonly property string typography:  ""   // font
    readonly property string clock:       ""
    // widget catalog / bar management (FA codepoints via \u escapes)
    readonly property string eye:         "\uf06e"   // fa-eye  (show)
    readonly property string eyeSlash:    "\uf070"   // fa-eye-slash (hidden)
    readonly property string dragHandle:  "\uf142"   // fa-ellipsis-v
    readonly property string window:      "\uf2d0"   // fa-window-maximize
    readonly property string cloud:       "\uf0c2"   // fa-cloud (weather)
    readonly property string coffee:      "\uf0f4"   // fa-coffee (idle inhibitor)
    readonly property string play:        "\uf04b"   // fa-play
    readonly property string pause:       "\uf04c"   // fa-pause
    readonly property string stepForward: "\uf051"   // fa-step-forward (next)
    readonly property string stepBack:    "\uf048"   // fa-step-backward (prev)
    readonly property string microchip:   "\uf2db"   // fa-microchip (cpu)
    readonly property string server:      "\uf233"   // fa-server (memory)
    readonly property string thermometer: "\uf2c9"   // fa-thermometer-half (temp)
    readonly property string shield:      "\uf132"   // fa-shield (privacy / vpn)
    readonly property string eyeDropper:  "\uf1fb"   // fa-eye-dropper (color picker)
    readonly property string stickyNote:  "\uf249"   // fa-sticky-note (notes)
    readonly property string arrowUp:     "\uf062"   // fa-arrow-up (net up / caps)
    readonly property string arrowDown:   "\uf063"   // fa-arrow-down (net down)
    readonly property string arrowsH:     "\uf07e"   // fa-arrows-h (spacer)
    readonly property string inbox:       "\uf01c"   // fa-inbox (system tray)
    readonly property string bars:        "\uf0c9"   // fa-bars (apps dock / menu)
    readonly property string language:    "\uf1ab"   // fa-language (keyboard layout)
    readonly property string crop:        "\uf125"   // fa-crop (region select)
    readonly property string copy:        "\uf0c5"   // fa-copy (clipboard entry)
}
