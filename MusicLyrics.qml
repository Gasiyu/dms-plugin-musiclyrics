import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property string navidromeUrl: pluginData.navidromeUrl ?? ""
    property string navidromeUser: pluginData.navidromeUser ?? ""
    property string navidromePassword: pluginData.navidromePassword ?? ""
    property bool cachingEnabled: pluginData.cachingEnabled ?? true
    property string extraLrcDirectory: pluginData.extraLrcDirectory ?? ""
    property string statusPaneButton: pluginData.statusPaneButton ?? "left"
    property string lyricsPaneButton: pluginData.lyricsPaneButton ?? "right"

    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    property var allPlayers: MprisController.availablePlayers

    // -------------------------------------------------------------------------
    // Enum namespaces
    // -------------------------------------------------------------------------

    // Chip-visible statuses for navidromeStatus, lrclibStatus, and cacheStatus.
    // Values are globally unique so all three properties share one _chipMeta map.
    QtObject {
        id: status
        readonly property int none: 0
        readonly property int searching: 1
        readonly property int found: 2
        readonly property int notFound: 3
        readonly property int error: 4
        readonly property int skippedConfig: 5
        readonly property int skippedFound: 6
        readonly property int skippedPlain: 7
        readonly property int cacheHit: 11
        readonly property int cacheMiss: 12
        readonly property int cacheDisabled: 13
    }

    // Lyrics-fetch lifecycle.
    QtObject {
        id: lyricState
        readonly property int idle: 0
        readonly property int loading: 1
        readonly property int synced: 2
        readonly property int notFound: 3
    }

    // Lyrics sources.
    QtObject {
        id: lyricSrc
        readonly property int none: 0
        readonly property int navidrome: 1
        readonly property int lrclib: 2
        readonly property int cache: 3
        readonly property int musixmatch: 4
        readonly property int local: 5 // legacy local source id (kept for cached entries)
        readonly property int metadata: 6
        readonly property int localLrc: 7
    }

    // -------------------------------------------------------------------------
    // Lyrics state
    // -------------------------------------------------------------------------

    property var lyricsLines: []
    property int currentLineIndex: -1
    property bool lyricsLoading: lyricStatus === lyricState.loading
    property string _lastFetchedTrack: ""
    property string _lastFetchedArtist: ""
    property var _cancelActiveFetch: null

    // Chip status properties
    property int navidromeStatus: status.none
    property int lrclibStatus: status.none
    property int musixmatchStatus: status.none
    property int cacheStatus: status.none
    property int metadataStatus: status.none
    property int localLrcStatus: status.none

    // Fetch state and source
    property int lyricStatus: lyricState.idle
    property int lyricSource: lyricSrc.none

    // Track current song info
    property string currentTitle: activePlayer?.trackTitle ?? ""
    property string currentArtist: activePlayer?.trackArtist ?? ""
    property string currentAlbum: activePlayer?.trackAlbum ?? ""
    property real currentDuration: activePlayer?.length ?? 0

    // Current lyric line for bar pill display

    property string currentLyricText: {
        if (lyricsLoading)
            return "Searching lyrics…";
        if (lyricsLines.length > 0 && currentLineIndex >= 0)
            return lyricsLines[currentLineIndex].text || "♪ ♪ ♪";
        if (currentTitle)
            return currentTitle;
        return "No lyrics";
    }

    property bool _configValid: navidromeUrl !== "" && navidromeUser !== "" && navidromePassword !== ""

    on_ConfigValidChanged: {
        console.info("[MusicLyrics] Navidrome configured: " + (_configValid ? "yes (" + navidromeUrl + ")" : "no"));
        if (activePlayer && currentTitle)
            fetchDebounceTimer.restart();
    }

    // Debounce timer — avoids double-fetch when title and artist change simultaneously
    Timer {
        id: fetchDebounceTimer
        interval: 300
        onTriggered: root.fetchLyricsIfNeeded()
    }
    onCurrentTitleChanged: fetchDebounceTimer.restart()
    onCurrentArtistChanged: fetchDebounceTimer.restart()

    // Force-update toggle to poll MPRIS position
    property bool _forceUpdate: false

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _resetLyricsState() {
        lyricsLines = [];
        currentLineIndex = -1;
        navidromeStatus = status.none;
        lrclibStatus = status.none;
        musixmatchStatus = status.none;
        cacheStatus = status.none;
        metadataStatus = status.none;
        localLrcStatus = status.none;
        lyricStatus = lyricState.loading;
        lyricSource = lyricSrc.none;
    }

    // Sets the "no synced lyrics" state, used by musixmatch handlers
    function _setMusixmatchNotFound(musixmatchStatusVal) {
        musixmatchStatus = musixmatchStatusVal;
        _fetchFromLrclib(_lastFetchedTrack, _lastFetchedArtist);
    }

    // Sets the final "no synced lyrics" state after all sources exhausted
    function _setFinalNotFound(lrclibStatusVal) {
        lrclibStatus = lrclibStatusVal;
        lyricStatus = lyricState.notFound;
        root._cancelActiveFetch = null;
    }

    function _normalizeIdleSourceStatuses() {
        if (metadataStatus === status.none)
            metadataStatus = status.skippedConfig;
        if (localLrcStatus === status.none)
            localLrcStatus = status.skippedConfig;
    }

    // -------------------------------------------------------------------------
    // Cache helpers
    // -------------------------------------------------------------------------

    function _fnv1a32(str) {
        var hash = 0x811c9dc5;
        for (var i = 0; i < str.length; i++) {
            hash = ((hash ^ str.charCodeAt(i)) * 0x01000193) >>> 0;
        }
        return ("00000000" + hash.toString(16)).slice(-8);
    }

    function _cacheKey(title, artist) {
        return _fnv1a32((title + "\x00" + artist).toLowerCase());
    }

    readonly property string _defaultLyricsDir: "$HOME/.cache/musicLyrics"
    readonly property string _cacheDir: {
        const homeDir = Quickshell.env("HOME") || "";
        const configured = (pluginData.lyricsDirectory || _defaultLyricsDir).trim();
        const rawPath = configured.length > 0 ? configured : _defaultLyricsDir;
        if (rawPath.startsWith("$HOME/") && homeDir.length > 0)
            return homeDir + rawPath.substring(5);
        if (rawPath.startsWith("~/") && homeDir.length > 0)
            return homeDir + rawPath.substring(1);
        return rawPath;
    }
    readonly property string _expandedExtraLrcDirectory: {
        const homeDir = Quickshell.env("HOME") || "";
        const rawPath = (extraLrcDirectory || "").trim();
        if (!rawPath)
            return "";
        if (rawPath.startsWith("$HOME/") && homeDir.length > 0)
            return homeDir + rawPath.substring(5);
        if (rawPath.startsWith("~/") && homeDir.length > 0)
            return homeDir + rawPath.substring(1);
        return rawPath;
    }

    function _cacheFilePath(title, artist) {
        return _cacheDir + "/" + _cacheKey(title, artist) + ".json";
    }

    function _currentTrackFilePath() {
        const raw = activePlayer ? (activePlayer.trackUrl || activePlayer.url || "") : "";
        if (!raw)
            return "";
        if (raw.startsWith("file://")) {
            try {
                return decodeURIComponent(raw.substring(7));
            } catch (e) {
                return raw.substring(7);
            }
        }
        if (raw.startsWith("/"))
            return raw;
        return "";
    }

    function seekToLyricLine(index) {
        if (!activePlayer || index < 0 || index >= lyricsLines.length)
            return;
        const line = lyricsLines[index];
        if (!line || typeof line.time !== "number" || !Number.isFinite(line.time))
            return;

        const duration = Math.max(0, activePlayer.length || 0);
        if (duration > 0) {
            const clamped = Math.max(0, Math.min(duration * 0.99, line.time));
            activePlayer.position = clamped;
        } else {
            activePlayer.position = Math.max(0, line.time);
        }
    }

    // Static one-shot timer for XHR request timeouts
    Timer {
        id: xhrTimeoutTimer
        repeat: false
        property var onTimeout: null
        onTriggered: if (onTimeout)
            onTimeout()
    }

    // Static one-shot timer for retry delays
    Timer {
        id: xhrRetryTimer
        repeat: false
        property var onRetry: null
        onTriggered: if (onRetry)
            onRetry()
    }

    // Cache directory creation
    property bool _cacheDirReady: false

    Process {
        id: mkdirProcess
        command: ["mkdir", "-p", root._cacheDir]
        running: false
    }

    function _ensureCacheDir() {
        if (_cacheDirReady)
            return;
        _cacheDirReady = true;
        mkdirProcess.running = true;
    }

    on_CacheDirChanged: {
        _cacheDirReady = false;
    }

    // Cache read using FileView
    Component {
        id: cacheReaderComponent
        FileView {
            property var callback
            blockLoading: true
            preload: true
            onLoaded: {
                try {
                    callback(JSON.parse(text()));
                } catch (e) {
                    callback(null);
                }
                destroy();
            }
            onLoadFailed: {
                callback(null);
                destroy();
            }
        }
    }

    function readFromCache(title, artist, callback) {
        cacheReaderComponent.createObject(root, {
            path: _cacheFilePath(title, artist),
            callback: callback
        });
    }

    // Cache write using FileView
    Component {
        id: cacheWriterComponent
        FileView {
            property string cTitle
            property string cArtist
            blockWrites: false
            atomicWrites: true
            onSaved: {
                console.info("[MusicLyrics] Cache: written for \"" + cTitle + "\" by " + cArtist + " (" + path + ")");
                destroy();
            }
            onSaveFailed: {
                console.warn("[MusicLyrics] Cache: failed to write for \"" + cTitle + "\"");
                destroy();
            }
        }
    }

    function writeToCache(title, artist, lines, source) {
        _ensureCacheDir();
        var writer = cacheWriterComponent.createObject(root, {
            path: _cacheFilePath(title, artist),
            cTitle: title,
            cArtist: artist
        });
        writer.setText(JSON.stringify({
            lines: lines,
            source: source
        }));
    }

    property var _localLyricsCallback: null
    property string _localLyricsStdout: ""

    Process {
        id: localLyricsLookupProcess
        running: false
        command: []

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function (data) {
                if (!data)
                    return;
                if (root._localLyricsStdout.length > 0)
                    root._localLyricsStdout += "\n";
                root._localLyricsStdout += data;
            }
        }

        onExited: function () {
            const callback = root._localLyricsCallback;
            root._localLyricsCallback = null;
            if (!callback)
                return;

            const raw = (root._localLyricsStdout || "").trim();
            root._localLyricsStdout = "";
            if (!raw) {
                callback(null, "");
                return;
            }

            try {
                const payload = JSON.parse(raw);
                callback(payload.text || null, payload.source || "");
            } catch (e) {
                console.warn("[MusicLyrics] Local lyrics parse failed: " + e);
                callback(null, "");
            }
        }
    }

    function _lookupLocalLyrics(title, artist, callback) {
        const trackPath = _currentTrackFilePath();
        const extraDir = _expandedExtraLrcDirectory;
        if (!trackPath && !extraDir) {
            callback(null, "");
            return;
        }

        const script = `import json, os, subprocess, sys
title, artist, track_path, extra_dir = sys.argv[1:5]

def safe_name(s):
    return (s or "").replace("/", "_").replace("\\\\", "_").strip()

def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception:
        return ""

def find_file_in_dir(base_dir, names):
    if not base_dir or not os.path.isdir(base_dir):
        return ""
    seen = set()
    for n in names:
        if not n:
            continue
        p = os.path.join(base_dir, n + ".lrc")
        if p in seen:
            continue
        seen.add(p)
        if os.path.isfile(p):
            text = read_text(p)
            if text.strip():
                return text
    return ""

def find_file_recursive(root_dir, names):
    if not root_dir or not os.path.isdir(root_dir):
        return ""
    seen = set()
    for d, _dirs, _files in os.walk(root_dir):
        for n in names:
            if not n:
                continue
            p = os.path.join(d, n + ".lrc")
            if p in seen:
                continue
            seen.add(p)
            if os.path.isfile(p):
                text = read_text(p)
                if text.strip():
                    return text
    return ""

def read_metadata_lrc(path):
    if not path or not os.path.isfile(path):
        return ""
    try:
        proc = subprocess.run(
            ["ffprobe", "-v", "quiet", "-of", "json", "-show_entries", "format_tags", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout:
            return ""
        data = json.loads(proc.stdout)
        tags = ((data.get("format") or {}).get("tags") or {})
        for key in ["synchronized_lyrics", "SYNCEDLYRICS", "syncedlyrics", "lyrics", "LYRICS"]:
            val = tags.get(key)
            if isinstance(val, str) and val.strip():
                return val
    except Exception:
        return ""
    return ""

base_dir = os.path.dirname(track_path) if track_path else ""
track_stem = os.path.splitext(os.path.basename(track_path))[0] if track_path else ""
names = []
for candidate in [track_stem, safe_name(title), safe_name(artist + " - " + title), safe_name(title + " - " + artist)]:
    if candidate and candidate not in names:
        names.append(candidate)

metadata = read_metadata_lrc(track_path)
if metadata.strip():
    print(json.dumps({"source": "metadata", "text": metadata}))
    raise SystemExit(0)

text = find_file_in_dir(base_dir, names)
if not text.strip():
    text = find_file_recursive(extra_dir, names)
if text.strip():
    print(json.dumps({"source": "file", "text": text}))
else:
    print("")`;

        _localLyricsStdout = "";
        _localLyricsCallback = callback;
        localLyricsLookupProcess.command = ["python3", "-c", script, title || "", artist || "", trackPath || "", extraDir || ""];
        localLyricsLookupProcess.running = true;
    }

    // -------------------------------------------------------------------------
    // Fetch orchestration
    // -------------------------------------------------------------------------

    function fetchLyricsIfNeeded() {
        if (!currentTitle)
            return;
        if (currentTitle === _lastFetchedTrack && currentArtist === _lastFetchedArtist)
            return;

        // Cancel any in-flight XHR before starting fresh
        if (_cancelActiveFetch) {
            _cancelActiveFetch();
            _cancelActiveFetch = null;
        }
        if (localLyricsLookupProcess.running) {
            localLyricsLookupProcess.running = false;
            _localLyricsCallback = null;
            _localLyricsStdout = "";
        }

        _lastFetchedTrack = currentTitle;
        _lastFetchedArtist = currentArtist;
        _resetLyricsState();

        var durationStr = currentDuration > 0 ? (Math.floor(currentDuration / 60) + ":" + ("0" + Math.floor(currentDuration % 60)).slice(-2)) : "unknown";
        console.info("[MusicLyrics] ▶ Track changed: \"" + currentTitle + "\" by " + currentArtist + (currentAlbum ? " [" + currentAlbum + "]" : "") + " (" + durationStr + ")");

        var capturedTitle = currentTitle;
        var capturedArtist = currentArtist;

        function _startRemoteFetch() {
            if (_configValid) {
                _fetchFromNavidrome(capturedTitle, capturedArtist);
            } else {
                navidromeStatus = status.skippedConfig;
                console.info("[MusicLyrics] Navidrome: skipped (not configured)");
                _fetchFromMusixmatch(capturedTitle, capturedArtist);
            }
        }

        function _startFetch() {
            const hasTrackPath = !!_currentTrackFilePath();
            const hasLocalLrcSearch = hasTrackPath || _expandedExtraLrcDirectory !== "";
            root.metadataStatus = hasTrackPath ? status.searching : status.skippedConfig;
            root.localLrcStatus = hasLocalLrcSearch ? status.searching : status.skippedConfig;

            _lookupLocalLyrics(capturedTitle, capturedArtist, function (lrcText, localSource) {
                if (capturedTitle !== root._lastFetchedTrack || capturedArtist !== root._lastFetchedArtist)
                    return;

                if (lrcText) {
                    const parsed = root.parseLrc(lrcText);
                    if (parsed.length > 0) {
                        root.lyricsLines = parsed;
                        root.lyricStatus = lyricState.synced;
                        root.lyricSource = localSource === "metadata" ? lyricSrc.metadata : lyricSrc.localLrc;
                        root.metadataStatus = localSource === "metadata" ? status.found : (hasTrackPath ? status.notFound : status.skippedConfig);
                        root.localLrcStatus = localSource === "metadata" ? status.skippedFound : status.found;
                        root.navidromeStatus = status.skippedFound;
                        root.lrclibStatus = status.skippedFound;
                        root.musixmatchStatus = status.skippedFound;
                        console.info("[MusicLyrics] ✓ Local " + localSource + ": synced lyrics found (" + parsed.length + " lines) for \"" + capturedTitle + "\"");
                        if (root.cachingEnabled)
                            root.writeToCache(capturedTitle, capturedArtist, parsed, root.lyricSource);
                        return;
                    }
                }

                root.metadataStatus = hasTrackPath ? status.notFound : status.skippedConfig;
                root.localLrcStatus = hasLocalLrcSearch ? status.notFound : status.skippedConfig;
                _startRemoteFetch();
            });
        }

        if (cachingEnabled) {
            readFromCache(capturedTitle, capturedArtist, function (cached) {
                // Guard: track may have changed while the file read was in progress
                if (capturedTitle !== root._lastFetchedTrack || capturedArtist !== root._lastFetchedArtist)
                    return;
                if (cached && cached.lines && cached.lines.length > 0) {
                    root.lyricsLines = cached.lines;
                    root.lyricStatus = lyricState.synced;
                    root.lyricSource = lyricSrc.cache;
                    root.cacheStatus = status.cacheHit;
                    root.metadataStatus = status.skippedFound;
                    root.localLrcStatus = status.skippedFound;
                    root.navidromeStatus = status.skippedFound;
                    root.lrclibStatus = status.skippedFound;
                    root.musixmatchStatus = status.skippedFound;
                    root._normalizeIdleSourceStatuses();
                    console.info("[MusicLyrics] ✓ Cache: lyrics loaded for \"" + capturedTitle + "\" (" + cached.lines.length + " lines)");
                    return;
                }
                root.cacheStatus = status.cacheMiss;
                _startFetch();
            });
        } else {
            cacheStatus = status.cacheDisabled;
            _normalizeIdleSourceStatuses();
            _startFetch();
        }
    }

    // -------------------------------------------------------------------------
    // XMLHttpRequest helper
    // -------------------------------------------------------------------------

    function _xhrGet(url, timeoutMs, onSuccess, onError, customHeaders) {
        var retriesLeft = 2;
        var retryDelay = 3000;
        var attempt = 0;
        var cancelled = false;
        var currentXhr = null;

        function _attempt() {
            attempt++;
            currentXhr = new XMLHttpRequest();
            var done = false;

            xhrTimeoutTimer.stop();
            xhrTimeoutTimer.interval = timeoutMs;
            xhrTimeoutTimer.onTimeout = function () {
                if (!done && !cancelled) {
                    done = true;
                    currentXhr.abort();
                    _retry("timeout");
                }
            };
            xhrTimeoutTimer.start();

            currentXhr.onreadystatechange = function () {
                if (currentXhr.readyState !== XMLHttpRequest.DONE || done || cancelled)
                    return;
                done = true;
                xhrTimeoutTimer.stop();
                if (currentXhr.status === 0) {
                    _retry("network error (status 0)");
                    return;
                }
                var responseBody = (currentXhr.responseText || "").trim();
                if (responseBody.length === 0) {
                    _retry("empty response (HTTP " + currentXhr.status + ")");
                    return;
                }
                onSuccess(currentXhr.responseText, currentXhr.status);
            };
            currentXhr.open("GET", url);
            if (customHeaders) {
                for (var key in customHeaders)
                    currentXhr.setRequestHeader(key, customHeaders[key]);
            } else {
                currentXhr.setRequestHeader("User-Agent", "DankMaterialShell MusicLyrics/1.4.0 (https://github.com/Gasiyu/dms-plugin-musiclyrics)");
                currentXhr.setRequestHeader("Accept", "application/json");
            }
            currentXhr.send();
        }

        function _retry(errMsg) {
            if (cancelled)
                return;
            if (retriesLeft > 0) {
                retriesLeft--;
                console.warn("[MusicLyrics] _xhrGet: " + errMsg + " — retrying (attempt " + (attempt + 1) + ", " + retriesLeft + " left): " + url);
                xhrRetryTimer.stop();
                xhrRetryTimer.interval = retryDelay;
                xhrRetryTimer.onRetry = _attempt;
                xhrRetryTimer.start();
            } else {
                onError(errMsg);
            }
        }

        _attempt();

        // Return a cancel function the caller can invoke to abort the entire chain
        return function cancel() {
            cancelled = true;
            xhrTimeoutTimer.stop();
            xhrRetryTimer.stop();
            if (currentXhr)
                currentXhr.abort();
            console.info("[MusicLyrics] ⊘ XHR cancelled: " + url);
        };
    }

    // -------------------------------------------------------------------------
    // Navidrome fetch
    // -------------------------------------------------------------------------

    // Builds a Navidrome REST URL with common auth params appended
    function _navidromeUrl(endpoint, extraParams) {
        var base = navidromeUrl.replace(/\/+$/, "") + "/rest/" + endpoint;
        var auth = "u=" + encodeURIComponent(navidromeUser) + "&p=" + encodeURIComponent(navidromePassword) + "&v=1.16.1&c=DankMaterialShell&f=json";
        return base + "?" + (extraParams ? extraParams + "&" : "") + auth;
    }

    function _fetchFromNavidrome(expectedTitle, expectedArtist) {
        navidromeStatus = status.searching;
        console.info("[MusicLyrics] Navidrome: searching for \"" + expectedTitle + "\" by " + expectedArtist);

        var searchUrl = _navidromeUrl("search3", "query=" + encodeURIComponent(expectedTitle) + "&songCount=5&albumCount=0&artistCount=0");
        console.log("[MusicLyrics] Navidrome: search URL = " + searchUrl);

        root._cancelActiveFetch = _xhrGet(searchUrl, 15000, function (responseText, httpStatus) {
            var rawData = (responseText || "").trim();
            console.log("[MusicLyrics] Navidrome: search response length = " + rawData.length);
            if (rawData.length === 0) {
                root.navidromeStatus = status.error;
                console.warn("[MusicLyrics] Navidrome: empty search response (HTTP " + httpStatus + ")");
                root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                return;
            }
            try {
                var result = JSON.parse(rawData);
                var songs = result["subsonic-response"]?.searchResult3?.song;
                if (!songs || songs.length === 0) {
                    root.navidromeStatus = status.notFound;
                    console.info("[MusicLyrics] ✗ Navidrome: no matching songs found for \"" + expectedTitle + "\"");
                    root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                    return;
                }

                // Prefer exact title match, fall back to first result
                var songId = songs[0].id;
                for (var i = 0; i < songs.length; i++) {
                    if (songs[i].title.toLowerCase() === expectedTitle.toLowerCase()) {
                        songId = songs[i].id;
                        break;
                    }
                }

                console.log("[MusicLyrics] Navidrome: song matched (id: " + songId + "), fetching lyrics…");
                root._fetchNavidromeLyrics(songId, expectedTitle, expectedArtist);
            } catch (e) {
                root.navidromeStatus = status.error;
                console.warn("[MusicLyrics] Navidrome: failed to parse search response — " + e);
                console.warn("[MusicLyrics] Navidrome: raw data: " + rawData.substring(0, 200));
                root._fetchFromMusixmatch(expectedTitle, expectedArtist);
            }
        }, function (errMsg) {
            root.navidromeStatus = status.error;
            console.warn("[MusicLyrics] Navidrome: search request failed — " + errMsg);
            root._fetchFromMusixmatch(expectedTitle, expectedArtist);
        });
    }

    function _fetchNavidromeLyrics(songId, expectedTitle, expectedArtist) {
        var lyricsUrl = _navidromeUrl("getLyricsBySongId", "id=" + encodeURIComponent(songId));
        console.log("[MusicLyrics] Navidrome: lyrics URL = " + lyricsUrl);

        root._cancelActiveFetch = _xhrGet(lyricsUrl, 15000, function (responseText, httpStatus) {
            var rawData = (responseText || "").trim();
            console.log("[MusicLyrics] Navidrome: lyrics response length = " + rawData.length);
            if (rawData.length === 0) {
                root.navidromeStatus = status.error;
                console.warn("[MusicLyrics] Navidrome: empty lyrics response (HTTP " + httpStatus + ")");
                root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                return;
            }
            try {
                var result = JSON.parse(rawData);
                var lyricsList = result["subsonic-response"]?.lyricsList?.structuredLyrics;
                if (!lyricsList || lyricsList.length === 0) {
                    root.navidromeStatus = status.notFound;
                    console.info("[MusicLyrics] ✗ Navidrome: no lyrics available for \"" + expectedTitle + "\"");
                    root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                    return;
                }

                var synced = null;
                var unsynced = null;
                for (var i = 0; i < lyricsList.length; i++) {
                    if (lyricsList[i].synced) {
                        synced = lyricsList[i];
                        break;
                    } else {
                        unsynced = lyricsList[i];
                    }
                }

                if (synced && synced.line) {
                    var lines = synced.line.map(function (l) {
                        return {
                            time: (l.start || 0) / 1000,
                            text: l.value || ""
                        };
                    });
                    root.lyricsLines = lines;
                    root.navidromeStatus = status.found;
                    root.lyricStatus = lyricState.synced;
                    root.lyricSource = lyricSrc.navidrome;
                    root.lrclibStatus = status.skippedFound;
                    root.musixmatchStatus = status.skippedFound;
                    console.info("[MusicLyrics] ✓ Navidrome: synced lyrics found (" + lines.length + " lines) for \"" + expectedTitle + "\"");
                    root._cancelActiveFetch = null;
                    if (root.cachingEnabled)
                        root.writeToCache(expectedTitle, expectedArtist, lines, lyricSrc.navidrome);
                } else if (unsynced && unsynced.line) {
                    root.navidromeStatus = status.skippedPlain;
                    console.info("[MusicLyrics] ✗ Navidrome: only plain lyrics found for \"" + expectedTitle + "\" (skipping, synced only)");
                    root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                } else {
                    root.navidromeStatus = status.notFound;
                    console.info("[MusicLyrics] ✗ Navidrome: lyrics structure empty for \"" + expectedTitle + "\"");
                    root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                }
            } catch (e) {
                root.navidromeStatus = status.error;
                console.warn("[MusicLyrics] Navidrome: failed to parse lyrics response — " + e);
                console.warn("[MusicLyrics] Navidrome: raw data: " + rawData.substring(0, 200));
                root._fetchFromMusixmatch(expectedTitle, expectedArtist);
            }
        }, function (errMsg) {
            root.navidromeStatus = status.error;
            console.warn("[MusicLyrics] Navidrome: lyrics request failed — " + errMsg);
            root._fetchFromMusixmatch(expectedTitle, expectedArtist);
        });
    }

    // -------------------------------------------------------------------------
    // lrclib.net fetch
    // -------------------------------------------------------------------------

    function _fetchFromLrclib(expectedTitle, expectedArtist) {
        if (lyricStatus === lyricState.synced) {
            lrclibStatus = status.skippedFound;
            console.info("[MusicLyrics] lrclib: skipped (synced lyrics already found)");
            return;
        }

        lrclibStatus = status.searching;
        console.info("[MusicLyrics] lrclib: searching for \"" + expectedTitle + "\" by " + expectedArtist);

        var url = "https://lrclib.net/api/get?artist_name=" + encodeURIComponent(expectedArtist) + "&track_name=" + encodeURIComponent(expectedTitle);
        if (currentAlbum)
            url += "&album_name=" + encodeURIComponent(currentAlbum);
        if (currentDuration > 0)
            url += "&duration=" + Math.round(currentDuration);

        root._cancelActiveFetch = _xhrGet(url, 20000, function (responseText, httpStatus) {
            var rawData = (responseText || "").trim();
            console.log("[MusicLyrics] lrclib: response length = " + rawData.length);
            if (rawData.length === 0) {
                root._setFinalNotFound(status.error);
                console.warn("[MusicLyrics] lrclib: empty response (HTTP " + httpStatus + ")");
                return;
            }
            try {
                var result = JSON.parse(rawData);
                if (result.statusCode === 404 || result.error) {
                    root._setFinalNotFound(status.notFound);
                    console.info("[MusicLyrics] ✗ lrclib: no lyrics found for \"" + expectedTitle + "\"");
                } else if (result.syncedLyrics) {
                    root.lyricsLines = root.parseLrc(result.syncedLyrics);
                    root.lrclibStatus = status.found;
                    root.lyricStatus = lyricState.synced;
                    root.lyricSource = lyricSrc.lrclib;
                    console.info("[MusicLyrics] ✓ lrclib: synced lyrics found (" + root.lyricsLines.length + " lines) for \"" + expectedTitle + "\"");
                    root._cancelActiveFetch = null;
                    if (root.cachingEnabled)
                        root.writeToCache(expectedTitle, expectedArtist, root.lyricsLines, lyricSrc.lrclib);
                } else if (result.plainLyrics) {
                    root._setFinalNotFound(status.skippedPlain);
                    console.info("[MusicLyrics] ✗ lrclib: only plain lyrics found for \"" + expectedTitle + "\" (skipping, synced only)");
                } else {
                    root._setFinalNotFound(status.notFound);
                    console.info("[MusicLyrics] ✗ lrclib: response contained no lyrics for \"" + expectedTitle + "\"");
                }
            } catch (e) {
                root._setFinalNotFound(status.error);
                console.warn("[MusicLyrics] lrclib: failed to parse response — " + e);
                console.warn("[MusicLyrics] lrclib: raw data: " + rawData.substring(0, 200));
            }
        }, function (errMsg) {
            root._setFinalNotFound(status.error);
            console.warn("[MusicLyrics] lrclib: request failed — " + errMsg);
        });
    }

    // -------------------------------------------------------------------------
    // Musixmatch fetch
    // -------------------------------------------------------------------------

    property string _musixmatchToken: pluginData.musixmatchToken ?? ""

    function _musixmatchHeaders() {
        return {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36",
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": "https://www.musixmatch.com",
            "Referer": "https://www.musixmatch.com/"
        };
    }

    function _fetchMusixmatchToken(callback) {
        if (_musixmatchToken) {
            callback(_musixmatchToken);
            return;
        }

        var url = "https://apic-desktop.musixmatch.com/ws/1.1/token.get"
            + "?user_language=en"
            + "&app_id=web-desktop-app-v1.0"
            + "&t=" + Date.now();

        console.info("[MusicLyrics] Musixmatch: fetching token…");

        root._cancelActiveFetch = _xhrGet(url, 15000, function (responseText, httpStatus) {
            try {
                var result = JSON.parse(responseText);
                var body = result.message ? result.message.body : undefined;
                var token = body ? body.user_token : undefined;
                if (token && token !== "undefined" && token !== "") {
                    root._musixmatchToken = token;
                    pluginService.savePluginData("musicLyrics", "musixmatchToken", token)
                    console.info("[MusicLyrics] Musixmatch: token acquired");
                    callback(token);
                } else {
                    console.warn("[MusicLyrics] Musixmatch: empty token in response");
                    callback(null);
                }
            } catch (e) {
                console.warn("[MusicLyrics] Musixmatch: failed to parse token response — " + e);
                callback(null);
            }
        }, function (errMsg) {
            console.warn("[MusicLyrics] Musixmatch: token request failed — " + errMsg);
            callback(null);
        }, _musixmatchHeaders());
    }

    function _fetchFromMusixmatch(expectedTitle, expectedArtist, _tokenRetried) {
        if (lyricStatus === lyricState.synced) {
            musixmatchStatus = status.skippedFound;
            console.info("[MusicLyrics] Musixmatch: skipped (synced lyrics already found)");
            return;
        }

        musixmatchStatus = status.searching;
        console.info("[MusicLyrics] Musixmatch: searching for \"" + expectedTitle + "\" by " + expectedArtist);

        _fetchMusixmatchToken(function (token) {
            if (!token) {
                root._setMusixmatchNotFound(status.error);
                console.warn("[MusicLyrics] Musixmatch: no token available, cannot search");
                return;
            }

            // Guard: track may have changed
            if (expectedTitle !== root._lastFetchedTrack || expectedArtist !== root._lastFetchedArtist)
                return;

            var trackUrl = "https://apic-desktop.musixmatch.com/ws/1.1/matcher.track.get"
                + "?q_track=" + encodeURIComponent(expectedTitle)
                + "&q_artist=" + encodeURIComponent(expectedArtist)
                + "&page_size=1&page=1"
                + "&app_id=web-desktop-app-v1.0"
                + "&usertoken=" + encodeURIComponent(token)
                + "&t=" + Date.now();

            root._cancelActiveFetch = root._xhrGet(trackUrl, 15000, function (responseText, httpStatus) {
                try {
                    var result = JSON.parse(responseText);
                    var headerStatusCode = result.message && result.message.header ? result.message.header.status_code : 0;
                    if (headerStatusCode === 401 || headerStatusCode === 402) {
                        console.warn("[MusicLyrics] Musixmatch: auth error (status_code=" + headerStatusCode + ") in matcher.track.get");
                        if (!_tokenRetried) {
                            root._musixmatchToken = "";
                            console.info("[MusicLyrics] Musixmatch: token cleared, retrying with fresh token…");
                            root._fetchFromMusixmatch(expectedTitle, expectedArtist, true);
                        } else {
                            root._setMusixmatchNotFound(status.error);
                            console.warn("[MusicLyrics] Musixmatch: auth error persists after token refresh");
                        }
                        return;
                    }
                    var track = result.message.body.track;
                    var trackId = track.track_id;
                    if (!trackId) {
                        root._setMusixmatchNotFound(status.notFound);
                        console.info("[MusicLyrics] ✗ Musixmatch: no track found for \"" + expectedTitle + "\"");
                        return;
                    }

                    var hasSubtitles = track.has_subtitles === 1;
                    var hasLyrics = track.has_lyrics === 1;
                    console.info("[MusicLyrics] Musixmatch: track matched (id: " + trackId + ", has_subtitles: " + hasSubtitles + ", has_lyrics: " + hasLyrics + ")");

                    if (!hasSubtitles) {
                        root._setMusixmatchNotFound(hasLyrics ? status.skippedPlain : status.notFound);
                        console.info("[MusicLyrics] ✗ Musixmatch: track has no synced lyrics (has_subtitles=0) for \"" + expectedTitle + "\"");
                        return;
                    }

                    console.info("[MusicLyrics] Musixmatch: fetching synced lyrics…");
                    root._fetchMusixmatchLyrics(trackId, token, expectedTitle, expectedArtist);
                } catch (e) {
                    root._setMusixmatchNotFound(status.error);
                    console.warn("[MusicLyrics] Musixmatch: failed to parse track response — " + e);
                }
            }, function (errMsg) {
                root._setMusixmatchNotFound(status.error);
                console.warn("[MusicLyrics] Musixmatch: track request failed — " + errMsg);
            }, _musixmatchHeaders());
        });
    }

    function _fetchMusixmatchLyrics(trackId, token, expectedTitle, expectedArtist, _tokenRetried) {
        var url = "https://apic-desktop.musixmatch.com/ws/1.1/track.subtitle.get"
            + "?track_id=" + trackId
            + "&subtitle_format=lrc"
            + "&app_id=web-desktop-app-v1.0"
            + "&usertoken=" + encodeURIComponent(token)
            + "&t=" + Date.now();

        root._cancelActiveFetch = _xhrGet(url, 15000, function (responseText, httpStatus) {
            // Guard: track may have changed
            if (expectedTitle !== root._lastFetchedTrack || expectedArtist !== root._lastFetchedArtist)
                return;

            try {
                var result = JSON.parse(responseText);
                var headerStatusCode = result.message && result.message.header ? result.message.header.status_code : 0;
                if (headerStatusCode === 401 || headerStatusCode === 402) {
                    console.warn("[MusicLyrics] Musixmatch: auth error (status_code=" + headerStatusCode + ") in track.subtitle.get");
                    if (!_tokenRetried) {
                        root._musixmatchToken = "";
                        console.info("[MusicLyrics] Musixmatch: token cleared, retrying with fresh token…");
                        root._fetchFromMusixmatch(expectedTitle, expectedArtist, true);
                    } else {
                        root._setMusixmatchNotFound(status.error);
                        console.warn("[MusicLyrics] Musixmatch: auth error persists after token refresh");
                    }
                    return;
                }
                var subtitleBody = result.message.body.subtitle.subtitle_body;
                if (!subtitleBody || subtitleBody.trim() === "") {
                    root._setMusixmatchNotFound(status.notFound);
                    console.info("[MusicLyrics] ✗ Musixmatch: no synced lyrics for \"" + expectedTitle + "\"");
                    return;
                }

                var lines = root.parseLrc(subtitleBody);
                if (lines.length === 0) {
                    root._setMusixmatchNotFound(status.notFound);
                    console.info("[MusicLyrics] ✗ Musixmatch: failed to parse LRC for \"" + expectedTitle + "\"");
                    return;
                }

                root.lyricsLines = lines;
                root.musixmatchStatus = status.found;
                root.lrclibStatus = status.skippedFound;
                root.lyricStatus = lyricState.synced;
                root.lyricSource = lyricSrc.musixmatch;
                console.info("[MusicLyrics] ✓ Musixmatch: synced lyrics found (" + lines.length + " lines) for \"" + expectedTitle + "\"");
                root._cancelActiveFetch = null;
                if (root.cachingEnabled)
                    root.writeToCache(expectedTitle, expectedArtist, lines, lyricSrc.musixmatch);
            } catch (e) {
                root._setMusixmatchNotFound(status.error);
                console.warn("[MusicLyrics] Musixmatch: failed to parse lyrics response — " + e);
            }
        }, function (errMsg) {
            root._setMusixmatchNotFound(status.error);
            console.warn("[MusicLyrics] Musixmatch: lyrics request failed — " + errMsg);
        }, _musixmatchHeaders());
    }

    // -------------------------------------------------------------------------
    // LRC parser
    // -------------------------------------------------------------------------

    function parseLrc(lrcText) {
        var timeRegex = /\[(\d{2}):(\d{2})\.(\d{2,3})\]/;
        var result = lrcText.split("\n").reduce(function (acc, rawLine) {
            var line = rawLine.trim();
            if (!line)
                return acc;
            var match = timeRegex.exec(line);
            if (!match)
                return acc;
            var millis = parseInt(match[3]);
            if (match[3].length === 2)
                millis *= 10;
            acc.push({
                time: parseInt(match[1]) * 60 + parseInt(match[2]) + millis / 1000,
                text: line.replace(/\[\d{2}:\d{2}\.\d{2,3}\]/g, "").trim()
            });
            return acc;
        }, []);
        result.sort(function (a, b) {
            return a.time - b.time;
        });
        return result;
    }

    // -------------------------------------------------------------------------
    // Position tracking for synced lyrics
    // -------------------------------------------------------------------------

    Timer {
        id: positionTimer
        interval: 200
        running: activePlayer && lyricsLines.length > 0
        repeat: true
        onTriggered: {
            var pos = activePlayer.position || 0;
            var newIndex = -1;
            for (var i = lyricsLines.length - 1; i >= 0; i--) {
                if (pos >= lyricsLines[i].time) {
                    newIndex = i;
                    break;
                }
            }
            if (newIndex !== currentLineIndex)
                currentLineIndex = newIndex;
        }
    }

    // -------------------------------------------------------------------------
    // Status chip helpers
    // -------------------------------------------------------------------------

    readonly property var _chipMeta: ({
            [status.searching]: {
                color: Theme.secondary,
                icon: "hourglass_top",
                label: "Searching…"
            },
            [status.found]: {
                color: Theme.primary,
                icon: "check_circle",
                label: "Found — Synced lyrics"
            },
            [status.notFound]: {
                color: Theme.warning,
                icon: "cancel",
                label: "Not found"
            },
            [status.error]: {
                color: Theme.error,
                icon: "error",
                label: "Error"
            },
            [status.skippedConfig]: {
                color: Theme.warning,
                icon: "block",
                label: "Skipped — Not configured"
            },
            [status.skippedFound]: {
                color: Theme.warning,
                icon: "block",
                label: "Skipped — Already found"
            },
            [status.skippedPlain]: {
                color: Theme.warning,
                icon: "block",
                label: "Skipped — Plain lyrics only"
            },
            [status.cacheHit]: {
                color: Theme.primary,
                icon: "check_circle",
                label: "Hit — Lyrics loaded from cache"
            },
            [status.cacheMiss]: {
                color: Theme.warning,
                icon: "cancel",
                label: "Miss — Not in cache"
            },
            [status.cacheDisabled]: {
                color: Theme.surfaceVariantText,
                icon: "do_not_disturb_on",
                label: "Disabled"
            }
        })

    function _chip(val) {
        return _chipMeta[val] ?? {
            color: Theme.surfaceContainerHighest,
            icon: "radio_button_unchecked",
            label: "Idle"
        };
    }

    function chipColor(val) {
        return _chip(val).color;
    }
    function chipIcon(val) {
        return _chip(val).icon;
    }
    function chipLabel(val) {
        return _chip(val).label;
    }

    // -------------------------------------------------------------------------
    // Bar Pills: show current lyric line
    // -------------------------------------------------------------------------

    horizontalBarPill: root.activePlayer ? hPillComponent : null

    Component {
        id: hPillComponent
        Item {
            implicitWidth: contentRow.implicitWidth
            implicitHeight: contentRow.implicitHeight

            Row {
                id: contentRow
                spacing: Theme.spacingS

                Rectangle {
                    width: chipContent.implicitWidth + Theme.spacingS * 2
                    height: Theme.fontSizeSmall + Theme.spacingXS
                    radius: 12
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.primary

                    Row {
                        id: chipContent
                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: activePlayer && activePlayer.playbackState === MprisPlaybackState.Playing ? "lyrics" : "pause"
                            size: Theme.fontSizeSmall
                            color: Theme.background
                        }

                        StyledText {
                            text: root.lyricSource === lyricSrc.navidrome ? "Navidrome"
                                  : root.lyricSource === lyricSrc.lrclib ? "lrclib"
                                  : root.lyricSource === lyricSrc.musixmatch ? "Musixmatch"
                                  : root.lyricSource === lyricSrc.metadata ? "Metadata"
                                  : (root.lyricSource === lyricSrc.localLrc || root.lyricSource === lyricSrc.local) ? "Local .lrc"
                                  : root.lyricSource === lyricSrc.cache ? "Cache"
                                  : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.background
                            anchors.verticalCenter: parent.verticalCenter
                            maximumLineCount: 1
                            elide: Text.ElideRight
                            visible: root.lyricsLines.length > 0
                        }
                    }
                }

                StyledText {
                    text: root.currentLyricText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, 300)
                }
            }

            MouseArea {
                id: hInteractiveArea
                anchors.fill: parent
                enabled: root.statusPaneButton === "middle" || root.lyricsPaneButton === "middle"
                acceptedButtons: Qt.MiddleButton
                z: 1000
                onPressed: mouse => {
                    root.handleMappedMouseAction("middle", contentRow, 0, 0, 0, "", null)
                    mouse.accepted = true
                }
            }
        }
    }

    verticalBarPill: root.activePlayer ? vPillComponent : null
    pillClickAction: (x, y, width, section, screen) => {
        handleMappedMouseAction("left", null, x, y, width, section, screen)
    }
    pillRightClickAction: (x, y, width, section, screen) => {
        handleMappedMouseAction("right", null, x, y, width, section, screen)
    }

    Component {
        id: vPillComponent
        Item {
            implicitWidth: contentColumn.implicitWidth
            implicitHeight: contentColumn.implicitHeight

            Column {
                id: contentColumn
                spacing: Theme.spacingXS

                DankIcon {
                    name: "lyrics"
                    size: Theme.iconSize
                    color: root.lyricsLines.length > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: "♪"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            MouseArea {
                id: vInteractiveArea
                anchors.fill: parent
                enabled: root.statusPaneButton === "middle" || root.lyricsPaneButton === "middle"
                acceptedButtons: Qt.MiddleButton
                z: 1000
                onPressed: mouse => {
                    root.handleMappedMouseAction("middle", contentColumn, 0, 0, 0, "", null)
                    mouse.accepted = true
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Popout: Now Playing + Lyrics Sources
    // -------------------------------------------------------------------------

    function _formatDuration(seconds) {
        if (seconds <= 0) return "—";
        var m = Math.floor(seconds / 60);
        var s = Math.floor(seconds % 60);
        return m + ":" + ("0" + s).slice(-2);
    }

    function mappedActionForButton(button) {
        // If both actions use the same button, prioritize Lyrics pane.
        if (lyricsPaneButton === button)
            return "lyrics";
        if (statusPaneButton === button)
            return "status";
        return "none";
    }

    function handleMappedMouseAction(button, sourceItem, x, y, width, triggerSection, screenObj) {
        const action = mappedActionForButton(button);
        if (action === "status") {
            const savedPillClickAction = root.pillClickAction;
            root.pillClickAction = null;
            try {
                root.triggerPopout();
            } finally {
                root.pillClickAction = savedPillClickAction;
            }
            return;
        }
        if (action !== "lyrics")
            return;

        if (sourceItem) {
            const currentScreen = parentScreen || Screen;
            const globalPos = sourceItem.mapToItem(null, 0, 0);
            const barPosition = axis?.edge === "left" ? 2 : (axis?.edge === "right" ? 3 : (axis?.edge === "bottom" ? 1 : 0));
            const triggerWidth = Math.max(barThickness || 0, sourceItem.width || 0, sourceItem.implicitWidth || 0);
            const pos = SettingsData.getPopupTriggerPosition(globalPos, currentScreen, barThickness, triggerWidth, barSpacing, barPosition, barConfig);
            toggleLyricsOnlyPopout(pos.x, pos.y, pos.width, root.section, currentScreen);
            return;
        }

        toggleLyricsOnlyPopout(x, y, width, triggerSection, screenObj);
    }

    function toggleLyricsOnlyPopout(x, y, width, triggerSection, screenObj) {
        const currentScreen = screenObj || parentScreen || Screen
        if (!currentScreen)
            return
        const barPosition = axis?.edge === "left" ? 2 : (axis?.edge === "right" ? 3 : (axis?.edge === "bottom" ? 1 : 0))

        lyricsOnlyPopout.setTriggerPosition(
            x || 0,
            y || 0,
            width || barThickness,
            triggerSection || section || "",
            currentScreen,
            barPosition,
            barThickness,
            barSpacing,
            barConfig
        )
        lyricsOnlyPopout.toggle()
    }

    DankPopout {
        id: lyricsOnlyPopout
        layerNamespace: "dms:musiclyrics-lyrics-only"
        popupWidth: 500
        popupHeight: 620
        onBackgroundClicked: close()

        content: Component {
            Rectangle {
                id: lyricsPane
                width: parent.width
                height: 560
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer
                property bool autoScrollPaused: false
                property bool autoScrollInternal: false

                function pauseAutoScroll() {
                    autoScrollPaused = true;
                    autoScrollResumeTimer.restart();
                }

                function syncToCurrentLine() {
                    if (autoScrollPaused || root.currentLineIndex < 0 || !lyricsFlick.visibleArea)
                        return;
                    const item = lineRepeater.itemAt(root.currentLineIndex);
                    if (!item)
                        return;

                    const pad = Math.max(12, Theme.spacingM);
                    const top = lyricsFlick.contentY;
                    const bottom = top + lyricsFlick.height;
                    const itemTop = item.y;
                    const itemBottom = item.y + item.height;
                    const alreadyVisible = itemTop >= (top + pad) && itemBottom <= (bottom - pad);
                    if (alreadyVisible)
                        return;

                    const maxY = Math.max(0, lyricsFlick.contentHeight - lyricsFlick.height);
                    const target = Math.max(0, Math.min(maxY, itemTop - lyricsFlick.height * 0.35));
                    autoScrollInternal = true;
                    lyricsFlick.contentY = target;
                    autoScrollInternal = false;
                }

                Timer {
                    id: autoScrollResumeTimer
                    interval: 5000
                    repeat: false
                    onTriggered: {
                        lyricsPane.autoScrollPaused = false;
                        lyricsPane.syncToCurrentLine();
                    }
                }

                Connections {
                    target: root
                    function onCurrentLineIndexChanged() {
                        Qt.callLater(lyricsPane.syncToCurrentLine);
                    }
                    function onLyricsLinesChanged() {
                        Qt.callLater(lyricsPane.syncToCurrentLine);
                    }
                }

                Component.onCompleted: Qt.callLater(syncToCurrentLine)
                onVisibleChanged: if (visible) Qt.callLater(syncToCurrentLine)

                Flickable {
                    id: lyricsFlick
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    clip: true
                    contentHeight: lyricsColumn.implicitHeight
                    onMovementStarted: {
                        if (!lyricsPane.autoScrollInternal)
                            lyricsPane.pauseAutoScroll();
                    }
                    Behavior on contentY {
                        NumberAnimation {
                            duration: 180
                            easing.type: Easing.OutCubic
                        }
                    }

                    WheelHandler {
                        target: lyricsFlick
                        onWheel: lyricsPane.pauseAutoScroll()
                    }

                    Column {
                        id: lyricsColumn
                        width: lyricsFlick.width
                        spacing: Theme.spacingS

                        StyledText {
                            text: "Lyrics"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.DemiBold
                            color: Theme.primary
                        }

                        StyledText {
                            text: root.currentTitle || "No track"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                            maximumLineCount: 2
                            wrapMode: Text.WordWrap
                        }

                        StyledText {
                            text: root.currentArtist || ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            visible: text.length > 0
                            maximumLineCount: 1
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.outline
                            opacity: 0.4
                        }

                        StyledText {
                            visible: root.lyricsLoading
                            text: "Searching lyrics..."
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            visible: !root.lyricsLoading && root.lyricsLines.length === 0
                            text: "No lyrics found."
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                        }

                        Repeater {
                            id: lineRepeater
                            model: root.lyricsLines.length
                            delegate: Item {
                                required property int index
                                width: lyricsColumn.width
                                implicitHeight: lineText.implicitHeight

                                StyledText {
                                    id: lineText
                                    text: root.lyricsLines[index].text || ""
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: index === root.currentLineIndex ? Theme.primary : Theme.surfaceText
                                    font.weight: index === root.currentLineIndex ? Font.DemiBold : Font.Normal
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !!root.activePlayer
                                    hoverEnabled: enabled
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.seekToLyricLine(index)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            headerText: "Music Lyrics"

            Item {
                width: parent.width
                implicitHeight: popoutLayout.implicitHeight

                Column {
                    id: popoutLayout
                    width: parent.width
                    spacing: Theme.spacingM

                    // ── Now Playing Card ──
                    Rectangle {
                        width: parent.width
                        height: nowPlayingContent.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: root.activePlayer
                              ? Theme.withAlpha(Theme.primary, 0.08)
                              : Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)

                        Row {
                            id: nowPlayingContent
                            anchors {
                                left: parent.left; right: parent.right
                                top: parent.top
                                margins: Theme.spacingM
                            }
                            spacing: Theme.spacingM

                            // Track info column (takes remaining space)
                            Column {
                                width: _coverArt.visible
                                       ? parent.width - _coverArt.width - parent.spacing
                                       : parent.width
                                spacing: Theme.spacingS

                                // Header row: icon + "Now Playing"
                                Row {
                                    spacing: Theme.spacingS
                                    width: parent.width

                                    DankIcon {
                                        name: root.activePlayer && root.activePlayer.playbackState === MprisPlaybackState.Playing
                                              ? "play_circle" : "pause_circle"
                                        size: 20
                                        color: root.activePlayer ? Theme.primary : Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    StyledText {
                                        text: root.activePlayer ? "Now Playing - " + (root.activePlayer.identity || "Unknown Player") : "No Active Player"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
                                        color: root.activePlayer ? Theme.primary : Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                // Song title
                                StyledText {
                                    width: parent.width
                                    text: root.currentTitle || "—"
                                    font.pixelSize: Theme.fontSizeLarge + 2
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    wrapMode: Text.WordWrap
                                    visible: root.activePlayer
                                }

                                // Artist & Album
                                Column {
                                    width: parent.width
                                    spacing: 2
                                    visible: root.activePlayer

                                    Row {
                                        spacing: Theme.spacingXS
                                        DankIcon {
                                            name: "person"
                                            size: 14
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        StyledText {
                                            text: root.currentArtist || "Unknown Artist"
                                            font.pixelSize: Theme.fontSizeMedium
                                            color: Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                            maximumLineCount: 1
                                            elide: Text.ElideRight
                                        }
                                    }

                                    Row {
                                        spacing: Theme.spacingXS
                                        visible: root.currentAlbum !== ""
                                        DankIcon {
                                            name: "album"
                                            size: 14
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        StyledText {
                                            text: root.currentAlbum
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                            maximumLineCount: 1
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                // Progress bar with timestamps
                                Column {
                                    width: parent.width
                                    spacing: 4
                                    visible: root.activePlayer && root.currentDuration > 0

                                    DankSeekbar {
                                        id: progressSeekbar
                                        width: parent.width
                                        height: 20
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        activePlayer: root.activePlayer
                                    }

                                    // Poll MPRIS position to keep seekbar and time text updated
                                    Timer {
                                        interval: 50
                                        running: root.activePlayer !== null
                                        repeat: true
                                        onTriggered: {
                                            if (progressSeekbar && root.activePlayer) {
                                                try {
                                                    var pos = root.activePlayer.position || 0;
                                                    var len = Math.max(1, root.activePlayer.length || 1);
                                                    progressSeekbar.value = Math.min(1, pos / len);
                                                } catch (e) {}
                                            }
                                            root._forceUpdate = !root._forceUpdate;
                                        }
                                    }

                                    Row {
                                        width: parent.width

                                        StyledText {
                                            id: _currentTime
                                            text: {
                                                void root._forceUpdate; // depend on polling toggle
                                                if (!activePlayer)
                                                    return "0:00";
                                                const rawPos = Math.max(0, activePlayer.position || 0);
                                                const pos = activePlayer.length ? rawPos % Math.max(1, activePlayer.length) : rawPos;
                                                const minutes = Math.floor(pos / 60);
                                                const seconds = Math.floor(pos % 60);
                                                const timeStr = minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
                                                return timeStr;
                                            }
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                        }

                                        Item { width: parent.width - _currentTime.implicitWidth - _endTime.implicitWidth; height: 1 }

                                        StyledText {
                                            id: _endTime
                                            text: {
                                                if (!activePlayer || !activePlayer.length)
                                                    return "0:00";
                                                const dur = Math.max(0, activePlayer.length || 0);
                                                const minutes = Math.floor(dur / 60);
                                                const seconds = Math.floor(dur % 60);
                                                return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
                                            }
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                        }
                                    }
                                }
                            }

                            // Album cover art
                            DankAlbumArt {
                                id: _coverArt
                                width: 80
                                height: 80
                                visible: root.activePlayer && (root.activePlayer.trackArtUrl ?? "") !== ""
                                anchors.verticalCenter: parent.verticalCenter
                                activePlayer: root.activePlayer
                                showAnimation: true
                            }
                        }
                    }

                    // ── Section label ──
                    StyledText {
                        text: "Lyrics Sources"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                        leftPadding: Theme.spacingXS
                    }

                    // ── Source Cards ──
                    Column {
                        width: parent.width
                        spacing: Theme.spacingS

                        SourceCard {
                            width: parent.width
                            icon: "cached"
                            label: "Cache"
                            sourceStatus: root.cacheStatus
                        }

                        SourceCard {
                            width: parent.width
                            icon: "badge"
                            label: "Metadata"
                            sourceStatus: root.metadataStatus
                        }

                        SourceCard {
                            width: parent.width
                            icon: "description"
                            label: "Local .lrc"
                            sourceStatus: root.localLrcStatus
                        }

                        SourceCard {
                            width: parent.width
                            icon: "cloud"
                            label: "Navidrome"
                            sourceStatus: root.navidromeStatus
                        }

                        SourceCard {
                            width: parent.width
                            icon: "music_note"
                            label: "Musixmatch"
                            sourceStatus: root.musixmatchStatus
                        }

                        SourceCard {
                            width: parent.width
                            icon: "library_music"
                            label: "lrclib"
                            sourceStatus: root.lrclibStatus
                        }
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Reusable source status card
    // -------------------------------------------------------------------------

    component SourceCard: Rectangle {
        id: sourceCard
        property string icon: ""
        property string label: ""
        property int sourceStatus: 0

        height: 44
        radius: Theme.cornerRadius
        color: sourceStatus === 0
               ? Theme.withAlpha(Theme.surfaceContainerHighest, 0.3)
               : Theme.withAlpha(root.chipColor(sourceStatus), 0.06)
        visible: true

        Row {
            anchors {
                left: parent.left; right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: Theme.spacingM; rightMargin: Theme.spacingM
            }
            spacing: Theme.spacingS

            // Source icon
            Rectangle {
                width: 28
                height: 28
                radius: 14
                color: sourceCard.sourceStatus === 0
                       ? Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)
                       : Theme.withAlpha(root.chipColor(sourceCard.sourceStatus), 0.15)
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    anchors.centerIn: parent
                    name: sourceCard.icon
                    size: 14
                    color: sourceCard.sourceStatus === 0
                           ? Theme.surfaceVariantText
                           : root.chipColor(sourceCard.sourceStatus)
                }
            }

            // Label
            StyledText {
                text: sourceCard.label
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.DemiBold
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
                width: 90
            }

            // Status chip – fills remaining width
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - parent.spacing * 2 - 28 - 90
                height: 22

                Rectangle {
                    visible: sourceCard.sourceStatus !== 0
                    anchors.fill: parent
                    radius: 11
                    color: Theme.withAlpha(root.chipColor(sourceCard.sourceStatus), 0.15)

                    Row {
                        id: statusChipContent
                        anchors.centerIn: parent
                        spacing: 4

                        DankIcon {
                            name: root.chipIcon(sourceCard.sourceStatus)
                            size: 12
                            color: root.chipColor(sourceCard.sourceStatus)
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.chipLabel(sourceCard.sourceStatus)
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: root.chipColor(sourceCard.sourceStatus)
                            anchors.verticalCenter: parent.verticalCenter
                            maximumLineCount: 1
                            elide: Text.ElideRight
                        }
                    }
                }

                // Idle label when no status
                Rectangle {
                    visible: sourceCard.sourceStatus === 0
                    anchors.fill: parent
                    radius: 11
                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.3)

                    StyledText {
                        anchors.centerIn: parent
                        text: "Idle"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        maximumLineCount: 1
                    }
                }
            }
        }
    }

    popoutWidth: 380
    popoutHeight: 520

    Component.onCompleted: {
        console.info("[MusicLyrics] Plugin loaded");
    }
}
