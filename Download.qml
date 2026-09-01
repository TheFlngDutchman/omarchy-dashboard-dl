import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// yt-dlp engine behind the MEDIA view's download button.
//
// Two jobs: work out what the active MPRIS player is actually playing, then
// fetch it. Neither is as direct as it sounds.
//
// Chromium-family browsers publish no xesam:url at all — their MPRIS bridge is
// fed by the Media Session API, which carries title/artist/album/artwork and no
// source URL. Firefox and mpv do publish the real page URL. So resolution is a
// chain, and its last link is a YouTube search built from the track tags, which
// can land on a lookalike. confirmFirst is the only thing gating that: with it
// off, a searched match is fetched without asking.
//
// Settings live in their own state file, not on the shell.json layout entry:
// disabling and re-enabling a bar widget rewrites that entry as a bare { id },
// which would quietly reset every preference here.
QtObject {
  id: engine

  // Injected by the panel — the same player its transport controls drive.
  property var player: null

  // --- persisted settings ---------------------------------------------------

  property bool audioOnly: false
  property string audioDir: "~/Music"
  property string videoDir: "~/Videos"
  property bool confirmFirst: true

  readonly property string targetDir: audioOnly ? audioDir : videoDir
  readonly property string resolvedTargetDir: engine.expandPath(engine.targetDir)

  // --- lifecycle ------------------------------------------------------------

  // idle -> probing -> confirm -> downloading -> done | error
  property string phase: "idle"
  property string errorText: ""

  property string pendingUrl: ""      // what we hand to yt-dlp
  property string pendingKind: ""     // "exact" (a real URL) | "search" (a guess)
  property string pendingLabel: ""    // human-readable form of the above

  property real percent: 0            // 0..100, monotonic across streams
  property real speed: 0              // bytes/s, 0 unknown
  property real eta: -1               // seconds, -1 unknown
  property string filePath: ""
  property string doneTitle: ""

  // Probe results, shown in the confirmation card.
  property bool probeOk: false
  property string probeTitle: ""
  property string probeUploader: ""
  property string probeDuration: ""
  property string probeFormat: ""
  property string probeResolution: ""
  property string probeSize: ""
  property bool probeIsLive: false
  property string probeUrl: ""
  property int playlistCount: 0

  readonly property bool busy: phase === "probing" || phase === "downloading"

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"

  // --- which yt-dlp ---------------------------------------------------------

  // A stale yt-dlp is what produces YouTube's HTTP 403s, and the packaged build
  // trails behind on a delayed mirror, so a self-updating standalone binary under
  // ~/.local/bin is preferred whenever one is present. The distro copy stays as
  // the fallback (and other packages depend on it).
  //
  // PATH is not trusted for this: the shell process runs with /usr/bin ahead of
  // ~/.local/bin on one of its entries, so the packaged build would win a bare
  // name lookup. Resolution is an absolute path, done once at load. The starting
  // value is a bare name only so anything fired before the resolver answers still
  // runs rather than failing.
  property string ytdlpPath: ""            // persisted; empty means auto-detect
  property string ytdlpBinary: "yt-dlp"
  property string ytdlpVersion: ""
  property bool updating: false
  property string updateResult: ""

  readonly property bool ytdlpSelfUpdating:
    ytdlpBinary.indexOf(Quickshell.env("HOME") + "/.local/") === 0

  onYtdlpPathChanged: engine.resolveBinary()
  Component.onCompleted: engine.resolveBinary()

  function resolveBinary() {
    var candidates = []
    if (String(engine.ytdlpPath || "").trim() !== "")
      candidates.push(engine.expandPath(engine.ytdlpPath))
    var home = Quickshell.env("HOME")
    candidates.push(home + "/.local/bin/yt-dlp")
    candidates.push(home + "/.local/bin/yt-dlp_linux")

    var script = ""
    for (var i = 0; i < candidates.length; i++) {
      var quoted = Util.shellQuote(candidates[i])
      script += "if [ -x " + quoted + " ]; then printf '%s' " + quoted + "; exit 0; fi\n"
    }
    script += "command -v yt-dlp 2>/dev/null || printf 'yt-dlp'"
    resolveProcess.command = ["bash", "-lc", script]
    resolveProcess.running = true
  }

  function readVersion() {
    if (versionProcess.running) return
    versionProcess.command = [engine.ytdlpBinary, "--version"]
    versionProcess.running = true
  }

  function updateBinary() {
    if (engine.updating || engine.busy) return
    engine.updating = true
    engine.updateResult = ""
    updateProcess.command = [engine.ytdlpBinary, "-U"]
    updateProcess.running = true
  }

  // --- resolution -----------------------------------------------------------

  // What a click would download right now. Recomputed on every metadata change
  // so the button can enable/disable itself and explain why.
  readonly property var target: {
    var p = engine.player
    if (!p) return { ok: false, reason: "Nothing playing" }

    var meta = p.metadata || {}
    var url = String(meta["xesam:url"] || "")

    if (url !== "") {
      var lower = url.toLowerCase()
      if (lower.indexOf("file://") === 0)
        return { ok: false, reason: "Already a local file" }
      if (!/^https?:\/\//.test(lower))
        return { ok: false, reason: "Source is not a web address" }
      if (engine.isPrivateHost(lower))
        return { ok: false, reason: "Local stream — nothing to fetch" }
      // A DRM host hands over a perfectly well-formed URL that yt-dlp refuses
      // outright. For a music service the useful answer is a search on the
      // tags, so fall through rather than fail.
      if (!engine.isRerouteHost(lower))
        return { ok: true, kind: "exact", url: url, label: url }
    }

    // mpv publishes a real remote thumbnail, so the video id is recoverable
    // from it. Chromium's artUrl is a local temp PNG with no URL inside, hence
    // the http gate.
    var art = String(p.trackArtUrl || meta["mpris:artUrl"] || "")
    if (/^https?:\/\//i.test(art)) {
      var id = art.match(/(?:i\d?\.ytimg\.com|img\.youtube\.com)\/vi\/([A-Za-z0-9_-]{11})\//)
      if (id) {
        var rebuilt = "https://www.youtube.com/watch?v=" + id[1]
        return { ok: true, kind: "exact", url: rebuilt, label: rebuilt }
      }
    }

    var title = String(p.trackTitle || "").trim()
    if (title === "") return { ok: false, reason: "No track information" }
    var artist = String(p.trackArtist || "").trim()
    var query = (artist !== "" && artist !== title ? artist + " - " : "") + title
    return { ok: true, kind: "search", url: "ytsearch1:" + query, label: query }
  }

  // Anything yt-dlp will accept as its final argument: a web address, or one of
  // its own search shorthands.
  function isFetchable(url) {
    var value = String(url || "")
    return /^https?:\/\//i.test(value) || value.indexOf("ytsearch") === 0
  }

  function isPrivateHost(lower) {
    return /^https?:\/\/(localhost|127\.|0\.0\.0\.0|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|\[::1\])/.test(lower)
  }

  // Hosts whose URL yt-dlp is known to refuse. Deliberately short: yt-dlp owns
  // the authoritative DRM blocklist, and its stderr is surfaced verbatim when it
  // refuses something this list does not know about. These are only the ones
  // worth rerouting to a tag search instead of failing.
  function isRerouteHost(lower) {
    return lower.indexOf("open.spotify.com") !== -1
      || lower.indexOf("music.amazon.") !== -1
      || lower.indexOf("deezer.com") !== -1
      || lower.indexOf("tidal.com") !== -1
  }

  // Store paths unexpanded so they stay portable; expand only at the point of
  // use. A literal "~" handed to argv would be created as a directory named "~".
  function expandPath(path) {
    var value = String(path || "").trim()
    var home = Quickshell.env("HOME")
    if (value === "~" ) return home
    if (value.indexOf("~/") === 0) return home + value.substring(1)
    if (value.indexOf("$HOME/") === 0) return home + value.substring(5)
    return value
  }

  // --- actions --------------------------------------------------------------

  function start() {
    if (engine.busy) return
    var t = engine.target
    if (!t.ok) { engine.fail(t.reason); return }

    engine.pendingUrl = t.url
    engine.pendingKind = t.kind
    engine.pendingLabel = t.label
    engine.clearProbe()
    engine.errorText = ""

    // Immediate mode skips the probe entirely, searched matches included. yt-dlp
    // takes the ytsearch1: query as an argument directly, so there is nothing to
    // resolve up front — the real title arrives with the first print.
    if (!engine.confirmFirst) engine.beginDownload(t.url)
    else engine.beginProbe(t.url)
  }

  function confirm() {
    if (engine.phase !== "confirm") return
    engine.beginDownload(engine.probeUrl !== "" ? engine.probeUrl : engine.pendingUrl)
  }

  function dismiss() {
    if (engine.phase === "confirm" || engine.phase === "done" || engine.phase === "error")
      engine.reset()
  }

  function reset() {
    engine.phase = "idle"
    engine.errorText = ""
    engine.percent = 0
    engine.speed = 0
    engine.eta = -1
    engine.filePath = ""
    engine.doneTitle = ""
    engine.clearProbe()
  }

  function fail(message) {
    engine.errorText = String(message || "Download failed")
    engine.phase = "error"
  }

  function clearProbe() {
    engine.probeOk = false
    engine.probeTitle = ""
    engine.probeUploader = ""
    engine.probeDuration = ""
    engine.probeFormat = ""
    engine.probeResolution = ""
    engine.probeSize = ""
    engine.probeIsLive = false
    engine.probeUrl = ""
    engine.playlistCount = 0
  }

  // --- format selection -----------------------------------------------------

  // Shared by the probe and the download so the confirmation card describes the
  // format that will actually be fetched.
  function formatArgs() {
    if (engine.audioOnly)
      return ["-f", "bestaudio/best", "-x", "--audio-format", "best", "--audio-quality", "0"]
    // mkv over mp4: -t mp4 forces h264/aac and throws away the better AV1/VP9
    // and Opus streams. --recode-video would fix the container by re-encoding
    // the whole file, which is not a trade worth making for a download button.
    return ["-t", "mkv", "-f", "bv*+ba/b"]
  }

  function baseArgs() {
    return [engine.ytdlpBinary,
      "--ignore-config",       // a ~/.config/yt-dlp/config appearing later must not change what this button does
      "--no-playlist",         // collapses watch?v=X&list=Y to just X
      "--playlist-items", "1", // the actual guard: --no-playlist alone does not stop a bare /playlist?list= URL
      "--no-warnings", "--no-color",
      "--retries", "10", "--fragment-retries", "10", "--socket-timeout", "20"]
  }

  // --- probe ----------------------------------------------------------------

  readonly property string probePrint:
    "OMV\t%(title)s\t%(uploader,channel,uploader_id)s\t%(duration_string)s\t%(format)s"
    + "\t%(resolution)s\t%(ext)s\t%(filesize_approx,filesize)s\t%(is_live)s\t%(webpage_url)s"

  function beginProbe(url) {
    engine.phase = "probing"
    var args = engine.baseArgs().concat(engine.formatArgs())

    // A search query is itself a playlist. The playlist-counting trick below
    // selects zero entries, which on a search means nothing is extracted and
    // nothing is printed — so searches take the plain path and let baseArgs'
    // --playlist-items 1 pull the single hit. ytsearch1 never returns more.
    if (url.indexOf("ytsearch") !== 0) {
      // For a real URL, --flat-playlist with zero entries selected reports how
      // big a playlist is without extracting any of it, and still prints the
      // video line for an ordinary single-video link.
      args = args.concat(["--flat-playlist", "--playlist-items", "0",
                          "--print", "playlist:OMP\t%(playlist_count,n_entries)s"])
    }

    probeProcess.command = args.concat(["--simulate", "--print", engine.probePrint, "--", url])
    probeProcess.running = true
  }

  // yt-dlp renders a missing field as the literal "NA", never as an empty
  // string, and pads every *_str field.
  function cleanField(value) {
    var text = String(value || "").trim()
    return text === "NA" || text === "N/A" ? "" : text
  }

  function applyProbe(out) {
    var lines = String(out).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split("\t")
      if (f[0] === "OMV" && !engine.probeOk) {
        engine.probeOk = true
        engine.probeTitle = engine.cleanField(f[1])
        engine.probeUploader = engine.cleanField(f[2])
        engine.probeDuration = engine.cleanField(f[3])
        engine.probeFormat = engine.cleanField(f[4])
        engine.probeResolution = engine.cleanField(f[5])
        engine.probeSize = engine.formatBytes(parseFloat(engine.cleanField(f[7])))
        engine.probeIsLive = engine.cleanField(f[8]) === "True"
        engine.probeUrl = engine.cleanField(f[9])
      } else if (f[0] === "OMP" && engine.playlistCount === 0) {
        var count = parseInt(engine.cleanField(f[1]), 10)
        engine.playlistCount = isFinite(count) ? count : 0
      }
    }
  }

  function formatBytes(bytes) {
    if (!isFinite(bytes) || bytes <= 0) return ""
    var units = ["B", "KB", "MB", "GB"]
    var value = bytes
    var unit = 0
    while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++ }
    return (value < 10 && unit > 0 ? value.toFixed(1) : Math.round(value)) + " " + units[unit]
  }

  function formatEta(seconds) {
    if (!isFinite(seconds) || seconds < 0) return ""
    var total = Math.round(seconds)
    var minutes = Math.floor(total / 60)
    var rest = total % 60
    return minutes + ":" + (rest < 10 ? "0" : "") + rest
  }

  // --- download -------------------------------------------------------------

  property bool cancelled: false
  property int streamsDone: 0
  property int streamCount: 1

  // --newline is not optional: yt-dlp emits progress separated by \r even with a
  // --progress-template set, and SplitParser splits on \n, so without it the
  // whole download arrives as one unsplit chunk and the bar never moves.
  readonly property string progressTemplate:
    "download:OMPROG\t%(progress.status)s\t%(progress._percent_str)s"
    + "\t%(progress.speed)s\t%(progress.eta)s"

  function beginDownload(url) {
    // A ytsearch1: query is a valid yt-dlp argument, not just a probe input, so
    // it has to pass here too — immediate mode hands one straight over.
    if (!engine.isFetchable(url)) { engine.fail("Not a downloadable address"); return }

    engine.cancelled = false
    engine.percent = 0
    engine.speed = 0
    engine.eta = -1
    engine.streamsDone = 0
    engine.streamCount = 1
    engine.filePath = ""
    engine.doneTitle = engine.probeTitle
    engine.errorText = ""
    engine.phase = "downloading"

    // Array form: Quickshell execve()s this directly, so quotes, spaces and
    // semicolons in the URL or the directory are inert data. The trailing "--"
    // is load-bearing — a URL of "--version" would otherwise be read as a flag,
    // and this URL comes from metadata a page controls.
    downloadProcess.command = engine.baseArgs()
      .concat(engine.formatArgs())
      .concat(["--newline", "--quiet", "--progress", "--progress-delta", "0.25",
               "--embed-metadata",
               "--restrict-filenames", "--trim-filenames", "120",
               "--paths", engine.resolvedTargetDir,
               "-o", "%(title)s [%(id)s].%(ext)s",
               "--progress-template", engine.progressTemplate,
               "--print", "before_dl:OMSTART\t%(title)s\t%(format)s",
               "--print", "after_move:OMDONE\t%(title)s\t%(filepath)s",
               "--", url])
    downloadProcess.running = true
  }

  function cancelDownload() {
    if (!downloadProcess.running) return
    engine.cancelled = true
    downloadProcess.running = false   // SIGTERM; the child is reaped in onExited
  }

  function onDownloadLine(raw) {
    var f = String(raw).split("\t")

    if (f[0] === "OMSTART") {
      engine.doneTitle = engine.cleanField(f[1]) || engine.doneTitle
      // "395 - 1920x1080+251 - audio only" is two streams. Percent restarts at
      // zero for each, which is why the fold below exists.
      engine.streamCount = Math.max(1, String(f[2] || "").split("+").length)
      return
    }
    if (f[0] === "OMDONE") {
      engine.doneTitle = engine.cleanField(f[1]) || engine.doneTitle
      engine.filePath = engine.cleanField(f[2])
      return
    }
    if (f[0] !== "OMPROG") return

    var pct = parseFloat(String(f[2] || "").replace("%", "").trim())
    if (!isFinite(pct)) pct = 0
    var folded = (engine.streamsDone + pct / 100) / engine.streamCount * 100
    if (folded > engine.percent) engine.percent = Math.min(100, folded)

    var sp = parseFloat(String(f[3] || "").trim())
    engine.speed = isFinite(sp) ? sp : 0
    var et = parseFloat(String(f[4] || "").trim())
    engine.eta = isFinite(et) ? et : -1

    if (String(f[1] || "").trim() === "finished")
      engine.streamsDone = Math.min(engine.streamCount, engine.streamsDone + 1)
  }

  // --- notifications --------------------------------------------------------

  // omarchy-notification-send reads any leading-dash argument as an option, so a
  // title like "- Whatever" makes it exit 1 and no toast appears at all.
  function safeArg(text) {
    var value = String(text || "").replace(/^[-\s]+/, "").trim()
    return value === "" ? "(untitled)" : value
  }

  function notify(args) {
    Quickshell.execDetached([engine.omarchyPath + "/bin/omarchy-notification-send"].concat(args))
  }

  function notifyDone() {
    var args = ["-g", "󰇚", "-u", "normal", "-t", "8000"]
    if (engine.filePath !== "") args = args.concat(["--exec", "xdg-open " + Util.shellQuote(engine.filePath)])
    engine.notify(args.concat(["Download complete", engine.safeArg(engine.doneTitle)]))
  }

  function notifyFail(message) {
    engine.notify(["-g", "󰀪", "-u", "critical", "Download failed", engine.safeArg(message)])
  }

  // --- settings persistence -------------------------------------------------

  readonly property string statePath:
    (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/settings/io.github.theflngdutchman.dashboard-dl.json"

  // Keys this version does not know about are round-tripped rather than dropped.
  property var rawSettings: ({})
  property bool applyingSettings: false

  function loadSettings(text) {
    var parsed = {}
    try { parsed = JSON.parse(String(text || "{}")) || {} } catch (e) { return }
    if (typeof parsed !== "object") return

    engine.rawSettings = parsed
    engine.applyingSettings = true
    if (typeof parsed.audioOnly === "boolean") engine.audioOnly = parsed.audioOnly
    if (typeof parsed.confirmFirst === "boolean") engine.confirmFirst = parsed.confirmFirst
    if (typeof parsed.audioDir === "string" && parsed.audioDir !== "") engine.audioDir = parsed.audioDir
    if (typeof parsed.videoDir === "string" && parsed.videoDir !== "") engine.videoDir = parsed.videoDir
    if (typeof parsed.ytdlpPath === "string") engine.ytdlpPath = parsed.ytdlpPath
    engine.applyingSettings = false
  }

  function saveSettings() {
    if (engine.applyingSettings) return
    saveTimer.restart()
  }

  function flushSettings() {
    var payload = engine.rawSettings || {}
    payload.version = 1
    payload.audioOnly = engine.audioOnly
    payload.confirmFirst = engine.confirmFirst
    payload.audioDir = engine.audioDir
    payload.videoDir = engine.videoDir
    payload.ytdlpPath = engine.ytdlpPath
    engine.rawSettings = payload
    settingsFile.setText(JSON.stringify(payload, null, 2) + "\n")
  }

  // --- processes and files --------------------------------------------------

  property Timer saveTimer: Timer {
    // Coalesces a burst of toggles, and keeps the directory field from writing
    // once per keystroke.
    interval: 200
    onTriggered: engine.flushSettings()
  }

  property FileView settingsFile: FileView {
    path: engine.statePath
    watchChanges: true     // emits fileChanged only — reloading is on us
    atomicWrites: true     // temp + rename, and it creates missing parent dirs
    printErrors: false     // first run is a legitimate FileNotFound
    onFileChanged: reload()          // keeps the per-monitor copies in step
    onLoaded: engine.loadSettings(text())
    onLoadFailed: function(error) {
      // No file yet on first run; the declared defaults above are the state and
      // the file appears with the first save.
      if (error !== FileViewError.FileNotFound)
        console.warn("io.github.theflngdutchman.dashboard-dl: settings load failed:", FileViewError.toString(error))
    }
    onSaveFailed: function(error) {
      console.warn("io.github.theflngdutchman.dashboard-dl: settings save failed:", FileViewError.toString(error))
    }
  }

  property Process resolveProcess: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = String(text || "").trim()
        if (found !== "") engine.ytdlpBinary = found
        engine.readVersion()
      }
    }
  }

  property Process versionProcess: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: engine.ytdlpVersion = String(text || "").trim()
    }
  }

  property string updateStdout: ""
  property string updateStderr: ""

  property Process updateProcess: Process {
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: engine.updateStdout = String(text || "").trim() }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: engine.updateStderr = String(text || "").trim() }
    onExited: function(exitCode) {
      engine.updating = false
      // A distro build refuses with "you installed with a package manager; use
      // that to update", which is the useful answer — show it rather than a
      // generic failure.
      var out = engine.updateStderr !== "" ? engine.updateStderr : engine.updateStdout
      var lines = String(out).split("\n")
      engine.updateResult = lines.length > 0 ? lines[lines.length - 1].trim() : ""
      engine.readVersion()
    }
  }

  property Process probeProcess: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: engine.applyProbe(String(text || ""))
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: engine.probeStderr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      if (engine.phase !== "probing") return
      if (engine.probeOk) engine.phase = "confirm"
      else engine.fail(engine.probeStderr !== "" ? engine.probeStderr
        : (engine.pendingKind === "search" ? "Nothing found for this track" : "Could not read media info"))
    }
  }

  property string probeStderr: ""
  property string downloadStderr: ""

  property Process downloadProcess: Process {
    stdout: SplitParser { onRead: function(line) { engine.onDownloadLine(line) } }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: engine.downloadStderr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      // Cancellation is tracked explicitly: a SIGTERM death reports as a crash
      // with a non-portable exit code, so it cannot be inferred here.
      if (engine.cancelled) {
        engine.cancelled = false
        engine.reset()
        return
      }
      if (exitCode !== 0) {
        engine.errorText = engine.downloadStderr !== "" ? engine.downloadStderr : "Download failed"
        engine.phase = "error"
        engine.notifyFail(engine.errorText)
        return
      }
      // after_move prints only after a successful download and move, so a
      // captured path is the success signal.
      engine.percent = 100
      engine.phase = "done"
      engine.notifyDone()
    }
  }
}
