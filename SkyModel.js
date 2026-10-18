.pragma library

// Pure helpers for SkyAgent. Keep all QML/UI out of this file so the behaviour
// can be tested with Node as well.

function defaults() {
  return {
    voice: "af_sky",
    speed: 1.0,
    speakReplies: true,
    openPanelOnVoice: true,
    allowGuardedActions: false,
    sessionId: "",
    kokoroBaseUrl: "http://127.0.0.1:8880",
    cwd: "~/Projects"
  };
}

function mergeConfig(input) {
  var out = defaults()
  if (!input || typeof input !== "object" || Array.isArray(input)) return out

  if (typeof input.voice === "string" && input.voice.trim()) out.voice = input.voice.trim()
  if (typeof input.speed === "number" && isFinite(input.speed)) {
    out.speed = Math.max(0.5, Math.min(2.0, input.speed))
  }
  if (typeof input.speakReplies === "boolean") out.speakReplies = input.speakReplies
  if (typeof input.openPanelOnVoice === "boolean") out.openPanelOnVoice = input.openPanelOnVoice
  if (typeof input.allowGuardedActions === "boolean") out.allowGuardedActions = input.allowGuardedActions
  if (typeof input.sessionId === "string" && isValidSessionId(input.sessionId)) out.sessionId = input.sessionId
  if (typeof input.kokoroBaseUrl === "string" && input.kokoroBaseUrl.trim()) {
    out.kokoroBaseUrl = input.kokoroBaseUrl.trim()
  }
  if (typeof input.cwd === "string" && input.cwd.trim()) out.cwd = input.cwd.trim()
  return out
}

function serializeConfig(config) {
  return JSON.stringify(mergeConfig(config), null, 2) + "\n"
}

function parseJson(text, fallback) {
  try {
    return JSON.parse(String(text || ""))
  } catch (error) {
    return fallback
  }
}

function pad2(value) {
  return (value < 10 ? "0" : "") + value
}

function newSessionId(now) {
  var date = now instanceof Date ? now : new Date()
  var suffix = Math.random().toString(36).slice(2, 5)
  return "skyagent-"
    + date.getFullYear()
    + pad2(date.getMonth() + 1)
    + pad2(date.getDate())
    + "-"
    + pad2(date.getHours())
    + pad2(date.getMinutes())
    + pad2(date.getSeconds())
    + "-"
    + suffix
}

function isValidSessionId(value) {
  var text = String(value || "")
  return text.length > 0 && text.length <= 100 && /^[A-Za-z0-9._-]+$/.test(text)
}

function expandHome(path, home) {
  var value = String(path || "")
  if (value === "~") return String(home || "")
  if (value.indexOf("~/") === 0) return String(home || "") + value.slice(1)
  return value
}

function normalizeBaseUrl(value) {
  var url = String(value || "").trim()
  while (url.length > 0 && url.charAt(url.length - 1) === "/") url = url.slice(0, -1)
  return url || "http://127.0.0.1:8880"
}

function kokoroSpeechUrl(baseUrl) {
  var base = normalizeBaseUrl(baseUrl)
  if (/\/v1$/.test(base)) return base + "/audio/speech"
  return base + "/v1/audio/speech"
}

function kokoroVoicesUrl(baseUrl) {
  var base = normalizeBaseUrl(baseUrl)
  if (/\/v1$/.test(base)) return base + "/audio/voices"
  return base + "/v1/audio/voices"
}

function kokoroHealthUrl(baseUrl) {
  var base = normalizeBaseUrl(baseUrl)
  if (/\/v1$/.test(base)) return base.replace(/\/v1$/, "") + "/health"
  return base + "/health"
}

function parseSession(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var entry = parseJson(line, null)
    if (!entry || typeof entry !== "object") continue
    if (entry.role !== "user" && entry.role !== "assistant") continue
    if (typeof entry.content !== "string") continue
    out.push({
      role: entry.role,
      content: entry.content,
      ts: typeof entry.ts === "string" ? entry.ts : ""
    })
  }
  return out
}

function parseVoxtypeOutcome(text) {
  var parsed = parseJson(String(text || "").trim(), null)
  if (!parsed || typeof parsed !== "object") {
    return { ok: false, status: "error", text: "", message: "Could not parse voxtype output." }
  }
  var transcript = typeof parsed.text === "string" ? parsed.text.trim() : ""
  return {
    ok: transcript.length > 0,
    status: typeof parsed.status === "string" ? parsed.status : "",
    text: transcript,
    message: typeof parsed.message === "string" ? parsed.message : ""
  }
}

function truncate(text, maxChars) {
  var value = String(text || "")
  var limit = Number(maxChars) || 0
  if (limit <= 0 || value.length <= limit) return value
  return value.slice(0, limit)
}

var LANGUAGE_NAMES = {
  "en-us": "English (US)",
  "en-gb": "English (UK)",
  "es": "Spanish",
  "fr-fr": "French",
  "hi": "Hindi",
  "it": "Italian",
  "ja": "Japanese",
  "pt-br": "Portuguese (Brazil)",
  "zh": "Chinese"
}

function languageName(code) {
  var key = String(code || "").toLowerCase()
  return LANGUAGE_NAMES[key] || String(code || "unknown")
}

function formatVoiceOptions(jsonText) {
  var parsed = parseJson(String(jsonText || "").trim(), null)
  var raw = parsed && Array.isArray(parsed.voices) ? parsed.voices : []
  var options = []
  for (var i = 0; i < raw.length; i++) {
    var voice = raw[i]
    if (!voice || typeof voice.id !== "string") continue
    var language = languageName(voice.language)
    var gender = String(voice.gender || "voice")
    options.push({
      value: voice.id,
      label: voice.id + " · " + language + " · " + gender,
      description: language + ", " + gender,
      language: String(voice.language || ""),
      gender: gender
    })
  }
  options.sort(function(left, right) {
    if (left.language !== right.language) return left.language < right.language ? -1 : 1
    if (left.gender !== right.gender) return left.gender < right.gender ? -1 : 1
    return left.value < right.value ? -1 : (left.value > right.value ? 1 : 0)
  })
  var hasSky = false
  for (var j = 0; j < options.length; j++) if (options[j].value === "af_sky") hasSky = true
  if (!hasSky) {
    options.unshift({
      value: "af_sky",
      label: "af_sky · English (US) · female",
      description: "English (US), female",
      language: "en-us",
      gender: "female"
    })
  }
  return options
}

function displayText(text) {
  var value = String(text || "")
  value = value.replace(/\r\n/g, "\n")
  value = value.replace(/```[A-Za-z0-9_-]*\n?/g, "")
  value = value.replace(/```/g, "")
  value = value.replace(/`([^`\n]+)`/g, "$1")
  value = value.replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
  value = value.replace(/\[([^\]]+)\]\(([^)]+)\)/g, "$1 ($2)")
  value = value.replace(/^\s{0,3}#{1,6}\s+/gm, "")
  value = value.replace(/(\*\*|__)(.*?)\1/g, "$2")
  value = value.replace(/(\*|_)(.*?)\1/g, "$2")
  value = value.replace(/^\s*[-*+]\s+/gm, "")
  value = value.replace(/^\s*>\s?/gm, "")
  value = value.replace(/\n{3,}/g, "\n\n")
  return value.trim()
}

function speechText(text) {
  var value = String(text || "")
  value = value.replace(/```[\s\S]*?```/g, " The code is in the panel. ")
  value = value.replace(/`([^`\n]+)`/g, "$1")
  value = value.replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
  value = value.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
  value = value.replace(/https?:\/\/\S+/g, " a link ")
  value = displayText(value)
  value = value.replace(/\s+/g, " ").trim()
  return value
}

function splitSpeech(text, maxChars) {
  var limit = Math.max(40, Number(maxChars) || 350)
  var source = String(text || "").replace(/\s+/g, " ").trim()
  if (!source) return []

  var pieces = []
  var start = 0
  for (var i = 0; i < source.length; i++) {
    var ch = source.charAt(i)
    var next = i + 1 < source.length ? source.charAt(i + 1) : ""
    if ((ch === "." || ch === "!" || ch === "?") && (next === "" || next === " ")) {
      var sentence = source.slice(start, i + 1).trim()
      if (sentence) pieces.push(sentence)
      start = i + 1
    }
  }
  var tail = source.slice(start).trim()
  if (tail) pieces.push(tail)

  var out = []
  for (var p = 0; p < pieces.length; p++) {
    var piece = pieces[p]
    while (piece.length > limit) {
      var cut = piece.lastIndexOf(" ", limit)
      if (cut < Math.floor(limit / 4)) cut = limit
      out.push(piece.slice(0, cut).trim())
      piece = piece.slice(cut).trim()
    }
    if (piece) out.push(piece)
  }
  return out
}

function toolLabel(name) {
  var tool = String(name || "")
  if (tool === "fetch_url") return "Searching the web…"
  if (tool === "read_file" || tool === "list_dir") return "Reading files…"
  if (tool === "write_file" || tool === "edit_file" || tool === "append_file" || tool === "rename_file") {
    return "Updating files…"
  }
  if (tool === "run_command") return "Running a command…"
  if (tool === "remember" || tool === "search_memory" || tool === "forget") return "Using memory…"
  if (tool === "load_skill") return "Loading a skill…"
  return tool ? "Using " + tool + "…" : "Working…"
}

function filterStderr(text) {
  var lines = String(text || "").split("\n")
  var useful = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    if (line.indexOf("bash: cannot set terminal process group") === 0) continue
    if (line.indexOf("bash: no job control") === 0) continue
    if (line.indexOf("This run cannot ask") === 0) continue
    if (line.indexOf("Re-run with --yes") === 0) continue
    useful.push(line)
  }
  if (useful.length === 0) return ""
  return useful.slice(Math.max(0, useful.length - 3)).join("\n")
}

// Wrapper for basicagent. It saves the previous last-session pointer, then
// execs basicagent so the process SkyAgent sees (and can terminate) is the
// agent itself. SkyAgent restores the pointer after the process exits.
function basicagentWrapperScript() {
  return [
    'session="$1"',
    'allow="$2"',
    'workdir="$3"',
    'pointer="$4"',
    'saved="$5"',
    'prev=""',
    'mkdir -p "$(dirname "$saved")" 2>/dev/null || true',
    'if [ -f "$pointer" ]; then prev=$(cat "$pointer" 2>/dev/null || true); fi',
    'if [ -n "$prev" ]; then',
    '  printf "%s\\n" "$prev" > "$saved" 2>/dev/null || true',
    'else',
    '  printf "@@NONE@@\\n" > "$saved" 2>/dev/null || true',
    'fi',
    'set -- --json --session "$session" --cwd "$workdir"',
    'if [ "$allow" = "1" ]; then set -- "$@" --yes; fi',
    'exec basicagent "$@"'
  ].join("\n")
}

function restorePointerScript() {
  return [
    'pointer="$1"',
    'saved="$2"',
    'if [ ! -f "$saved" ]; then exit 0; fi',
    'first=$(head -n 1 "$saved" 2>/dev/null || true)',
    'if [ "$first" = "@@NONE@@" ]; then',
    '  rm -f "$pointer" 2>/dev/null || true',
    'else',
    '  mkdir -p "$(dirname "$pointer")" 2>/dev/null || true',
    '  cat "$saved" > "$pointer" 2>/dev/null || true',
    'fi',
    'rm -f "$saved" 2>/dev/null || true'
  ].join("\n")
}

function nowIso() {
  return new Date().toISOString()
}
