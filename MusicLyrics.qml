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

    property MprisPlayer activePlayer: MprisController.activePlayer
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
    property int cacheStatus: status.none

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

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _resetLyricsState() {
        lyricsLines = [];
        currentLineIndex = -1;
        navidromeStatus = status.none;
        lrclibStatus = status.none;
        cacheStatus = status.none;
        lyricStatus = lyricState.loading;
        lyricSource = lyricSrc.none;
    }

    // Sets the "no synced lyrics" state, used by lrclib handlers
    function _setLyricsNotFound(lrclibStatusVal) {
        lrclibStatus = lrclibStatusVal;
        lyricStatus = lyricState.notFound;
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

    readonly property string _cacheDir: (Quickshell.env("HOME") || "") + "/.cache/musicLyrics"

    function _cacheFilePath(title, artist) {
        return _cacheDir + "/" + _cacheKey(title, artist) + ".json";
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

        _lastFetchedTrack = currentTitle;
        _lastFetchedArtist = currentArtist;
        _resetLyricsState();

        var durationStr = currentDuration > 0 ? (Math.floor(currentDuration / 60) + ":" + ("0" + Math.floor(currentDuration % 60)).slice(-2)) : "unknown";
        console.info("[MusicLyrics] ▶ Track changed: \"" + currentTitle + "\" by " + currentArtist + (currentAlbum ? " [" + currentAlbum + "]" : "") + " (" + durationStr + ")");

        var capturedTitle = currentTitle;
        var capturedArtist = currentArtist;

        function _startFetch() {
            if (_configValid) {
                _fetchFromNavidrome(capturedTitle, capturedArtist);
            } else {
                navidromeStatus = status.skippedConfig;
                console.info("[MusicLyrics] Navidrome: skipped (not configured)");
                _fetchFromLrclib(capturedTitle, capturedArtist);
            }
        }

        if (cachingEnabled) {
            readFromCache(capturedTitle, capturedArtist, function (cached) {
                // Guard: track may have changed while the file read was in progress
                if (capturedTitle !== root._lastFetchedTrack || capturedArtist !== root._lastFetchedArtist)
                    return;
                if (cached && cached.lines && cached.lines.length > 0) {
                    root.lyricsLines = cached.lines;
                    root.lyricStatus = lyricState.synced;
                    root.lyricSource = cached.source > 0 ? cached.source : lyricSrc.cache;
                    root.cacheStatus = status.cacheHit;
                    root.navidromeStatus = status.skippedFound;
                    root.lrclibStatus = status.skippedFound;
                    console.info("[MusicLyrics] ✓ Cache: lyrics loaded for \"" + capturedTitle + "\" (" + cached.lines.length + " lines)");
                    return;
                }
                root.cacheStatus = status.cacheMiss;
                _startFetch();
            });
        } else {
            cacheStatus = status.cacheDisabled;
            _startFetch();
        }
    }

    // -------------------------------------------------------------------------
    // XMLHttpRequest helper
    // -------------------------------------------------------------------------

    function _xhrGet(url, timeoutMs, onSuccess, onError) {
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
                onSuccess(currentXhr.responseText, currentXhr.status);
            };
            currentXhr.open("GET", url);
            currentXhr.setRequestHeader("User-Agent", "DankMaterialShell MusicLyrics/1.1.0 (https://github.com/Gasiyu/musiclyrics)");
            currentXhr.setRequestHeader("Accept", "application/json");
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
                root._fetchFromLrclib(expectedTitle, expectedArtist);
                return;
            }
            try {
                var result = JSON.parse(rawData);
                var songs = result["subsonic-response"]?.searchResult3?.song;
                if (!songs || songs.length === 0) {
                    root.navidromeStatus = status.notFound;
                    console.info("[MusicLyrics] ✗ Navidrome: no matching songs found for \"" + expectedTitle + "\"");
                    root._fetchFromLrclib(expectedTitle, expectedArtist);
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
                root._fetchFromLrclib(expectedTitle, expectedArtist);
            }
        }, function (errMsg) {
            root.navidromeStatus = status.error;
            console.warn("[MusicLyrics] Navidrome: search request failed — " + errMsg);
            root._fetchFromLrclib(expectedTitle, expectedArtist);
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
                root._fetchFromLrclib(expectedTitle, expectedArtist);
                return;
            }
            try {
                var result = JSON.parse(rawData);
                var lyricsList = result["subsonic-response"]?.lyricsList?.structuredLyrics;
                if (!lyricsList || lyricsList.length === 0) {
                    root.navidromeStatus = status.notFound;
                    console.info("[MusicLyrics] ✗ Navidrome: no lyrics available for \"" + expectedTitle + "\"");
                    root._fetchFromLrclib(expectedTitle, expectedArtist);
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
                    console.info("[MusicLyrics] ✓ Navidrome: synced lyrics found (" + lines.length + " lines) for \"" + expectedTitle + "\"");
                    if (root.cachingEnabled)
                        root.writeToCache(expectedTitle, expectedArtist, lines, lyricSrc.navidrome);
                } else if (unsynced && unsynced.line) {
                    root.navidromeStatus = status.skippedPlain;
                    console.info("[MusicLyrics] ✗ Navidrome: only plain lyrics found for \"" + expectedTitle + "\" (skipping, synced only)");
                    root._fetchFromLrclib(expectedTitle, expectedArtist);
                } else {
                    root.navidromeStatus = status.notFound;
                    console.info("[MusicLyrics] ✗ Navidrome: lyrics structure empty for \"" + expectedTitle + "\"");
                    root._fetchFromLrclib(expectedTitle, expectedArtist);
                }
            } catch (e) {
                root.navidromeStatus = status.error;
                console.warn("[MusicLyrics] Navidrome: failed to parse lyrics response — " + e);
                console.warn("[MusicLyrics] Navidrome: raw data: " + rawData.substring(0, 200));
                root._fetchFromLrclib(expectedTitle, expectedArtist);
            }
        }, function (errMsg) {
            root.navidromeStatus = status.error;
            console.warn("[MusicLyrics] Navidrome: lyrics request failed — " + errMsg);
            root._fetchFromLrclib(expectedTitle, expectedArtist);
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
                root._setLyricsNotFound(status.error);
                console.warn("[MusicLyrics] lrclib: empty response (HTTP " + httpStatus + ")");
                return;
            }
            try {
                var result = JSON.parse(rawData);
                if (result.statusCode === 404 || result.error) {
                    root._setLyricsNotFound(status.notFound);
                    console.info("[MusicLyrics] ✗ lrclib: no lyrics found for \"" + expectedTitle + "\"");
                } else if (result.syncedLyrics) {
                    root.lyricsLines = root.parseLrc(result.syncedLyrics);
                    root.lrclibStatus = status.found;
                    root.lyricStatus = lyricState.synced;
                    root.lyricSource = lyricSrc.lrclib;
                    console.info("[MusicLyrics] ✓ lrclib: synced lyrics found (" + root.lyricsLines.length + " lines) for \"" + expectedTitle + "\"");
                    if (root.cachingEnabled)
                        root.writeToCache(expectedTitle, expectedArtist, root.lyricsLines, lyricSrc.lrclib);
                } else if (result.plainLyrics) {
                    root._setLyricsNotFound(status.skippedPlain);
                    console.info("[MusicLyrics] ✗ lrclib: only plain lyrics found for \"" + expectedTitle + "\" (skipping, synced only)");
                } else {
                    root._setLyricsNotFound(status.notFound);
                    console.info("[MusicLyrics] ✗ lrclib: response contained no lyrics for \"" + expectedTitle + "\"");
                }
            } catch (e) {
                root._setLyricsNotFound(status.error);
                console.warn("[MusicLyrics] lrclib: failed to parse response — " + e);
                console.warn("[MusicLyrics] lrclib: raw data: " + rawData.substring(0, 200));
            }
        }, function (errMsg) {
            root._setLyricsNotFound(status.error);
            console.warn("[MusicLyrics] lrclib: request failed — " + errMsg);
        });
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

    horizontalBarPill: Component {
        Row {
            visible: !!root.activePlayer
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
                        text: root.lyricSource === lyricSrc.navidrome ? "Navidrome" : root.lyricSource === lyricSrc.lrclib ? "lrclib" : ""
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
    }

    verticalBarPill: Component {
        Column {
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
    }

    // -------------------------------------------------------------------------
    // Popout: Status + Media Player Selector
    // -------------------------------------------------------------------------

    popoutContent: Component {
        PopoutComponent {
            headerText: "Music Lyrics"
            detailsText: root.currentTitle ? (root.currentArtist + " — " + root.currentTitle) : "No track playing"
            showCloseButton: true

            Item {
                width: parent.width
                height: 300

                Column {
                    anchors.fill: parent
                    spacing: Theme.spacingM

                    // Divider
                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.withAlpha(Theme.outlineStrong, 0.3)
                    }

                    // --- Status Chips Section ---
                    Column {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            text: "Lyrics Status"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }

                        StatusChipRow {
                            label: "Cache"
                            status: root.cacheStatus
                        }
                        StatusChipRow {
                            label: "Navidrome"
                            status: root.navidromeStatus
                        }
                        StatusChipRow {
                            label: "lrclib"
                            status: root.lrclibStatus
                        }
                    }

                    // Divider
                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.withAlpha(Theme.outlineStrong, 0.3)
                    }

                    // --- Media Players Section ---
                    Column {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            text: "Media Players"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            text: "No media players detected"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            visible: !root.allPlayers || root.allPlayers.length === 0
                        }

                        ListView {
                            id: playerListView
                            width: parent.width
                            height: Math.min(contentHeight, 200)
                            clip: true
                            visible: root.allPlayers && root.allPlayers.length > 0
                            model: root.allPlayers
                            spacing: Theme.spacingXS

                            delegate: Rectangle {
                                id: playerDelegate
                                required property var modelData
                                width: playerListView.width
                                height: playerRow.implicitHeight + Theme.spacingS * 2
                                radius: Theme.cornerRadius
                                color: modelData === root.activePlayer ? Theme.withAlpha(Theme.primary, 0.15) : playerMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                                Row {
                                    id: playerRow
                                    anchors {
                                        left: parent.left
                                        right: parent.right
                                        verticalCenter: parent.verticalCenter
                                        margins: Theme.spacingS
                                    }
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: modelData.playbackState === MprisPlaybackState.Playing ? "play_circle" : "pause_circle"
                                        size: Theme.iconSize
                                        color: modelData === root.activePlayer ? Theme.primary : Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Column {
                                        spacing: 2
                                        width: parent.width - Theme.iconSize - Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter

                                        StyledText {
                                            text: modelData.identity || "Unknown Player"
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: modelData === root.activePlayer ? Font.Bold : Font.Normal
                                            color: modelData === root.activePlayer ? Theme.primary : Theme.surfaceText
                                            width: parent.width
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                        }

                                        StyledText {
                                            text: {
                                                var title = modelData.trackTitle || "";
                                                var artist = modelData.trackArtist || "";
                                                if (title && artist)
                                                    return artist + " — " + title;
                                                return title || "No track";
                                            }
                                            font.pixelSize: Theme.fontSizeSmall * 0.9
                                            color: Theme.surfaceVariantText
                                            width: parent.width
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                        }
                                    }
                                }

                                MouseArea {
                                    id: playerMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: MprisController.activePlayer = playerDelegate.modelData
                                }

                                Behavior on color {
                                    ColorAnimation {
                                        duration: 150
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Reusable status chip row
    // -------------------------------------------------------------------------

    component StatusChipRow: Row {
        id: chipRow
        property string label: ""
        property int status: 0

        spacing: Theme.spacingS
        visible: status !== 0

        Rectangle {
            width: innerChipRow.implicitWidth + Theme.spacingM * 2
            height: 28
            radius: 14
            color: Theme.withAlpha(root.chipColor(chipRow.status), 0.15)

            Row {
                id: innerChipRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: root.chipIcon(chipRow.status)
                    size: 14
                    color: root.chipColor(chipRow.status)
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: chipRow.label
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.DemiBold
                    color: root.chipColor(chipRow.status)
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        StyledText {
            text: root.chipLabel(chipRow.status)
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    popoutWidth: 380
    popoutHeight: 480

    Component.onCompleted: {
        console.info("[MusicLyrics] Plugin loaded");
    }
}
