import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "SkyModel.js" as SkyModel

Item {
  id: root

  property var bar: null
  property var hostWidget: null
  property var anchorItem: null
  property var manifest: null

  property bool opened: false
  property string view: "chat"
  property string agentState: "idle"
  property string toolStatus: ""
  property string notice: ""
  property bool noticeIsError: false
  property string blockedNotice: ""

  property bool configLoaded: false
  property bool basicConfigLoaded: false
  property bool bootstrapped: false
  property var config: SkyModel.defaults()
  property var basicConfig: ({})
  property string dataDir: ""
  property string sessionId: ""
  property bool sessionLoading: false
  property bool configDirty: false
  property string pendingConfig: ""

  property string pendingQuestion: ""
  property string streamingAnswer: ""
  property int currentAssistantIndex: -1
  property bool agentRunning: false
  property bool agentDone: false
  property bool agentCancelled: false
  property string agentError: ""

  property bool recordingStarted: false
  property bool voiceStopPending: false
  property bool voiceCancelled: false
  property string voiceFile: ""

  property var voices: SkyModel.formatVoiceOptions("")
  property bool voicesLoading: false
  property string voicesError: ""

  property var speechQueue: []
  property var speechReady: []
  property var speechFailed: []
  property int speechSynthIndex: 0
  property int speechPlayIndex: 0
  property bool speechSynthBusy: false
  property bool speechPlayBusy: false
  property bool speechActive: false
  property string speechToken: ""
  property int speechGeneration: 0
  property string synthJson: ""
  property int synthIndex: -1
  property int synthGeneration: -1
  property int playGeneration: -1

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configDir: home + "/.config/skyagent"
  readonly property string configFile: configDir + "/config.json"
  readonly property string basicConfigFile: home + "/.config/basicagent/config.json"
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/skyagent"
  readonly property string defaultDataDir: {
    var base = Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")
    return base + "/basicagent"
  }
  readonly property string lastSessionPointer: dataDir !== "" ? dataDir + "/last-session.txt" : ""
  readonly property string lastSessionSaved: runtimeDir + "/last-session.prev"
  readonly property string sessionPath: dataDir !== "" && sessionId !== "" ? dataDir + "/sessions/" + sessionId + ".jsonl" : ""
  readonly property string workdir: SkyModel.expandHome(config.cwd || "~/Projects", home)
  readonly property string kokoroBase: SkyModel.normalizeBaseUrl(config.kokoroBaseUrl)
  readonly property string speechUrl: SkyModel.kokoroSpeechUrl(kokoroBase)
  readonly property string voicesUrl: SkyModel.kokoroVoicesUrl(kokoroBase)
  readonly property bool allowActions: config.allowGuardedActions === true

  readonly property color foreground: Commons.Color.popups.text
  readonly property color background: Commons.Color.popups.background
  readonly property color borderColor: Commons.Color.popups.border
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius

  readonly property string stateLabel: {
    if (agentState === "listening") return "Listening…"
    if (agentState === "transcribing") return "Transcribing…"
    if (agentState === "thinking") return "Thinking…"
    if (agentState === "speaking") return "Speaking…"
    if (agentState === "error") return "Error"
    return "Ready"
  }
  readonly property color stateColor: agentState === "error" ? urgent : (agentState === "idle" ? foreground : accent)
  readonly property bool busy: agentRunning || speechActive || voiceStartProc.running || voiceStopProc.running
  readonly property string statusLine: {
    if (blockedNotice !== "") return blockedNotice
    if (toolStatus !== "") return toolStatus
    if (notice !== "") return notice
    if (voicesError !== "" && view === "settings") return voicesError
    return ""
  }
  readonly property bool statusIsError: blockedNotice !== "" || noticeIsError || (voicesError !== "" && view === "settings")

  function open() {
    opened = true
    view = "chat"
    Qt.callLater(function() {
      if (inputField) inputField.forceActiveFocus()
    })
  }

  function close() {
    opened = false
  }

  function togglePanel() {
    if (opened) close()
    else open()
  }

  function handleEscape() {
    if (allowActionsConfirm.opened) {
      allowActionsConfirm.opened = false
      return
    }
    if (view === "settings") {
      view = "chat"
      Qt.callLater(function() { if (inputField) inputField.forceActiveFocus() })
      return
    }
    close()
  }

  function toggleView() {
    if (view === "settings") {
      view = "chat"
      Qt.callLater(function() { if (inputField) inputField.forceActiveFocus() })
    } else {
      view = "settings"
      loadVoices()
    }
  }

  function scrollToBottom() {
    if (messageList) messageList.positionViewAtEnd()
  }

  function setNotice(text, isError) {
    notice = String(text || "")
    noticeIsError = isError === true
    if (notice === "") noticeTimer.stop()
    else noticeTimer.restart()
  }

  function setError(text) {
    agentState = "error"
    setNotice(text, true)
    stateResetTimer.restart()
  }

  function updateConfig(key, value) {
    var next = {}
    for (var k in config) next[k] = config[k]
    next[key] = value
    config = SkyModel.mergeConfig(next)
    if (configLoaded) saveConfigDebounce.restart()
  }

  function saveConfigNow() {
    if (!configLoaded) return
    if (configWriteProc.running) {
      configDirty = true
      return
    }
    pendingConfig = SkyModel.serializeConfig(config)
    configWriteProc.command = [
      "bash", "-c",
      "set -e; d=$(dirname -- \"$1\"); install -d -m 700 -- \"$d\"; tmp=$(mktemp \"$d/.tmp.XXXXXX\"); trap 'rm -f \"$tmp\"' EXIT; chmod 600 \"$tmp\"; cat > \"$tmp\"; mv -f \"$tmp\" \"$1\"; chmod 600 \"$1\"",
      "bash", configFile
    ] 
    configWriteProc.stdinEnabled = true
    configWriteProc.running = true
  }

  function applySkyConfigText(raw) {
    var parsed = SkyModel.parseJson(String(raw || ""), null)
    config = SkyModel.mergeConfig(parsed)
    configLoaded = true
    maybeBootstrap()
  }

  function applyBasicConfigText(raw) {
    var parsed = SkyModel.parseJson(String(raw || ""), null)
    basicConfig = parsed && typeof parsed === "object" ? parsed : ({})
    basicConfigLoaded = true
    maybeBootstrap()
  }

  function resolveDataDir() {
    var configured = basicConfig && basicConfig.memory && basicConfig.memory.dir
      ? String(basicConfig.memory.dir) : ""
    if (configured !== "") {
      return SkyModel.expandHome(configured, home).replace(/\/+$/, "")
    }
    return defaultDataDir
  }

  function maybeBootstrap() {
    if (!configLoaded || !basicConfigLoaded || bootstrapped) return
    bootstrapped = true
    dataDir = resolveDataDir()

    var sid = SkyModel.isValidSessionId(config.sessionId) ? config.sessionId : SkyModel.newSessionId()
    if (sid !== config.sessionId) {
      var next = {}
      for (var k in config) next[k] = config[k]
      next.sessionId = sid
      config = SkyModel.mergeConfig(next)
      saveConfigDebounce.stop()
      saveConfigNow()
    }
    sessionId = sid

    setupDirsProc.running = true
    cleanupProc.running = true
    // If a previous shell instance died mid-turn, put last-session.txt back.
    restorePointerProc.running = true
    loadSession()
    loadVoices()

    if (basicConfig && basicConfig.memory && basicConfig.memory.enabled === false) {
      setNotice("basicagent memory is disabled; conversations and facts will not be saved.", true)
    }
  }

  function loadSession() {
    if (sessionPath === "") return
    sessionLoading = true
    sessionReadProc.command = [
      "bash", "-c", "cat -- \"$1\" 2>/dev/null || true", "bash", sessionPath
    ]
    sessionReadProc.running = true
  }

  function applySessionText(raw) {
    sessionLoading = false
    if (agentRunning) return
    messagesModel.clear()
    currentAssistantIndex = -1
    var rows = SkyModel.parseSession(String(raw || ""))
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      messagesModel.append({
        role: row.role,
        content: row.role === "assistant" ? SkyModel.displayText(row.content) : row.content,
        isError: false,
        streaming: false,
        ts: row.ts
      })
    }
    scrollToBottom()
  }

  function appendRow(role, content, isError, streaming) {
    messagesModel.append({
      role: String(role || "assistant"),
      content: String(content || ""),
      isError: isError === true,
      streaming: streaming === true,
      ts: SkyModel.nowIso()
    })
    return messagesModel.count - 1
  }

  function setAssistantText(text, streaming, isError) {
    if (currentAssistantIndex < 0 || currentAssistantIndex >= messagesModel.count) return
    messagesModel.setProperty(currentAssistantIndex, "content", SkyModel.displayText(String(text || "")))
    messagesModel.setProperty(currentAssistantIndex, "streaming", streaming === true)
    messagesModel.setProperty(currentAssistantIndex, "isError", isError === true)
  }

  function setAssistantError(message) {
    var text = "Error: " + String(message || "Something went wrong.")
    if (currentAssistantIndex < 0 || currentAssistantIndex >= messagesModel.count) {
      currentAssistantIndex = appendRow("assistant", text, true, false)
    } else {
      messagesModel.setProperty(currentAssistantIndex, "content", text)
      messagesModel.setProperty(currentAssistantIndex, "streaming", false)
      messagesModel.setProperty(currentAssistantIndex, "isError", true)
    }
  }

  function sendTyped() {
    if (agentRunning) return
    var text = String(inputField.text || "").trim()
    if (!text) return
    inputField.text = ""
    sendQuestion(text)
  }

  function sendQuestion(text) {
    var question = String(text || "").trim()
    if (!question || agentRunning) return

    stopSpeech()
    blockedNotice = ""
    notice = ""
    toolStatus = ""
    agentError = ""
    agentDone = false
    agentCancelled = false
    streamingAnswer = ""
    pendingQuestion = question

    appendRow("user", question, false, false)
    currentAssistantIndex = appendRow("assistant", "", false, true)
    agentRunning = true
    agentState = "thinking"

    if (!SkyModel.isValidSessionId(sessionId)) {
      sessionId = SkyModel.newSessionId()
      updateConfig("sessionId", sessionId)
      saveConfigNow()
    }

    agentProc.command = [
      "bash", "-ic", SkyModel.basicagentWrapperScript(),
      "bash",
      sessionId,
      allowActions ? "1" : "0",
      workdir,
      lastSessionPointer,
      lastSessionSaved
    ]
    agentProc.stdinEnabled = true
    agentProc.running = true
  }

  function handleAgentLine(line) {
    var event = SkyModel.parseJson(String(line || ""), null)
    if (!event || typeof event !== "object") return

    if (event.type === "assistant_delta") {
      streamingAnswer += String(event.text || "")
      setAssistantText(streamingAnswer, true, false)
      messageList.follow = messageList.atYEnd
    } else if (event.type === "tool_start") {
      // The final persisted assistant message only contains the answer from
      // the last iteration. Discard any pre-tool chatter so the live thread
      // matches the session basicagent will save.
      streamingAnswer = ""
      setAssistantText("", true, false)
      toolStatus = SkyModel.toolLabel(event.name)
      agentState = "thinking"
    } else if (event.type === "tool_end") {
      toolStatus = ""
      if (event.ok === false && blockedNotice === "") {
        var toolError = event.result && event.result.error ? String(event.result.error) : "Tool call failed."
        setNotice(toolError.split("\n")[0], true)
      }
    } else if (event.type === "approval") {
      var description = String(event.description || "guarded action")
      if (event.approved === true) {
        setNotice("Auto-approved: " + SkyModel.truncate(description, 180), false)
      } else {
        blockedNotice = "Blocked: " + description + " (one-shot mode cannot ask for approval)"
      }
    } else if (event.type === "warning") {
      setNotice(String(event.message || "Warning"), false)
    } else if (event.type === "error") {
      agentError = String(event.message || "basicagent failed.")
      setAssistantError(agentError)
      setError(agentError)
    } else if (event.type === "done") {
      agentDone = true
      finishAnswer(String(event.text || streamingAnswer))
    }
  }

  function finishAnswer(text) {
    var finalText = String(text || streamingAnswer || "").trim()
    if (!finalText) {
      setAssistantError("basicagent returned an empty answer.")
      setError("basicagent returned an empty answer.")
      return
    }
    setAssistantText(finalText, false, false)
    messageList.follow = true
    scrollToBottom()
    if (config.speakReplies) startSpeech(finalText)
    else if (!agentRunning) agentState = "idle"
  }

  function handleAgentFailure(message) {
    var text = String(message || "basicagent failed.")
    agentError = text
    setAssistantError(text)
    agentRunning = false
    toolStatus = ""
    setError(text)
    if (agentProc.running) agentProc.running = false
    restorePointerProc.running = true
  }

  function cancelAgent() {
    if (!agentRunning) return
    agentCancelled = true
    agentRunning = false
    toolStatus = ""
    if (agentProc.running) agentProc.running = false
    if (currentAssistantIndex >= 0 && currentAssistantIndex < messagesModel.count) {
      messagesModel.remove(currentAssistantIndex, 1)
    }
    currentAssistantIndex = -1
    agentState = "idle"
    setNotice("Stopped.", false)
    restorePointerProc.running = true
  }

  function handleAgentFinished(code) {
    restorePointerProc.running = true
    var wasCancelled = agentCancelled
    agentCancelled = false
    agentRunning = false
    toolStatus = ""

    if (wasCancelled) {
      agentState = "idle"
      return
    }

    if (code !== 0 && agentError === "") {
      var detail = SkyModel.filterStderr(String(agentStderr.text || ""))
      handleAgentFailure(detail || ("basicagent exited with code " + code))
      return
    }
    if (!agentDone && agentError === "") {
      handleAgentFailure("basicagent ended without a final answer.")
      return
    }
    if (agentState === "error") return
    if (!speechActive) agentState = "idle"
  }

  function stopAll() {
    cancelAgent()
    cancelVoice()
    stopSpeech()
    agentState = "idle"
    toolStatus = ""
  }

  function newSession() {
    stopAll()
    sessionId = SkyModel.newSessionId()
    updateConfig("sessionId", sessionId)
    saveConfigNow()
    messagesModel.clear()
    currentAssistantIndex = -1
    pendingQuestion = ""
    streamingAnswer = ""
    blockedNotice = ""
    notice = ""
    view = "chat"
    setNotice("Started a new conversation.", false)
  }

  function startVoice() {
    if (voiceStartProc.running || voiceStopProc.running || recordingStarted) return
    if (agentState === "transcribing") return
    if (agentRunning) cancelAgent()
    stopSpeech()

    blockedNotice = ""
    notice = ""
    voiceCancelled = false
    voiceStopPending = false
    recordingStarted = false
    agentState = "listening"
    voiceFile = runtimeDir + "/voice-" + Date.now() + ".txt"

    voiceStartProc.command = ["voxtype", "record", "start", "--file", voiceFile]
    voiceStartProc.running = true
  }

  function stopVoice() {
    if (voiceCancelled) return
    if (voiceStartProc.running) {
      voiceStopPending = true
      return
    }
    if (!recordingStarted) {
      agentState = "idle"
      return
    }
    recordingStarted = false
    agentState = "transcribing"
    voiceStopProc.command = ["voxtype", "record", "stop", "--wait", "--json", "--timeout", "120"]
    voiceStopProc.running = true
  }

  function cancelVoice() {
    if (!voiceStartProc.running && !voiceStopProc.running && !recordingStarted) return
    voiceCancelled = true
    voiceStopPending = false
    var shouldCancel = recordingStarted || voiceStartProc.running || voiceStopProc.running
    if (voiceStartProc.running) voiceStartProc.running = false
    if (voiceStopProc.running) voiceStopProc.running = false
    if (shouldCancel) {
      voiceCancelProc.command = ["voxtype", "record", "cancel"]
      voiceCancelProc.running = true
    }
    recordingStarted = false
    if (agentState === "listening" || agentState === "transcribing") agentState = "idle"
    cleanupVoiceFile()
  }

  function handleVoiceStartExited(code) {
    if (voiceCancelled) {
      voiceCancelled = false
      agentState = "idle"
      return
    }
    if (code === 0) {
      recordingStarted = true
      if (voiceStopPending) {
        voiceStopPending = false
        stopVoice()
      }
    } else {
      recordingStarted = false
      voiceStopPending = false
      cleanupVoiceFile()
      setError("Could not start voxtype recording. Is the voxtype daemon running?")
    }
  }

  function handleVoiceStop(code, raw) {
    var wasCancelled = voiceCancelled
    voiceCancelled = false
    recordingStarted = false
    cleanupVoiceFile()
    if (wasCancelled) {
      agentState = "idle"
      return
    }

    var outcome = SkyModel.parseVoxtypeOutcome(raw)
    if (outcome.ok) {
      if (config.openPanelOnVoice) open()
      sendQuestion(outcome.text)
      return
    }

    agentState = "idle"
    if (outcome.status === "empty" || code === 3) {
      setNotice("Didn't catch that.", false)
    } else {
      setNotice(outcome.message || SkyModel.filterStderr(String(voiceStopStdout.text || "")) || "Transcription failed.", true)
    }
  }

  function cleanupVoiceFile() {
    if (voiceFile === "") return
    voiceCleanupProc.command = ["bash", "-c", "rm -f -- \"$1\"", "bash", voiceFile]
    voiceCleanupProc.running = true
    voiceFile = ""
  }

  function loadVoices() {
    if (voicesProc.running) return
    voicesLoading = true
    voicesError = ""
    voicesProc.command = ["curl", "-sS", "--max-time", "10", voicesUrl]
    voicesProc.running = true
  }

  function applyVoices(code, raw) {
    voicesLoading = false
    var options = SkyModel.formatVoiceOptions(String(raw || ""))
    var selected = String(config.voice || "af_sky")
    var found = false
    for (var i = 0; i < options.length; i++) if (options[i].value === selected) found = true
    if (!found) {
      options.push({ value: selected, label: selected + " · saved voice", description: "Saved voice" })
    }
    voices = options
    if (code !== 0 && options.length <= 1) {
      voicesError = "Could not load the Kokoro voice list; using af_sky."
    } else {
      voicesError = ""
    }
  }

  function setVoice(value) {
    var voice = String(value || "").trim()
    if (voice === "" || voice === config.voice) return
    updateConfig("voice", voice)
  }

  function setSpeed(value) {
    var speed = Math.max(0.5, Math.min(2.0, Number(value) || 1.0))
    speed = Math.round(speed * 100) / 100
    if (speed === config.speed) return
    updateConfig("speed", speed)
  }

  function setSpeakReplies(value) {
    var enabled = value === true
    updateConfig("speakReplies", enabled)
    if (!enabled) stopSpeech()
  }

  function setOpenPanelOnVoice(value) {
    updateConfig("openPanelOnVoice", value === true)
  }

  function setAllowActions(value) {
    var enabled = value === true
    updateConfig("allowGuardedActions", enabled)
    if (enabled) setNotice("Guarded actions will be auto-approved for new questions.", false)
    else setNotice("Guarded actions are denied unless basicagent can ask.", false)
  }

  function previewVoice() {
    if (agentRunning) return
    startSpeech("Hello, I'm Sky.", true)
  }

  function ttsFile(index) {
    return runtimeDir + "/tts-" + speechToken + "-" + index + ".pcm"
  }

  function startSpeech(text, force) {
    stopSpeech()
    if (!config.speakReplies && force !== true) return
    var chunks = SkyModel.splitSpeech(SkyModel.speechText(text), 320)
    if (chunks.length === 0) return

    speechToken = String(Date.now()) + "-" + Math.random().toString(36).slice(2, 6)
    speechQueue = chunks
    speechReady = []
    speechFailed = []
    speechSynthIndex = 0
    speechPlayIndex = 0
    speechSynthBusy = false
    speechPlayBusy = false
    speechActive = true
    speechGeneration++
    agentState = "speaking"
    pumpSynth()
  }

  function stopSpeech() {
    var oldToken = speechToken
    speechActive = false
    speechGeneration++
    speechSynthBusy = false
    speechPlayBusy = false
    speechQueue = []
    speechReady = []
    speechFailed = []
    speechSynthIndex = 0
    speechPlayIndex = 0
    synthIndex = -1
    if (synthProc.running) synthProc.running = false
    if (playerProc.running) playerProc.running = false
    speechToken = ""
    if (oldToken !== "") cleanupSpeechFiles(oldToken)
    if (!agentRunning && (agentState === "speaking" || agentState === "idle")) agentState = "idle"
  }

  function pumpSynth() {
    if (!speechActive || speechSynthBusy || speechSynthIndex >= speechQueue.length) return
    var index = speechSynthIndex++
    var file = ttsFile(index)
    var text = speechQueue[index]
    synthIndex = index
    synthGeneration = speechGeneration
    synthJson = JSON.stringify({
      model: "kokoro",
      input: text,
      voice: String(config.voice || "af_sky"),
      response_format: "pcm",
      speed: Number(config.speed || 1.0)
    })
    speechSynthBusy = true
    synthProc.command = [
      "curl", "-sS", "--fail", "--connect-timeout", "5", "--max-time", "120",
      "-H", "Content-Type: application/json",
      "--data-binary", "@-", speechUrl, "-o", file
    ]
    synthProc.stdinEnabled = true
    synthProc.running = true
  }

  function handleSynthExited(code) {
    var generation = synthGeneration
    var index = synthIndex
    if (generation !== speechGeneration || !speechActive) return
    speechSynthBusy = false
    speechReady[index] = code === 0
    speechFailed[index] = code !== 0
    if (code !== 0) {
      var detail = SkyModel.filterStderr(String(synthStderr.text || ""))
      setNotice("Voice unavailable: " + (detail || "Kokoro synthesis failed."), true)
    }
    pumpPlay()
    pumpSynth()
  }

  function handleSynthError(message) {
    if (!speechActive || synthGeneration !== speechGeneration) return
    speechSynthBusy = false
    if (synthIndex >= 0) {
      speechReady[synthIndex] = false
      speechFailed[synthIndex] = true
    }
    setNotice("Voice unavailable: " + String(message || "could not start curl."), true)
    pumpPlay()
    pumpSynth()
  }

  function pumpPlay() {
    if (!speechActive || speechPlayBusy) return
    var index = speechPlayIndex
    while (index < speechQueue.length && speechFailed[index]) index++
    if (index >= speechQueue.length) {
      if (!speechSynthBusy && speechSynthIndex >= speechQueue.length) finishSpeech()
      return
    }
    if (!speechReady[index]) return
    speechPlayIndex = index
    playGeneration = speechGeneration
    speechPlayBusy = true
    playerProc.command = [
      "ffplay", "-nodisp", "-autoexit", "-loglevel", "error",
      "-f", "s16le", "-ar", "24000", "-ch_layout", "mono", ttsFile(index)
    ]
    playerProc.running = true
  }

  function handlePlayerExited(code) {
    if (playGeneration !== speechGeneration || !speechActive) return
    speechPlayBusy = false
    speechPlayIndex++
    if (code !== 0) setNotice("Audio playback failed.", true)
    pumpPlay()
    if (!speechSynthBusy && speechSynthIndex >= speechQueue.length && speechPlayIndex >= speechQueue.length) {
      finishSpeech()
    }
  }

  function handlePlayerError(message) {
    if (!speechActive || playGeneration !== speechGeneration) return
    speechPlayBusy = false
    speechPlayIndex++
    setNotice("Audio playback failed: " + String(message || "could not start ffplay."), true)
    pumpPlay()
  }

  function finishSpeech() {
    if (!speechActive) return
    var token = speechToken
    speechActive = false
    speechGeneration++
    speechQueue = []
    speechReady = []
    speechFailed = []
    speechSynthIndex = 0
    speechPlayIndex = 0
    speechToken = ""
    if (token !== "") cleanupSpeechFiles(token)
    if (!agentRunning) agentState = "idle"
  }

  function cleanupSpeechFiles(token) {
    if (!token) return
    speechCleanupProc.command = [
      "bash", "-c",
      "for f in \"$1\"/tts-\"$2\"-*; do [ -e \"$f\" ] && rm -f -- \"$f\"; done 2>/dev/null || true",
      "bash", runtimeDir, String(token)
    ]
    speechCleanupProc.running = true
  }



  // ---- State ---------------------------------------------------------------

  ListModel { id: messagesModel }

  Timer {
    id: noticeTimer
    interval: 6000
    onTriggered: root.notice = ""
  }

  Timer {
    id: stateResetTimer
    interval: 6000
    onTriggered: {
      if (!root.busy && root.agentState === "error") root.agentState = "idle"
    }
  }

  Timer {
    id: saveConfigDebounce
    interval: 300
    onTriggered: root.saveConfigNow()
  }

  FileView {
    id: skyConfigView
    path: root.configFile
    watchChanges: false
    printErrors: false
    onLoaded: root.applySkyConfigText(String(text() || ""))
    onLoadFailed: root.applySkyConfigText("")
  }

  FileView {
    id: basicConfigView
    path: root.basicConfigFile
    watchChanges: false
    printErrors: false
    onLoaded: root.applyBasicConfigText(String(text() || ""))
    onLoadFailed: root.applyBasicConfigText("")
  }

  Process {
    id: setupDirsProc
    command: ["bash", "-c", "install -d -m 700 -- \"$1\" \"$2\"", "bash", root.configDir, root.runtimeDir]
  }

  Process {
    id: cleanupProc
    command: [
      "bash", "-c",
      "find \"$1\" -maxdepth 1 -type f \\( -name 'tts-*' -o -name 'voice-*' \\) -mmin +60 -delete 2>/dev/null || true",
      "bash", root.runtimeDir
    ]
  }

  Process {
    id: sessionReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySessionText(String(text || ""))
    }
    onExited: function(code) { root.sessionLoading = false }
  }

  Process {
    id: configWriteProc
    stdinEnabled: true
    onStarted: {
      configWriteProc.write(root.pendingConfig)
      configWriteProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) root.setNotice("Could not save SkyAgent settings.", true)
      if (root.configDirty) {
        root.configDirty = false
        root.saveConfigNow()
      }
    }
  }

  Process {
    id: restorePointerProc
    command: ["bash", "-c", SkyModel.restorePointerScript(), "bash", root.lastSessionPointer, root.lastSessionSaved]
  }

  Process {
    id: voicesProc
    stdout: StdioCollector {
      id: voicesStdout
      waitForEnd: true
    }
    onExited: function(code) {
      root.applyVoices(code, String(voicesStdout.text || ""))
    }
  }

  Process {
    id: voiceStartProc
    onExited: function(code) { root.handleVoiceStartExited(code) }
  }

  Process {
    id: voiceStopProc
    stdout: StdioCollector {
      id: voiceStopStdout
      waitForEnd: true
    }
    onExited: function(code) {
      root.handleVoiceStop(code, String(voiceStopStdout.text || ""))
    }
  }

  Process {
    id: voiceCancelProc
    command: ["voxtype", "record", "cancel"]
  }

  Process {
    id: voiceCleanupProc
  }

  Process {
    id: agentProc
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.handleAgentLine(line) }
    }
    stderr: StdioCollector {
      id: agentStderr
      waitForEnd: true
    }
    onStarted: {
      agentProc.write(root.pendingQuestion)
      agentProc.stdinEnabled = false
    }
    onExited: function(code) { root.handleAgentFinished(code) }
  }

  Process {
    id: synthProc
    stdinEnabled: true
    stderr: StdioCollector {
      id: synthStderr
      waitForEnd: true
    }
    onStarted: {
      synthProc.write(root.synthJson)
      synthProc.stdinEnabled = false
    }
    onExited: function(code) { root.handleSynthExited(code) }
  }

  Process {
    id: playerProc
    onExited: function(code) { root.handlePlayerExited(code) }
  }

  Process {
    id: speechCleanupProc
  }

  // ---- Window --------------------------------------------------------------

  KeyboardPanel {
    id: window
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.hostWidget
    open: root.opened
    centerOnBar: true
    focusTarget: inputField
    padding: Style.spacing.popupPadding
    contentWidth: window.fittedContentWidth(Style.space(780))
    contentHeight: window.fittedContentHeight(Style.space(640))
    borderSpec: root.borderSpec

    Item {
      id: content
      anchors.fill: parent

      Shortcut {
        sequence: "Escape"
        onActivated: root.handleEscape()
      }

      // Header -------------------------------------------------------------
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)

        Text {
          id: title
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "SkyAgent"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Rectangle {
          id: stateDot
          anchors.left: title.right
          anchors.leftMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6)
          height: Style.space(6)
          radius: width / 2
          color: root.stateColor
        }

        Text {
          id: stateText
          anchors.left: stateDot.right
          anchors.leftMargin: Style.spacing.xs
          anchors.verticalCenter: parent.verticalCenter
          text: root.stateLabel
          color: root.stateColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Button {
          id: actionsBadge
          visible: root.allowActions
          anchors.left: stateText.right
          anchors.leftMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: "Actions allowed"
          foreground: root.urgent
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.sm
          verticalPadding: 2
          focusable: false
          onClicked: {
            root.view = "settings"
            root.loadVoices()
          }
        }

        Button {
          id: closeButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Close"
          fontSize: Style.font.caption
          focusable: true
          onClicked: root.close()
        }

        Button {
          id: settingsButton
          anchors.right: closeButton.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: root.view === "settings" ? "Chat" : "Settings"
          fontSize: Style.font.caption
          focusable: true
          onClicked: root.toggleView()
        }

        Button {
          id: newButton
          visible: root.view === "chat"
          anchors.right: settingsButton.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: "New"
          fontSize: Style.font.caption
          focusable: true
          onClicked: root.newSession()
        }
      }

      PanelSeparator {
        id: headerSeparator
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
      }

      // Chat ---------------------------------------------------------------
      Item {
        id: chatView
        anchors.top: headerSeparator.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "chat"

        ListView {
          id: messageList
          anchors.top: parent.top
          anchors.topMargin: Style.spacing.md
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: statusBand.top
          anchors.bottomMargin: Style.spacing.sm
          clip: true
          spacing: Style.spacing.sm
          boundsBehavior: Flickable.StopAtBounds
          model: messagesModel
          delegate: messageDelegate
          property bool follow: true

          onMovementEnded: follow = atYEnd
          onCountChanged: if (follow) positionViewAtEnd()
          onContentHeightChanged: if (follow) positionViewAtEnd()
        }

        Text {
          visible: messagesModel.count === 0 && !root.sessionLoading
          anchors.centerIn: messageList
          width: Math.min(messageList.width - Style.space(40), Style.space(420))
          horizontalAlignment: Text.AlignHCenter
          text: "Hold F10 to talk\nor type a question below."
          color: Qt.darker(root.foreground, 1.35)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          lineHeight: 1.25
        }

        Rectangle {
          id: statusBand
          visible: root.statusLine !== ""
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: composerRow.top
          anchors.bottomMargin: Style.spacing.sm
          height: visible ? statusText.implicitHeight + Style.spacing.sm * 2 : 0
          radius: root.cornerRadius
          color: root.statusIsError
            ? Util.alpha(root.urgent, 0.16)
            : Style.hoverFillFor(root.foreground, root.accent)

          Text {
            id: statusText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.spacing.sm
            wrapMode: Text.WordWrap
            text: root.statusLine
            color: root.statusIsError ? root.urgent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          id: composerRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.spacing.controlHeight

          TextField {
            id: inputField
            anchors.left: parent.left
            anchors.right: micButton.left
            anchors.rightMargin: Style.spacing.sm
            height: parent.height
            enabled: !root.agentRunning && root.agentState !== "listening" && root.agentState !== "transcribing"
            placeholderText: root.agentRunning
              ? "Sky is working…"
              : (root.agentState === "listening" ? "Listening…" : "Ask Sky…")
            onAccepted: root.sendTyped()
          }

          Button {
            id: micButton
            anchors.right: sendButton.left
            anchors.rightMargin: Style.spacing.sm
            width: Style.space(74)
            height: parent.height
            text: root.agentState === "listening" ? "Stop" : "Mic"
            tooltipText: root.agentState === "listening" ? "Stop recording and ask" : "Hold F10 or click to talk"
            fontSize: Style.font.caption
            focusable: true
            enabled: root.agentState !== "transcribing"
            onClicked: {
              if (root.agentState === "listening") root.stopVoice()
              else root.startVoice()
            }
          }

          Button {
            id: sendButton
            anchors.right: speakButton.left
            anchors.rightMargin: Style.spacing.sm
            width: Style.space(72)
            height: parent.height
            text: (root.agentRunning || root.speechActive) ? "Stop" : "Send"
            tooltipText: text
            fontSize: Style.font.caption
            focusable: true
            enabled: root.agentRunning || root.speechActive || String(inputField.text || "").trim() !== ""
            onClicked: {
              if (root.agentRunning || root.speechActive) root.stopAll()
              else root.sendTyped()
            }
          }

          Button {
            id: speakButton
            anchors.right: parent.right
            width: Style.space(42)
            height: parent.height
            text: root.config.speakReplies ? "󰕾" : "󰖁"
            tooltipText: root.config.speakReplies ? "Spoken answers on" : "Spoken answers off"
            fontSize: Style.font.icon
            focusable: true
            onClicked: root.setSpeakReplies(!root.config.speakReplies)
          }
        }
      }

      // Settings -----------------------------------------------------------
      Item {
        id: settingsView
        anchors.top: headerSeparator.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "settings"

        Flickable {
          id: settingsFlick
          anchors.fill: parent
          anchors.topMargin: Style.spacing.md
          contentWidth: width
          contentHeight: settingsColumn.implicitHeight + Style.spacing.xxl
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: settingsColumn
            width: parent.width
            spacing: Style.spacing.panelGap

            PanelSectionHeader { text: "Voice"; foreground: root.foreground }

            Text {
              width: parent.width
              text: "Kokoro voice. The default is Sky."
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            SearchableDropdown {
              id: voiceDropdown
              width: parent.width
              label: "Voice"
              showLabel: false
              options: root.voices
              value: root.config.voice
              placeholderText: "Search voices…"
              foreground: root.foreground
              accent: root.accent
              popupBorder: root.borderColor
              onChanged: function(value) { root.setVoice(value) }
            }

            Text {
              visible: root.voicesError !== ""
              width: parent.width
              text: root.voicesError
              color: root.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Item {
              width: parent.width
              height: Style.spacing.controlHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Speed"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              PanelSlider {
                id: speedSlider
                bar: root.bar
                anchors.left: parent.left
                anchors.leftMargin: Style.space(56)
                anchors.right: speedValue.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                minimum: 0.5
                maximum: 2.0
                step: 0.05
                value: root.config.speed
                onMoved: function(value) { root.setSpeed(value) }
              }

              Text {
                id: speedValue
                anchors.right: previewButton.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(40)
                horizontalAlignment: Text.AlignRight
                text: Number(root.config.speed).toFixed(2) + "×"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Button {
                id: previewButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(72)
                height: Style.spacing.controlHeight
                text: "Preview"
                fontSize: Style.font.caption
                focusable: true
                enabled: !root.agentRunning
                onClicked: root.previewVoice()
              }
            }

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              height: Style.spacing.controlHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Speak replies"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.speakReplies
                foreground: root.foreground
                accent: root.accent
                onToggled: root.setSpeakReplies(!root.config.speakReplies)
              }
            }

            Item {
              width: parent.width
              height: Style.spacing.controlHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Open panel after voice"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.openPanelOnVoice
                foreground: root.foreground
                accent: root.accent
                onToggled: root.setOpenPanelOnVoice(!root.config.openPanelOnVoice)
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader { text: "Tool actions"; foreground: root.foreground }

            Text {
              width: parent.width
              text: "By default, basicagent denies shell commands and guarded writes in one-shot mode. Enabling this passes --yes for new questions. It applies to every guarded action in that run."
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Item {
              width: parent.width
              height: Style.spacing.controlHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Allow guarded actions (--yes)"
                color: root.allowActions ? root.urgent : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                id: actionsToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.allowGuardedActions || allowActionsConfirm.opened
                foreground: root.foreground
                accent: root.accent
                onToggled: {
                  if (root.config.allowGuardedActions) root.setAllowActions(false)
                  else allowActionsConfirm.opened = true
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader { text: "Conversation"; foreground: root.foreground }

            Text {
              width: parent.width
              text: "basicagent owns this conversation. Context is trimmed by basicagent at its configured context limit. Starting a new conversation creates a new basicagent session; older sessions remain available in basicagent-web."
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "Session: " + (root.sessionId || "—")
              color: Qt.darker(root.foreground, 1.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              width: Style.space(150)
              height: Style.spacing.controlHeight
              text: "New conversation"
              fontSize: Style.font.body
              focusable: true
              onClicked: root.newSession()
            }
          }
        }
      }

      ConfirmDialog {
        id: allowActionsConfirm
        anchors.fill: parent
        opened: false
        z: 100
        message: "Allow guarded actions?\n\nSkyAgent will pass --yes to basicagent. Shell commands and protected file writes will run without asking for the rest of this session. Only enable this if you trust the request."
        cancelText: "Cancel"
        confirmText: "Allow"
        background: root.background
        foreground: root.foreground
        scrim: Util.alpha(root.background, 0.72)
        selectedText: root.accent
        cornerRadius: root.cornerRadius
        onCanceled: {
          allowActionsConfirm.opened = false
        }
        onConfirmed: {
          allowActionsConfirm.opened = false
          root.setAllowActions(true)
        }
      }
    }
  }

  // ---- Message delegate ----------------------------------------------------

  Component {
    id: messageDelegate

    Item {
      id: wrap
      required property int index
      required property string role
      required property string content
      required property bool isError
      required property bool streaming

      readonly property bool isUser: role === "user"
      readonly property real pad: Style.spacing.xxl
      readonly property real maxBubbleWidth: messageList.width * 0.88
      readonly property real naturalWidth: messageText.implicitWidth + pad * 2

      width: messageList.width
      height: bubble.height + Style.spacing.xs

      Rectangle {
        id: bubble
        x: wrap.isUser ? wrap.width - width : 0
        width: Math.min(wrap.maxBubbleWidth, Math.max(Style.space(110), wrap.naturalWidth))
        height: messageText.height + wrap.pad * 2
        radius: root.cornerRadius
        color: wrap.isError
          ? Util.alpha(root.urgent, 0.18)
          : (wrap.isUser
            ? Style.selectedFillFor(root.foreground, root.accent)
            : Style.hoverFillFor(root.foreground, root.accent))

        TapHandler {
          acceptedButtons: Qt.LeftButton
          onDoubleTapped: messageText.selectAll()
        }

        TextEdit {
          id: messageText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: wrap.pad
          anchors.rightMargin: wrap.pad
          anchors.topMargin: wrap.pad
          text: wrap.content
          textFormat: TextEdit.PlainText
          wrapMode: TextEdit.Wrap
          readOnly: true
          selectByMouse: true
          activeFocusOnTab: false
          cursorVisible: false
          color: wrap.isError
            ? root.urgent
            : (wrap.isUser ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground)
          selectionColor: Style.selectionFillFor(root.foreground, root.accent)
          selectedTextColor: wrap.isUser ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  // ---- IPC -----------------------------------------------------------------

  IpcHandler {
    target: "skyagent"

    function ping(): string { return "ok" }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function settings(): void { root.view = "settings"; root.loadVoices() }
    function chat(): void { root.view = "chat" }
    function voiceStart(): string { root.startVoice(); return "ok" }
    function voiceStop(): string { root.stopVoice(); return "ok" }
    function ask(text: string): string {
      if (!root.opened) root.open()
      root.sendQuestion(String(text || ""))
      return "ok"
    }
    function clear(): string { root.newSession(); return "ok" }
    function stop(): string { root.stopAll(); return "ok" }
    function status(): string {
      return JSON.stringify({
        state: root.agentState,
        session: root.sessionId,
        recording: root.recordingStarted,
        agentRunning: root.agentRunning,
        speaking: root.speechActive,
        allowActions: root.allowActions
      })
    }
  }
}
