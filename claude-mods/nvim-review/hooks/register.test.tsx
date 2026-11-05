import type { On, PromptFillResult } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const WS = 'ws-1'
const RUN = '/T/nvim.me'
const MINE = `${RUN}/aaa/nvim.100.0`
const ELSEWHERE = `${RUN}/bbb/nvim.200.0`
const DEAD = `${RUN}/ccc/nvim.300.0`

const PAYLOAD = 'Review comments (2):\n\n1. @a.lua#L3\n   needs a guard'

const BAND = {
  plugin: 'nvim-review',
  component: 'AbovePrompt',
  requestId: 'band',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 9 },
    view: {},
  },
} as const

type Nvim = { workspace?: string; cwd: string; ids: number[]; text?: string }

const ran = (stdout: string, exitCode = 0, stderr = '') => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
})

const entry = (name: string, kind: 'dir' | 'other') => ({
  name,
  kind,
  size: 0,
  mtimeMs: 0,
  isLink: false,
})

/**
 * The world beneath the mod: nvims listening under nvim's run directory, each
 * answering `snapshot()` and `ack()` over `--remote-expr` as the Lua side does,
 * and a prompt box that takes or refuses a fill.
 */
function world(
  on: On,
  nvims: Record<string, Nvim | 'dead' | 'hung'>,
  {
    fill = { isFilled: true },
    env = { TMPDIR: '/T/', USER: 'me', CMUX_WORKSPACE_ID: WS },
    draft = { text: '', cursor: 0 },
  }: {
    fill?: PromptFillResult
    env?: Record<string, string>
    draft?: { text: string; cursor: number }
  } = {},
) {
  mock.env(on, env)
  const clock = mock.clock(on)

  // RUN/<dir>/nvim.<pid>.0: the directory and the socket's name.
  const part = (socket: string, i: 3 | 4) => socket.split('/')[i] ?? ''
  on('fs.list', (_, e) => {
    if (e.path === RUN) {
      return { value: Object.keys(nvims).map(s => entry(part(s, 3), 'dir')) }
    }
    const sockets = Object.keys(nvims).filter(s => s.startsWith(`${e.path}/`))
    return { value: sockets.map(s => entry(part(s, 4), 'other')) }
  })

  const acks: { socket: string; ids: number[] }[] = []
  const asked: Record<string, number> = {}
  on('process.run', (_, e) => {
    const socket = e.argv[e.argv.indexOf('--server') + 1] ?? ''
    const expr = e.argv[e.argv.indexOf('--remote-expr') + 1] ?? ''
    asked[socket] = (asked[socket] ?? 0) + 1
    const nvim = nvims[socket]
    // A suspended nvim takes the connection and never answers: the engine
    // kills the client at its timeout and the call rejects.
    if (nvim === 'hung') throw new Error('timed out')
    if (nvim === undefined || nvim === 'dead') {
      return ran('', 1, `E247: Failed to connect to '${socket}': connection refused.`)
    }
    if (expr.includes('.snapshot()')) {
      const { ids, text, cwd, workspace } = nvim
      return ran(JSON.stringify({ count: ids.length, ids, text, cwd, workspace }))
    }
    const acked = /\.ack\(_A\)', (\[.*\])\)$/.exec(expr)
    if (acked?.[1]) {
      const ids: number[] = JSON.parse(acked[1])
      acks.push({ socket, ids })
      nvim.ids = nvim.ids.filter(id => !ids.includes(id))
      if (nvim.ids.length === 0) nvim.text = undefined
      return ran(String(ids.length))
    }
    return ran('', 2, `unexpected expression ${expr}`)
  })

  const fills: string[] = []
  on('prompt.read', () => ({ value: draft }))
  on('prompt.fill', (_, e) => {
    fills.push(e.text)
    return fill
  })

  const toasts: string[] = []
  on('ui.toast', (_, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })

  on('command.register', () => ({ value: { command: 'nvim-review' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  return { clock, acks, asked, fills, toasts }
}

/** `/nvim-review` as typed at the prompt. */
const TYPED = {
  command: 'nvim-review',
  args: '',
  origin: { kind: 'composer' },
  presentation: { isFullscreen: false, columns: 120 },
} as const

const mineAndOthers = (): Record<string, Nvim | 'dead' | 'hung'> => ({
  [MINE]: { workspace: WS, cwd: '/repo', ids: [1, 2], text: PAYLOAD },
  [ELSEWHERE]: { workspace: 'ws-2', cwd: '/repo', ids: [7], text: 'another workspace' },
  [DEAD]: 'dead',
})

test('the command inserts the batch of this workspace’s nvim and acks it', async ($, on) => {
  const w = world(on, mineAndOthers())
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  await $.command.run(TYPED)

  expect(w.fills).toEqual([PAYLOAD])
  expect(w.acks).toEqual([{ socket: MINE, ids: [1, 2] }])
})

test('a refused fill leaves the comments queued in nvim', async ($, on) => {
  const w = world(on, mineAndOthers(), { fill: { isFilled: false, refusal: 'dialog' } })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  await $.command.run(TYPED)

  // The site strips a refusal cause a test hook writes itself, so the dialog
  // wording is not reachable here; what matters is that nothing was acked.
  expect(w.acks).toEqual([])
  expect(w.toasts.join('\n')).toMatch(/stay queued in nvim/)
})

test('with nothing queued the prompt is left alone', async ($, on) => {
  const w = world(on, { [MINE]: { workspace: WS, cwd: '/repo', ids: [] } })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  await $.command.run(TYPED)

  expect(w.fills).toEqual([])
  expect(w.toasts.join('\n')).toMatch(/No review comments/)
})

test('outside cmux an nvim is matched by its working tree', async ($, on) => {
  const w = world(
    on,
    {
      [MINE]: { cwd: '/repo', ids: [4], text: 'same tree' },
      [ELSEWHERE]: { cwd: '/other', ids: [5], text: 'other tree' },
    },
    { env: { TMPDIR: '/T/', USER: 'me' } },
  )
  await $.session.start({ cwd: '/repo/lua', surface: 'terminal', isInteractive: true })

  await $.command.run(TYPED)

  expect(w.fills).toEqual(['same tree'])
})

// Found live: an nvim suspended with ctrl+z accepts the connection and never
// replies, so every scan waited out the timeout on it.
test('an nvim that does not answer is not asked again by the command', async ($, on) => {
  const HUNG = `${RUN}/ddd/nvim.400.0`
  const w = world(on, { ...mineAndOthers(), [HUNG]: 'hung' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await w.clock.advance(3000)

  await $.command.run(TYPED)

  expect(w.fills).toEqual([PAYLOAD])
  expect(w.asked[HUNG]).toBe(1)
})

// Found live: the band's Insert glued the batch onto the end of the draft.
test('a batch inserted after a draft is set off by a blank line', async ($, on) => {
  const w = world(on, mineAndOthers(), { draft: { text: 'fix these', cursor: 9 } })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  await $.command.run(TYPED)

  expect(w.fills).toEqual([`\n\n${PAYLOAD}`])
})

test('the band counts what is queued and inserts it on a press', async ($, on) => {
  const w = world(on, mineAndOthers())
  // Stands for the engine's own band, which the mod passes to when empty.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await w.clock.advance(3000)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    expect((await ui.find({ type: 'Text', text: /2 review comments/ }))?.text).toMatch(/nvim/)
    await ui.unmount()
  }

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await ui.press({ key: 'insert' })
  expect(w.fills).toEqual([PAYLOAD])
  expect(w.acks).toEqual([{ socket: MINE, ids: [1, 2] }])
  expect(await ui.find({ type: 'Text', text: /review comment/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /engine band/ })).toBeDefined()
  await ui.unmount()
})
