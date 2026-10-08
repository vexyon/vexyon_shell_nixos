pragma Singleton

import QtQuick
import Quickshell
import qs.services

// ============================================================================
//  FolderIcons — the symbol drawn on top of a folder in the File Manager.
//
//  Folders keep their normal artwork (the themed folder glyph); a symbol is
//  composited on it — a document on Documents, an arrow on Downloads… The
//  symbols are vector glyphs from the Material Design set that the Nerd Font
//  the shell already depends on carries (JetBrainsMono Nerd Font, code points
//  U+F0001–U+F1AF0): no icon pack, no new dependency, sharp at any size and
//  scale, and tinted from the theme so they follow every palette change.
//
//  Which symbol a folder shows, first match wins:
//   1. the one the user chose (Customize Folder Icon), stored by
//      `vexyon-fm-helper` in ~/.local/share/vexyon/folder-icons.json — keyed
//      by path, with the folder's device+inode so a rename or move made by
//      another program is followed; nothing is written inside the folder;
//   2. the default of an XDG user folder, at its CONFIGURED path (Places);
//   3. Home's house.
//
//  A custom image (SVG/PNG) is only ever loaded from the sanitised copy the
//  helper makes; the original file is never handed to the renderer.
// ============================================================================
Singleton {
    id: root

    // ---- library -----------------------------------------------------------
    //  [id, code point (hex), category, label, extra search words]. Labels and
    //  categories are English I18n keys.
    readonly property var catalog: [
        // General
        ["star", "f04ce", "General", "Star", "favorite"],
        ["heart", "f02d1", "General", "Heart", "love favorite"],
        ["bookmark", "f00c0", "General", "Bookmark", "saved"],
        ["flag", "f023b", "General", "Flag", "mark"],
        ["tag", "f04f9", "General", "Tag", "label"],
        ["pin", "f0403", "General", "Pin", "pinned"],
        ["lightbulb", "f0335", "General", "Idea", "light bulb"],
        ["fire", "f0238", "General", "Fire", "hot"],
        ["lightning-bolt", "f140b", "General", "Lightning", "fast flash"],
        ["palette", "f03d8", "General", "Palette", "art colors design"],
        ["puzzle", "f0431", "General", "Puzzle", "plugin extension"],
        ["rocket-launch", "f14de", "General", "Rocket", "launch startup"],
        ["crown", "f01a5", "General", "Crown", "king vip"],
        ["diamond-stone", "f01c8", "General", "Diamond", "gem valuable"],
        ["cog", "f0493", "General", "Gear", "settings config"],
        ["wrench", "f05b7", "General", "Wrench", "tools fix"],
        ["toolbox", "f09ac", "General", "Toolbox", "tools kit"],
        ["clock-outline", "f0150", "General", "Clock", "time recent"],
        ["calendar", "f00ed", "General", "Calendar", "date events"],
        ["inbox", "f0687", "General", "Inbox", "incoming"],
        ["eye", "f0208", "General", "Eye", "watch view"],
        ["account", "f0004", "General", "Person", "user profile"],
        ["account-group", "f0849", "General", "Group", "team people"],
        ["home", "f02dc", "General", "House", "home"],
        ["trash-can", "f0a79", "General", "Trash", "bin delete"],
        ["alert", "f0026", "General", "Warning", "alert important"],
        ["check-circle", "f05e0", "General", "Done", "check finished"],
        ["layers", "f0328", "General", "Layers", "stack"],
        ["application", "f08c6", "General", "Window", "application program"],
        ["pencil-ruler", "f1353", "General", "Templates", "ruler design draft"],
        ["share-variant", "f0497", "General", "Share", "public shared"],
        ["link-variant", "f0339", "General", "Link", "chain"],
        // Documents
        ["file-document", "f0219", "Documents", "Document", "text paper"],
        ["file-document-multiple", "f1517", "Documents", "Documents", "papers"],
        ["file-pdf-box", "f0226", "Documents", "PDF", "adobe"],
        ["file-word", "f022c", "Documents", "Word", "doc office"],
        ["file-excel", "f021b", "Documents", "Spreadsheet", "excel calc office"],
        ["file-powerpoint", "f0227", "Documents", "Presentation", "slides powerpoint office"],
        ["text-box", "f021a", "Documents", "Text", "notes"],
        ["notebook", "f082e", "Documents", "Notebook", "journal notes"],
        ["book-open-variant", "f14f7", "Documents", "Book", "reading"],
        ["clipboard-text", "f014d", "Documents", "Clipboard", "list"],
        ["note-text", "f039e", "Documents", "Note", "memo"],
        ["newspaper", "f0395", "Documents", "Newspaper", "news article"],
        ["file-sign", "f19c3", "Documents", "Signed", "contract sign"],
        ["receipt", "f0449", "Documents", "Receipt", "invoice bill"],
        ["script-text", "f0bc2", "Documents", "Script", "scroll"],
        ["file-cabinet", "f0ab6", "Documents", "Filing cabinet", "records"],
        ["card-account-details", "f05d2", "Documents", "ID", "identity card"],
        // Development
        ["code-braces", "f0169", "Development", "Code", "programming braces"],
        ["code-tags", "f0174", "Development", "Markup", "html tags"],
        ["console", "f018d", "Development", "Terminal", "console shell"],
        ["git", "f02a2", "Development", "Git", "version control"],
        ["github", "f02a4", "Development", "GitHub", "repository"],
        ["gitlab", "f0ba0", "Development", "GitLab", "repository"],
        ["source-branch", "f062c", "Development", "Branch", "git branch"],
        ["bug", "f00e4", "Development", "Bug", "debug issue"],
        ["language-python", "f0320", "Development", "Python", "py"],
        ["language-javascript", "f031e", "Development", "JavaScript", "js"],
        ["language-typescript", "f06e6", "Development", "TypeScript", "ts"],
        ["language-rust", "f1617", "Development", "Rust", "cargo"],
        ["language-go", "f07d3", "Development", "Go", "golang"],
        ["language-c", "f0671", "Development", "C", "clang"],
        ["language-cpp", "f0672", "Development", "C++", "cpp"],
        ["language-java", "f0b37", "Development", "Java", "jvm"],
        ["language-php", "f031f", "Development", "PHP", "web"],
        ["language-ruby", "f0d2d", "Development", "Ruby", "gem"],
        ["language-lua", "f08b1", "Development", "Lua", "script"],
        ["language-html5", "f031d", "Development", "HTML", "web"],
        ["language-css3", "f031c", "Development", "CSS", "style web"],
        ["nodejs", "f0399", "Development", "Node.js", "npm"],
        ["react", "f0708", "Development", "React", "frontend"],
        ["vuejs", "f0844", "Development", "Vue", "frontend"],
        ["docker", "f0868", "Development", "Docker", "containers"],
        ["kubernetes", "f10fe", "Development", "Kubernetes", "k8s"],
        ["database", "f01bc", "Development", "Database", "sql data"],
        ["api", "f109b", "Development", "API", "interface"],
        ["linux", "f033d", "Development", "Linux", "tux"],
        ["nix", "f1105", "Development", "Nix", "nixos snowflake"],
        ["robot", "f06a9", "Development", "Robot", "bot ai automation"],
        // Work
        ["briefcase", "f00d6", "Work", "Briefcase", "work job"],
        ["domain", "f01d7", "Work", "Company", "building office"],
        ["office-building", "f0991", "Work", "Office", "building"],
        ["chart-bar", "f0128", "Work", "Bar chart", "stats reports"],
        ["chart-line", "f012a", "Work", "Line chart", "stats growth"],
        ["chart-pie", "f012b", "Work", "Pie chart", "stats"],
        ["presentation", "f0428", "Work", "Presentation", "meeting slides"],
        ["calendar-check", "f00ef", "Work", "Schedule", "planned"],
        ["clipboard-check", "f014e", "Work", "Tasks", "checklist todo"],
        ["sitemap", "f04aa", "Work", "Structure", "org chart"],
        ["account-tie", "f0ce3", "Work", "Business", "client"],
        ["handshake", "f1218", "Work", "Deal", "partners"],
        ["target", "f04fe", "Work", "Goal", "target objective"],
        ["lightbulb-on", "f06e8", "Work", "Ideas", "brainstorm"],
        ["hammer-wrench", "f1323", "Work", "Build", "maintenance"],
        ["printer", "f042a", "Work", "Printer", "print"],
        // Games
        ["gamepad-variant", "f0297", "Games", "Gamepad", "controller games"],
        ["controller-classic", "f0b82", "Games", "Retro", "controller classic"],
        ["google-controller", "f02b4", "Games", "Controller", "joystick"],
        ["sword", "f04e5", "Games", "Sword", "rpg"],
        ["sword-cross", "f0787", "Games", "Battle", "swords fight"],
        ["chess-knight", "f0858", "Games", "Chess", "board game"],
        ["dice-5", "f01ce", "Games", "Dice", "board game"],
        ["cards-playing", "f18a1", "Games", "Cards", "poker"],
        ["trophy", "f0538", "Games", "Trophy", "achievement"],
        ["ghost", "f02a0", "Games", "Ghost", "arcade"],
        ["pac-man", "f0baf", "Games", "Arcade", "pacman retro"],
        ["steam", "f04d3", "Games", "Steam", "valve store"],
        ["microsoft-xbox", "f05b9", "Games", "Xbox", "console"],
        ["sony-playstation", "f0414", "Games", "PlayStation", "console"],
        ["nintendo-switch", "f07e1", "Games", "Switch", "nintendo console"],
        // Media
        ["play", "f040a", "Media", "Play", "videos"],
        ["play-circle", "f040c", "Media", "Play circle", "videos media"],
        ["movie-open", "f0fce", "Media", "Movies", "film cinema"],
        ["filmstrip", "f0230", "Media", "Film", "movies reel"],
        ["video", "f0567", "Media", "Video camera", "recording"],
        ["youtube", "f05c3", "Media", "YouTube", "video"],
        ["television", "f0502", "Media", "TV", "series shows"],
        ["broadcast", "f1720", "Media", "Broadcast", "live stream"],
        ["record-rec", "f044b", "Media", "Recordings", "record"],
        // Music
        ["music", "f075a", "Music", "Music", "songs"],
        ["music-note", "f0387", "Music", "Note", "song"],
        ["headphones", "f02cb", "Music", "Headphones", "audio"],
        ["guitar-electric", "f02c4", "Music", "Guitar", "band"],
        ["piano", "f067d", "Music", "Piano", "keys"],
        ["microphone", "f036c", "Music", "Microphone", "podcast vocals"],
        ["playlist-music", "f0cb8", "Music", "Playlist", "songs"],
        ["album", "f0025", "Music", "Album", "record vinyl cd"],
        ["spotify", "f04c7", "Music", "Spotify", "streaming"],
        ["radio", "f0439", "Music", "Radio", "fm"],
        ["speaker", "f04c3", "Music", "Speaker", "audio"],
        ["violin", "f060f", "Music", "Violin", "classical"],
        ["waveform", "f147d", "Music", "Waveform", "audio sound"],
        ["podcast", "f0994", "Music", "Podcast", "audio"],
        // Pictures
        ["image", "f02e9", "Pictures", "Image", "picture photo"],
        ["image-multiple", "f02f9", "Pictures", "Gallery", "photos album"],
        ["camera", "f0100", "Pictures", "Camera", "photos"],
        ["brush", "f00e3", "Pictures", "Brush", "paint art"],
        ["draw", "f0f49", "Pictures", "Drawing", "pen sketch"],
        ["vector-curve", "f0559", "Pictures", "Vector", "bezier svg design"],
        ["panorama", "f03dc", "Pictures", "Panorama", "landscape"],
        ["image-filter-hdr", "f02f5", "Pictures", "Landscape", "mountains nature"],
        ["flower", "f024a", "Pictures", "Flower", "nature"],
        ["face-man", "f0643", "Pictures", "Portrait", "face person"],
        ["camera-iris", "f0104", "Pictures", "Lens", "aperture photography"],
        ["wallpaper", "f0e09", "Pictures", "Wallpapers", "background"],
        ["monitor-screenshot", "f0e51", "Pictures", "Screenshots", "capture"],
        // Downloads
        ["download", "f01da", "Downloads", "Download", "arrow incoming"],
        ["cloud-download", "f0162", "Downloads", "Cloud download", "incoming"],
        ["tray-arrow-down", "f0120", "Downloads", "Tray", "incoming"],
        ["inbox-arrow-down", "f02fb", "Downloads", "Inbox download", "incoming"],
        ["magnet", "f0347", "Downloads", "Magnet", "torrent"],
        ["progress-download", "f0997", "Downloads", "Downloading", "progress"],
        // Archives
        ["archive", "f003c", "Archives", "Archive", "box storage"],
        ["package-variant-closed", "f03d7", "Archives", "Package", "box"],
        ["zip-box", "f05c4", "Archives", "Zip", "compressed"],
        ["safe", "f0a6a", "Archives", "Safe", "vault"],
        ["history", "f02da", "Archives", "History", "old past"],
        ["backup-restore", "f006f", "Archives", "Backup", "restore"],
        ["harddisk", "f02ca", "Archives", "Disk", "drive storage"],
        ["treasure-chest", "f0726", "Archives", "Treasure", "chest"],
        // Network
        ["lan", "f0317", "Network", "LAN", "network wired"],
        ["web", "f059f", "Network", "Web", "internet globe"],
        ["wifi", "f05a9", "Network", "Wi-Fi", "wireless"],
        ["ethernet", "f0200", "Network", "Ethernet", "cable"],
        ["router-wireless", "f0469", "Network", "Router", "wireless"],
        ["cloud", "f015f", "Network", "Cloud", "online"],
        ["cloud-sync", "f063f", "Network", "Sync", "cloud"],
        ["server-network", "f048d", "Network", "Network server", "nas"],
        ["dns", "f01d6", "Network", "DNS", "domain"],
        ["vpn", "f0582", "Network", "VPN", "tunnel"],
        ["email", "f01ee", "Network", "Email", "mail"],
        ["rss", "f046b", "Network", "RSS", "feed"],
        ["earth", "f01e7", "Network", "Globe", "world internet"],
        // Servers
        ["server", "f048b", "Servers", "Server", "rack"],
        ["server-security", "f0492", "Servers", "Secure server", "rack"],
        ["nas", "f08f3", "Servers", "NAS", "storage"],
        ["raspberry-pi", "f043f", "Servers", "Raspberry Pi", "board"],
        ["cpu-64-bit", "f0ee0", "Servers", "CPU", "processor"],
        ["memory", "f035b", "Servers", "Memory", "ram"],
        ["console-network", "f08a9", "Servers", "Remote shell", "ssh"],
        ["database-cog", "f164b", "Servers", "DB admin", "database"],
        // Security
        ["shield", "f0498", "Security", "Shield", "protection"],
        ["shield-lock", "f099d", "Security", "Protected", "secure"],
        ["lock", "f033e", "Security", "Padlock", "lock private"],
        ["key", "f0306", "Security", "Key", "password"],
        ["fingerprint", "f0237", "Security", "Fingerprint", "biometric"],
        ["incognito", "f05f9", "Security", "Incognito", "private"],
        ["safe-square", "f127c", "Security", "Vault", "safe"],
        ["eye-off", "f0209", "Security", "Hidden", "private"],
        ["security", "f0483", "Security", "Security", "guard"],
        ["certificate", "f0124", "Security", "Certificate", "ssl diploma"],
        ["form-textbox-password", "f07f5", "Security", "Password", "secret"],
        // Education
        ["school", "f0474", "Education", "School", "graduation"],
        ["book", "f00ba", "Education", "Book", "reading"],
        ["book-open-page-variant", "f05da", "Education", "Reading", "book"],
        ["bookshelf", "f125f", "Education", "Library", "books"],
        ["pencil", "f03eb", "Education", "Pencil", "write"],
        ["calculator", "f00ec", "Education", "Calculator", "math"],
        ["atom", "f0768", "Education", "Science", "atom physics"],
        ["flask", "f0093", "Education", "Chemistry", "lab flask"],
        ["microscope", "f0654", "Education", "Microscope", "biology lab"],
        ["translate", "f05ca", "Education", "Languages", "translate"],
        ["brain", "f09d1", "Education", "Brain", "study mind"],
        ["math-compass", "f0358", "Education", "Geometry", "compass math"],
        ["dna", "f0684", "Education", "DNA", "biology"],
        ["telescope", "f0b4e", "Education", "Telescope", "astronomy"],
        // Places
        ["airplane", "f001d", "Places", "Travel", "flight trip"],
        ["map", "f034d", "Places", "Map", "travel"],
        ["map-marker", "f034e", "Places", "Location", "place"],
        ["compass", "f018b", "Places", "Compass", "explore"],
        ["beach", "f0092", "Places", "Beach", "vacation holiday"],
        ["car", "f010b", "Places", "Car", "vehicle"],
        ["train", "f052c", "Places", "Train", "travel"],
        ["bike", "f00a3", "Places", "Bike", "cycling"],
        ["home-city", "f0d15", "Places", "City", "town"],
        ["tent", "f0508", "Places", "Camping", "outdoors"],
        ["bag-suitcase", "f158b", "Places", "Luggage", "travel"],
        // Life
        ["food", "f025a", "Life", "Food", "recipes"],
        ["silverware-fork-knife", "f0a70", "Life", "Recipes", "cooking food"],
        ["coffee", "f0176", "Life", "Coffee", "cafe"],
        ["cart", "f0110", "Life", "Shopping", "cart"],
        ["gift", "f0e44", "Life", "Gift", "present"],
        ["baby-carriage", "f068f", "Life", "Baby", "family"],
        ["dog", "f0a43", "Life", "Dog", "pet"],
        ["cat", "f011b", "Life", "Cat", "pet"],
        ["paw", "f03e9", "Life", "Pets", "animals"],
        ["pill", "f0402", "Life", "Health", "medicine"],
        ["hospital-box", "f02e0", "Life", "Medical", "health"],
        ["run", "f070e", "Life", "Running", "sport"],
        ["dumbbell", "f01e6", "Life", "Fitness", "gym sport"],
        ["soccer", "f04b8", "Life", "Football", "soccer sport"],
        ["tree", "f0531", "Life", "Tree", "nature"],
        ["leaf", "f032a", "Life", "Leaf", "nature green"],
        ["party-popper", "f1056", "Life", "Party", "celebration"],
        ["account-heart", "f0899", "Life", "Family", "people love"],
        // Finance
        ["currency-usd", "f01c1", "Finance", "Dollar", "money"],
        ["currency-eur", "f01ad", "Finance", "Euro", "money"],
        ["bank", "f0070", "Finance", "Bank", "finance"],
        ["wallet", "f0584", "Finance", "Wallet", "money"],
        ["cash", "f0114", "Finance", "Cash", "money"],
        ["credit-card", "f0fef", "Finance", "Card", "payment"],
        ["piggy-bank", "f1007", "Finance", "Savings", "money"],
        ["bitcoin", "f0813", "Finance", "Bitcoin", "crypto"],
        ["chart-areaspline", "f0127", "Finance", "Investments", "stocks"],
        // Communication
        ["chat", "f0b79", "Communication", "Chat", "messages"],
        ["forum", "f028c", "Communication", "Forum", "discussion"],
        ["phone", "f03f2", "Communication", "Phone", "calls"],
        ["message-text", "f0369", "Communication", "Message", "sms"],
        ["send", "f048a", "Communication", "Send", "outgoing"],
        ["bullhorn", "f00e6", "Communication", "Announcements", "megaphone"],
        // Hardware
        ["monitor", "f0379", "Hardware", "Display", "desktop screen"],
        ["laptop", "f0322", "Hardware", "Laptop", "computer"],
        ["cellphone", "f011c", "Hardware", "Phone", "mobile android"],
        ["tablet", "f04f6", "Hardware", "Tablet", "ipad"],
        ["keyboard", "f030c", "Hardware", "Keyboard", "input"],
        ["mouse", "f037d", "Hardware", "Mouse", "input"],
        ["usb", "f0553", "Hardware", "USB", "device"],
        ["chip", "f061a", "Hardware", "Chip", "electronics"],
        ["printer-3d", "f042b", "Hardware", "3D printer", "printing"]
    ]

    readonly property var categories: [
        { id: "General", label: "General" },
        { id: "Documents", label: "Documents" },
        { id: "Development", label: "Development" },
        { id: "Work", label: "Work & projects" },
        { id: "Games", label: "Games" },
        { id: "Media", label: "Videos & media" },
        { id: "Music", label: "Music" },
        { id: "Pictures", label: "Pictures" },
        { id: "Downloads", label: "Downloads" },
        { id: "Archives", label: "Archives" },
        { id: "Network", label: "Network" },
        { id: "Servers", label: "Servers" },
        { id: "Security", label: "Security" },
        { id: "Education", label: "Education & science" },
        { id: "Places", label: "Travel & places" },
        { id: "Life", label: "Home & life" },
        { id: "Finance", label: "Finance" },
        { id: "Communication", label: "Communication" },
        { id: "Hardware", label: "Hardware" }
    ]

    readonly property var byId: {
        var m = {};
        for (var i = 0; i < root.catalog.length; i++) {
            var e = root.catalog[i];
            m[e[0]] = { id: e[0], glyph: e[1], cat: e[2], label: e[3], tags: e[4] };
        }
        return m;
    }

    function glyphChar(hex) { return hex ? String.fromCodePoint(parseInt(hex, 16)) : ""; }

    //  The proportional build of the same Nerd Font: there a glyph's advance is
    //  its real width, so a symbol centres exactly (in the default build the
    //  Material Design glyphs are wider than their advance and lean right).
    readonly property string symbolFont: "JetBrainsMono Nerd Font Propo"

    //  Where the folder glyph's ink sits inside its Text box, per pixel of font
    //  size: measured once from the real font, so the symbol lands on the
    //  folder at every size (list, grid zoom, HiDPI) and survives a font change.
    TextMetrics { id: folderTm; font.family: Theme.fontFamily; font.pixelSize: 100; text: Icons.folder }
    FontMetrics { id: folderFm; font.family: Theme.fontFamily; font.pixelSize: 100 }
    readonly property var folderInk: {
        var r = folderTm.tightBoundingRect;
        if (!r || r.width <= 0) return { x: 0, y: 0.25, w: 0.9, h: 0.8, adv: 0.6 };
        return { x: r.x / 100, y: (folderFm.ascent + r.y) / 100, w: r.width / 100,
                 h: r.height / 100, adv: folderTm.advanceWidth / 100 };
    }

    //  Library entries for the picker: `cat` "" = all; `query` matches the
    //  English label, its translation, the category and the search words.
    function search(query, cat) {
        var q = (query || "").trim().toLowerCase();
        var out = [];
        for (var i = 0; i < root.catalog.length; i++) {
            var e = root.catalog[i];
            if (cat && e[2] !== cat) continue;
            if (q !== "") {
                var hay = (e[0] + " " + e[3] + " " + I18n.t(e[3]) + " " + e[4] + " "
                           + e[2] + " " + I18n.t(root.catLabel(e[2]))).toLowerCase();
                if (hay.indexOf(q) === -1) continue;
            }
            out.push({ id: e[0], glyph: e[1], cat: e[2], label: e[3] });
        }
        return out;
    }
    function catLabel(id) {
        for (var i = 0; i < root.categories.length; i++)
            if (root.categories[i].id === id) return root.categories[i].label;
        return id;
    }

    // ---- what each folder shows -------------------------------------------
    property var folders: ({})       // path -> { icon, glyph, dev, ino }
    property string imageDir: ""
    property bool ready: false
    property bool _loading: false

    readonly property var byInode: {
        var m = {};
        for (var p in root.folders) {
            var r = root.folders[p];
            if (r.dev !== undefined && r.ino !== undefined) m[r.dev + ":" + r.ino] = p;
        }
        return m;
    }

    //  The id the user chose for `path` ("" = none) / the built-in default.
    function customId(path) {
        var r = root.folders[path];
        return r ? r.icon : "";
    }
    function defaultId(path) {
        var key = Places.byPath[path];
        if (key !== undefined && Places.xdgIcons[key] !== undefined) return "md:" + Places.xdgIcons[key];
        if (path === Places.home) return "md:home";
        return "";
    }

    //  An icon id -> what to draw: { glyph } or { image } (null for none).
    function render(id, glyphHex) {
        if (!id) return null;
        if (id.indexOf("img:") === 0) {
            if (root.imageDir === "") return null;
            var p = root.imageDir + "/" + id.substring(4);
            return { image: "file://" + p.split("/").map(encodeURIComponent).join("/") };
        }
        var e = root.byId[id.substring(3)];
        var hex = glyphHex || (e ? e.glyph : "");
        return hex ? { glyph: root.glyphChar(hex) } : null;
    }

    //  What a folder at `path` shows on top of its artwork, or null.
    function emblemFor(path) {
        var r = root.folders[path];
        if (r) return root.render(r.icon, r.glyph);
        return root.render(root.defaultId(path), "");
    }
    //  The same, as one symbol for the sidebar ("" when there is none or the
    //  choice is an image — the sidebar then keeps a plain folder).
    function sidebarGlyph(path) {
        var em = root.emblemFor(path);
        return em && em.glyph ? em.glyph : "";
    }

    function hasCustomUnder(prefix) {
        for (var p in root.folders)
            if (p === prefix || p.indexOf(prefix + "/") === 0) return true;
        return false;
    }

    function _apply(r) {
        if (!r || r.error || !r.folders) return;
        root.folders = r.folders;
        root.imageDir = r.imageDir || "";
        root.ready = true;
    }

    function refresh() {
        if (root._loading) return;
        root._loading = true;
        FmHelper.run(["icons"], function(r) { root._loading = false; root._apply(r); });
    }

    function set(path, id, cb) {
        var e = root.byId[id];
        if (!e) return;
        FmHelper.run(["icon-set", path, "md:" + id, e.glyph], function(r, code) {
            root._apply(r);
            if (cb) cb(code === 0 && r && !r.error, r && r.error ? r.error : "");
        });
    }
    function setImage(path, file, cb) {
        FmHelper.run(["icon-image", path, file], function(r, code) {
            root._apply(r);
            if (cb) cb(code === 0 && r && !r.error, r && r.error ? r.error : "");
        });
    }
    function reset(path, cb) {
        FmHelper.run(["icon-reset", path], function(r) { root._apply(r); if (cb) cb(true, ""); });
    }
    //  Vexyon renamed or moved `from` to `to`: carry its icon (and the ones of
    //  folders inside it) along. Only spawns the helper when there is any.
    function moved(from, to) {
        if (!root.hasCustomUnder(from)) return;
        FmHelper.run(["icon-moved", from, to], root._apply);
    }
    //  Folders in a listing that carry a stored folder's device+inode under a
    //  new path: renamed/moved by another program. `entries` = [{ path, id }].
    function adopt(entries) {
        var cand = [];
        for (var i = 0; i < entries.length; i++) {
            var e = entries[i];
            if (!e.id || root.folders[e.path]) continue;
            var old = root.byInode[e.id];
            if (old !== undefined && old !== e.path) cand.push(e.path);
        }
        if (cand.length) FmHelper.run(["icon-adopt"].concat(cand), root._apply);
    }

    // ---- contrast ------------------------------------------------------------
    //  A symbol must stay readable on any accent of any theme, dark or light:
    //  of the theme's own colours, take onAccent unless it is too close to the
    //  folder colour, then whichever of base / text contrasts most (WCAG ratio).
    function _lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    function lum(c) { return 0.2126 * root._lin(c.r) + 0.7152 * root._lin(c.g) + 0.0722 * root._lin(c.b); }
    function contrast(a, b) {
        var la = root.lum(a), lb = root.lum(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }
    function inkOn(bg) {
        if (root.contrast(Theme.onAccent, bg) >= 3.0) return Theme.onAccent;
        return root.contrast(Theme.base, bg) >= root.contrast(Theme.text, bg) ? Theme.base : Theme.text;
    }
}
