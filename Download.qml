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
    resolveProcess.command = engine.withDeadline(engine.shortDeadline, ["bash", "-lc", script])
    resolveProcess.running = true
  }

  function readVersion() {
    if (versionProcess.running) return
    versionProcess.command = engine.withDeadline(engine.shortDeadline, [engine.ytdlpBinary, "--version"])
    versionProcess.running = true
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
      if (!engine.isPublicHttpUrl(url))
        return { ok: false, reason: "Local or private address — nothing to fetch" }
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

  // Anything yt-dlp will accept as its final argument: a public web address, or
  // one of its own search shorthands. Applied at the point of download as well
  // as during resolution, because the URL handed to beginDownload can be
  // probeUrl — yt-dlp's %(webpage_url)s — which a remote page controls.
  function isFetchable(url) {
    var value = String(url || "")
    if (value.indexOf("ytsearch") === 0) return true
    return engine.isPublicHttpUrl(value)
  }

  // --- address policy -------------------------------------------------------
  //
  // The URL here comes from MPRIS metadata that a web page writes, or from
  // yt-dlp's own report of where it ended up. Handing that to a fetcher without
  // a check lets a page point this plugin at the loopback interface, the LAN,
  // the tailnet, or a cloud metadata endpoint.
  //
  // Everything below is fail-closed: anything that does not parse cleanly into
  // a public address is refused. Two residual gaps are worth stating plainly
  // rather than papering over:
  //
  //   - A public hostname that *resolves* to a private address (DNS rebinding)
  //     is not detectable here. QML cannot resolve names, so the policy is
  //     applied to the literal host only.
  //   - yt-dlp follows redirects internally, so a public URL that 302s to a
  //     private one is not seen by this code.
  //
  // Both are bounded by the fact that a download only ever starts from an
  // explicit button press on a track the user is already playing.

  function isPublicHttpUrl(raw) {
    var parsed = engine.parseHttpUrl(raw)
    return parsed !== null && !engine.isBlockedHost(parsed.host)
  }

  // A deliberately strict parser. Returns null rather than guessing.
  function parseHttpUrl(raw) {
    var value = String(raw || "")
    // Control characters and spaces anywhere are a parser-confusion vector:
    // different consumers disagree about where the authority ends.
    if (/[\u0000-\u0020\u007f]/.test(value)) return null

    var m = value.match(/^(https?):\/\/([^\/?#]*)([\/?#][\s\S]*)?$/i)
    if (!m) return null
    var authority = m[2]
    if (authority === "") return null

    // Reject userinfo outright. "http://www.youtube.com@10.0.0.1/" reads as
    // YouTube to a person and resolves to 10.0.0.1.
    if (authority.indexOf("@") !== -1) return null

    var host
    if (authority.charAt(0) === "[") {
      var close = authority.indexOf("]")
      if (close === -1) return null
      host = authority.substring(1, close)
      var rest = authority.substring(close + 1)
      if (rest !== "" && !/^:[0-9]{1,5}$/.test(rest)) return null
      if (host.indexOf(":") === -1) return null      // brackets imply IPv6
    } else {
      var parts = authority.split(":")
      if (parts.length > 2) return null              // bare IPv6 without brackets
      host = parts[0]
      if (parts.length === 2 && !/^[0-9]{1,5}$/.test(parts[1])) return null
    }

    host = host.toLowerCase().replace(/\.+$/, "")     // strip the root dot
    if (host === "") return null
    return { scheme: m[1].toLowerCase(), host: host }
  }

  function isBlockedHost(host) {
    if (host.indexOf(":") !== -1) return engine.isBlockedIpv6(host)

    var v4 = engine.toIpv4(host)
    if (v4 !== null) return engine.isBlockedIpv4(v4)

    // A name with no dot resolves through local DNS, mDNS or /etc/hosts, so it
    // is by definition not a public address: localhost, router, nas.
    if (host.indexOf(".") === -1) return true
    if (/(^|\.)localhost$/.test(host)) return true
    if (/\.(local|localdomain|internal|intranet|lan|home|corp|private|test|invalid|example|onion)$/.test(host)) return true
    if (/\.home\.arpa$/.test(host)) return true
    if (/\.in-addr\.arpa$/.test(host) || /\.ip6\.arpa$/.test(host)) return true
    return false
  }

  // inet_aton accepts far more than dotted-quad: 2130706433, 0x7f000001 and
  // 0177.1 are all 127-something. Anything a resolver would accept has to be
  // normalised here or the range checks below can be walked straight past.
  function toIpv4(host) {
    var parts = String(host).split(".")
    if (parts.length < 1 || parts.length > 4) return null

    var nums = []
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i]
      if (p === "") return null
      var n
      if (/^0[xX][0-9a-fA-F]+$/.test(p)) n = parseInt(p.substring(2), 16)
      else if (/^0[0-7]+$/.test(p)) n = parseInt(p.substring(1), 8)
      else if (/^[0-9]+$/.test(p)) n = parseInt(p, 10)
      else return null                               // contains letters: a name
      if (!isFinite(n) || n < 0) return null
      nums.push(n)
    }

    // The final part absorbs every byte the earlier parts did not name.
    var last = nums[nums.length - 1]
    if (last >= Math.pow(256, 4 - (nums.length - 1))) return null
    var value = last
    for (var j = 0; j < nums.length - 1; j++) {
      if (nums[j] > 255) return null
      value += nums[j] * Math.pow(256, 3 - j)
    }
    if (value < 0 || value > 4294967295) return null
    return value
  }

  function isBlockedIpv4(v) {
    var a = Math.floor(v / 16777216) % 256
    var b = Math.floor(v / 65536) % 256
    if (a === 0) return true                              // 0.0.0.0/8
    if (a === 10) return true                             // RFC1918
    if (a === 127) return true                            // loopback
    if (a === 169 && b === 254) return true               // link-local, incl. 169.254.169.254
    if (a === 172 && b >= 16 && b <= 31) return true      // RFC1918
    if (a === 192 && b === 168) return true               // RFC1918
    if (a === 100 && b >= 64 && b <= 127) return true     // CGNAT, and the tailnet range
    if (a === 192 && b === 0) return true                 // IETF protocol assignments, TEST-NET-1
    if (a === 198 && (b === 18 || b === 19)) return true  // benchmarking
    if (a >= 224) return true                             // multicast, reserved, broadcast
    return false
  }

  function isBlockedIpv6(host) {
    var h = String(host).toLowerCase()
    // IPv4-mapped and -compatible forms smuggle a v4 address through a v6 literal.
    var mapped = h.match(/^::(?:ffff:)?([0-9.]+)$/)
    if (mapped) {
      var v = engine.toIpv4(mapped[1])
      return v === null ? true : engine.isBlockedIpv4(v)
    }
    if (h === "::" || h === "::1") return true
    if (/^fe[89ab]/.test(h)) return true    // fe80::/10 link-local
    if (/^f[cd]/.test(h)) return true       // fc00::/7 unique local
    if (/^ff/.test(h)) return true          // ff00::/8 multicast
    return false
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
    engine.errorText = engine.clamp(message || "Download failed", engine.maxMessageChars)
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

  // --- bounds ---------------------------------------------------------------
  //
  // Neither Process nor StdioCollector can cap runtime or buffered output, so
  // every child is bounded on the producing side instead: `timeout` is argv[0],
  // which keeps the whole command in execve array form — no shell is re-entered
  // to build a pipeline. SIGTERM first, SIGKILL after a grace period, so a hung
  // or malicious server cannot pin a process inside the resident shell forever.
  //
  // Whatever still arrives is truncated before it is stored or rendered.

  readonly property int probeDeadline: 90       // seconds
  readonly property int shortDeadline: 30       // --version, -U, binary resolution
  readonly property int downloadDeadline: 21600 // 6h: a long video on a slow line
  readonly property int killGrace: 5

  readonly property int maxFieldChars: 300      // one probe field
  readonly property int maxMessageChars: 2000   // a stderr message shown to the user
  readonly property int maxLineChars: 4000      // one progress line
  readonly property int maxProbeLines: 200

  function withDeadline(seconds, argv) {
    return ["timeout", "-k", String(engine.killGrace), String(seconds)].concat(argv)
  }

  function clamp(value, limit) {
    var text = String(value === undefined || value === null ? "" : value)
    return text.length > limit ? text.substring(0, limit) + "…" : text
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

    probeProcess.command = engine.withDeadline(engine.probeDeadline,
      args.concat(["--simulate", "--no-progress", "--print", engine.probePrint, "--", url]))
    probeProcess.running = true
  }

  // yt-dlp renders a missing field as the literal "NA", never as an empty
  // string, and pads every *_str field.
  function cleanField(value) {
    var text = engine.clamp(String(value || "").trim(), engine.maxFieldChars)
    return text === "NA" || text === "N/A" ? "" : text
  }

  function applyProbe(out) {
    var lines = String(out).split("\n")
    if (lines.length > engine.maxProbeLines) lines = lines.slice(0, engine.maxProbeLines)
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
    downloadProcess.command = engine.withDeadline(engine.downloadDeadline,
      engine.baseArgs()
      .concat(engine.formatArgs())
      .concat(["--newline", "--quiet", "--progress", "--progress-delta", "0.25",
               "--embed-metadata",
               "--restrict-filenames", "--trim-filenames", "120",
               "--paths", engine.resolvedTargetDir,
               "-o", "%(title)s [%(id)s].%(ext)s",
               "--progress-template", engine.progressTemplate,
               "--print", "before_dl:OMSTART\t%(title)s\t%(format)s",
               "--print", "after_move:OMDONE\t%(title)s\t%(filepath)s",
               "--", url]))
    downloadProcess.running = true
  }

  function cancelDownload() {
    if (!downloadProcess.running) return
    engine.cancelled = true
    downloadProcess.running = false   // SIGTERM; the child is reaped in onExited
  }

  function onDownloadLine(raw) {
    var f = engine.clamp(raw, engine.maxLineChars).split("\t")

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

  readonly property int maxSettingsBytes: 64 * 1024
  readonly property int maxPathChars: 4096
  readonly property int maxUnknownKeys: 32

  function loadSettings(text) {
    // A state file is not a trusted input just because it lives under $HOME:
    // anything with write access to the directory can replace it. Bound it
    // before parsing, and again before anything reaches a property.
    var raw = String(text || "{}")
    if (raw.length > engine.maxSettingsBytes) {
      console.warn("io.github.theflngdutchman.dashboard-dl: settings file too large, ignoring")
      return
    }

    var parsed = {}
    try { parsed = JSON.parse(raw) || {} } catch (e) { return }
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return

    // Unknown keys are round-tripped so a newer version's settings survive an
    // older one, but an unbounded number of them is just a growth vector.
    var known = { version: 1, audioOnly: 1, confirmFirst: 1, audioDir: 1, videoDir: 1, ytdlpPath: 1 }
    var kept = ({})
    var extras = 0
    for (var k in parsed) {
      if (known[k]) { kept[k] = parsed[k]; continue }
      if (extras >= engine.maxUnknownKeys) continue
      var v = parsed[k]
      var t = typeof v
      if (t !== "string" && t !== "number" && t !== "boolean") continue
      kept[k] = t === "string" ? engine.clamp(v, engine.maxPathChars) : v
      extras++
    }

    engine.rawSettings = kept
    engine.applyingSettings = true
    if (typeof parsed.audioOnly === "boolean") engine.audioOnly = parsed.audioOnly
    if (typeof parsed.confirmFirst === "boolean") engine.confirmFirst = parsed.confirmFirst
    if (engine.isUsablePath(parsed.audioDir)) engine.audioDir = engine.clamp(parsed.audioDir, engine.maxPathChars)
    if (engine.isUsablePath(parsed.videoDir)) engine.videoDir = engine.clamp(parsed.videoDir, engine.maxPathChars)
    if (typeof parsed.ytdlpPath === "string") engine.ytdlpPath = engine.clamp(parsed.ytdlpPath, engine.maxPathChars)
    engine.applyingSettings = false
  }

  // A destination is passed to yt-dlp as --paths. Newlines and NULs in an argv
  // entry are not a shell problem here (there is no shell) but they do produce
  // unreadable paths and confusing errors, so reject them outright.
  function isUsablePath(value) {
    if (typeof value !== "string" || value === "") return false
    if (value.length > engine.maxPathChars) return false
    return !/[\u0000-\u001f]/.test(value)
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
        var found = engine.clamp(String(text || "").trim(), 4096)
        if (found !== "") engine.ytdlpBinary = found
        engine.readVersion()
      }
    }
  }

  property Process versionProcess: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: engine.ytdlpVersion = engine.clamp(String(text || "").trim(), engine.maxFieldChars)
    }
  }

  property Process probeProcess: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: engine.applyProbe(String(text || ""))
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: engine.probeStderr = engine.clamp(String(text || "").trim(), engine.maxMessageChars)
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
      onStreamFinished: engine.downloadStderr = engine.clamp(String(text || "").trim(), engine.maxMessageChars)
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
