import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import vm from 'node:vm'

const here = dirname(fileURLToPath(import.meta.url))
const raw = readFileSync(join(here, '..', 'SkyModel.js'), 'utf8')
const source = raw.replace(/^\.pragma library\s*/, '')
const context = { console, Date, Math, JSON, String, Number, Array, Object, RegExp }
vm.createContext(context)
vm.runInContext(source, context)

test('defaults are the intended Sky settings', () => {
  const d = context.defaults()
  assert.equal(d.voice, 'af_sky')
  assert.equal(d.speed, 1.0)
  assert.equal(d.speakReplies, true)
  assert.equal(d.openPanelOnVoice, true)
  assert.equal(d.allowGuardedActions, false)
  assert.equal(d.sessionId, '')
  assert.equal(d.kokoroBaseUrl, 'http://127.0.0.1:8880')
})

test('config merge clamps speed and rejects bad session ids', () => {
  const merged = context.mergeConfig({
    voice: 'am_michael',
    speed: 9,
    allowGuardedActions: true,
    sessionId: 'bad id!'
  })
  assert.equal(merged.voice, 'am_michael')
  assert.equal(merged.speed, 2.0)
  assert.equal(merged.allowGuardedActions, true)
  assert.equal(merged.sessionId, '')
})

test('session ids are valid basicagent session names', () => {
  const id = context.newSessionId(new Date('2026-10-18T21:30:00Z'))
  assert.match(id, /^skyagent-\d{8}-\d{6}-[a-z0-9]{3}$/)
  assert.equal(context.isValidSessionId(id), true)
  assert.equal(context.isValidSessionId('../bad'), false)
})

test('session JSONL parser ignores damaged lines', () => {
  const rows = context.parseSession([
    JSON.stringify({ role: 'user', content: 'hello' }),
    JSON.stringify({ role: 'assistant', content: 'hi' }),
    'not json',
    JSON.stringify({ role: 'tool', content: 'ignored' })
  ].join('\n'))
  assert.equal(JSON.stringify(rows.map((row) => [row.role, row.content])), JSON.stringify([
    ['user', 'hello'],
    ['assistant', 'hi']
  ]))
})

test('voxtype outcomes distinguish empty from text', () => {
  assert.equal(JSON.stringify(context.parseVoxtypeOutcome('{"status":"empty","text":""}')), JSON.stringify({
    ok: false, status: 'empty', text: '', message: ''
  }))
  assert.equal(JSON.stringify(context.parseVoxtypeOutcome('{"status":"ok","text":"  hello  "}')), JSON.stringify({
    ok: true, status: 'ok', text: 'hello', message: ''
  }))
  assert.equal(context.parseVoxtypeOutcome('not json').ok, false)
})

test('speech text strips markdown and code', () => {
  const spoken = context.speechText('## Hello **world**\n\n```js\nconst x = 1;\n```\nSee [here](https://example.com).')
  assert.match(spoken, /Hello world/)
  assert.match(spoken, /The code is in the panel/)
  assert.match(spoken, /See here/)
  assert.doesNotMatch(spoken, /\*\*|```|const x/)
})

test('speech splitting keeps sentences and respects the limit', () => {
  const chunks = context.splitSpeech('One. Two! Three? ' + 'word '.repeat(100), 40)
  assert.ok(chunks.length > 4)
  assert.equal(chunks[0], 'One.')
  assert.equal(chunks[1], 'Two!')
  for (const chunk of chunks) assert.ok(chunk.length <= 40, chunk)
})

test('voice options always include af_sky and sort sensibly', () => {
  const options = context.formatVoiceOptions(JSON.stringify({
    voices: [
      { id: 'am_michael', language: 'en-us', gender: 'male' },
      { id: 'af_sky', language: 'en-us', gender: 'female' }
    ]
  }))
  assert.equal(options[0].value, 'af_sky')
  assert.ok(options.some((option) => option.value === 'am_michael'))
  assert.match(options[0].label, /English \(US\)/)
})

test('Kokoro URLs accept base and /v1 base forms', () => {
  assert.equal(context.kokoroSpeechUrl('http://127.0.0.1:8880'), 'http://127.0.0.1:8880/v1/audio/speech')
  assert.equal(context.kokoroSpeechUrl('http://127.0.0.1:8880/v1/'), 'http://127.0.0.1:8880/v1/audio/speech')
  assert.equal(context.kokoroVoicesUrl('http://127.0.0.1:8880/v1'), 'http://127.0.0.1:8880/v1/audio/voices')
})

test('the basicagent wrapper execs the agent and saves the old pointer', () => {
  const script = context.basicagentWrapperScript()
  assert.match(script, /exec basicagent "\$@"/)
  assert.match(script, /@@NONE@@/)
  assert.match(script, /--session/)
  const restore = context.restorePointerScript()
  assert.match(restore, /pointer/)
  assert.match(restore, /@@NONE@@/)
})
