pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Weather via wttr.in (no API key). Location optional (auto-detected by IP when
// blank). Polled every 15 min; degrades silently when offline.
Singleton {
    id: root

    property int    temp: 0          // °C
    property string condition: ""    // short description
    property string icon: ""         // emoji from wttr
    property bool   ok: false

    // rich fields for the weather panel
    property int    feelsLike: 0     // °C
    property int    humidity: 0      // %
    property int    windKmph: 0
    property int    rainChance: 0    // %
    property string area: ""         // detected/queried location name
    property var    hourly: []       // [{ time:"09:00", temp, rain, glyph, sunny }]
    property var    forecast: []     // por día: { dayFull, desc, temp, wind(kmh), humidity, pop, feelsLike, glyph, hourly[] }

    readonly property string location: Config.get("weather", "location", "")

    Timer { interval: 900000; running: true; repeat: true; triggeredOnStart: true; onTriggered: fetcher.running = true }

    // wttr.in JSON (j1) — no API key. Parsed in QML; degrades silently offline.
    Process {
        id: fetcher
        command: ["bash", "-c",
            "curl -fsm 10 'https://wttr.in/" + encodeURIComponent(root.location) +
            "?format=j1" + (I18n.lang === "es" ? "&lang=es" : "") + "' 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: root.parseJson(this.text) }
    }

    // re-fetch on language change: descriptions come localized from wttr.in
    Connections { target: I18n; function onLangChanged() { fetcher.running = true; } }

    // description in the shell language: wttr.in returns lang_<xx> arrays when
    // &lang=<xx> is requested; English payloads fall back to weatherDesc.
    function descOf(o) {
        var l = o["lang_" + I18n.lang];
        return (((l || o.weatherDesc || [])[0]) || {}).value || "";
    }

    // WWO weather code → coarse category for a matching glyph.
    function glyphFor(code) {
        var c = parseInt(code) || 0;
        if (c === 113) return { g: Icons.sun, sunny: true };
        return { g: Icons.cloud, sunny: false };
    }

    function parseJson(txt) {
        var s = (txt || "").trim();
        if (s === "" || s.charAt(0) !== "{") { root.ok = false; return; }
        try {
            var j = JSON.parse(s);
            var cc = (j.current_condition || [])[0] || {};
            root.temp = parseInt(cc.temp_C) || 0;
            root.feelsLike = parseInt(cc.FeelsLikeC) || 0;
            root.humidity = parseInt(cc.humidity) || 0;
            root.windKmph = parseInt(cc.windspeedKmph) || 0;
            root.condition = root.descOf(cc);
            var nn = (j.nearest_area || [])[0] || {};
            root.area = ((nn.areaName || [])[0] || {}).value || root.location;

            // build the hourly timeline from today (+ tomorrow if sparse)
            var out = [];
            var days = j.weather || [];
            var nowH = new Date().getHours();
            var maxRain = 0;
            for (var d = 0; d < days.length && out.length < 8; d++) {
                var hrs = days[d].hourly || [];
                for (var i = 0; i < hrs.length && out.length < 8; i++) {
                    var h = hrs[i];
                    var hh = Math.floor((parseInt(h.time) || 0) / 100);
                    if (d === 0 && hh < nowH - 1) continue; // skip past hours today
                    var gl = root.glyphFor(h.weatherCode);
                    var rc = parseInt(h.chanceofrain) || 0;
                    maxRain = Math.max(maxRain, rc);
                    out.push({
                        time: (hh < 10 ? "0" + hh : "" + hh) + ":00",
                        temp: parseInt(h.tempC) || 0,
                        rain: rc,
                        glyph: gl.g,
                        sunny: gl.sunny
                    });
                }
            }
            root.hourly = out;
            root.rainChance = maxRain;
            root.icon = out.length > 0 && out[0].sunny ? "☀️" : "☁️";

            // previsión por día (3 días de wttr j1) para el panel de calendario
            var fc = [];
            for (var fd = 0; fd < days.length; fd++) {
                var day = days[fd];
                var dhrs = day.hourly || [];
                var mid = dhrs[Math.min(4, dhrs.length - 1)] || {};   // ~mediodía
                var dGl = root.glyphFor(mid.weatherCode);
                var dPop = 0, dHours = [];
                for (var hi = 0; hi < dhrs.length; hi++) {
                    var dh = dhrs[hi];
                    dPop = Math.max(dPop, parseInt(dh.chanceofrain) || 0);
                    var hh2 = Math.floor((parseInt(dh.time) || 0) / 100);
                    var hgl = root.glyphFor(dh.weatherCode);
                    dHours.push({
                        time: (hh2 < 10 ? "0" + hh2 : "" + hh2) + ":00",
                        temp: parseInt(dh.tempC) || 0,
                        glyph: hgl.g,
                        sunny: hgl.sunny
                    });
                }
                var dDate = new Date(day.date + "T12:00:00");
                fc.push({
                    dayFull: fd === 0 ? I18n.t("Today") : dDate.toLocaleDateString(I18n.locale, "dddd d"),
                    desc: fd === 0 ? root.condition : root.descOf(mid),
                    temp: fd === 0 ? root.temp : (parseInt(day.avgtempC) || 0),
                    wind: fd === 0 ? root.windKmph : (parseInt(mid.windspeedKmph) || 0),
                    humidity: fd === 0 ? root.humidity : (parseInt(mid.humidity) || 0),
                    pop: dPop,
                    feelsLike: fd === 0 ? root.feelsLike : (parseInt(mid.FeelsLikeC) || 0),
                    glyph: dGl.g,
                    sunny: dGl.sunny,
                    hourly: dHours
                });
            }
            root.forecast = fc;
            root.ok = true;
        } catch (e) {
            root.ok = false;
        }
    }

    function refresh() { fetcher.running = true; }
}
