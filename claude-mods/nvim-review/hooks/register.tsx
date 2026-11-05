// Pulls the review comments queued in nvim (<leader>ac, lua/config/review_comments.lua
// in this repo) into this session's prompt box, as an unsent draft. Installed
// per project with :ClaudeModInstall; see docs/agent-review-comments.md.
//
// Pull, not push: the session that receives the batch is the one the person
// asked from, so it cannot land in another agent's session, and
// `$.prompt.fill` refuses while a dialog holds the keys instead of typing
// under it. nvim is reached over its own RPC socket with
// `nvim --server <socket> --remote-expr`; nothing is written to disk.
//
// Which nvim: the ones in this session's cmux workspace (both inherit
// CMUX_WORKSPACE_ID from their panes), or outside cmux the ones whose working
// directory shares this session's tree.
//
// Finding them is the background poll's job. The command and the band's
// button only re-ask the nvims already found, one quick call each, because a
// suspended nvim (ctrl+z) takes the connection and never answers: a full scan
// would wait out its timeout every time.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { NvimReviewSnapshot } from '../types'

type Engine = EngineInterface
type Scope = { cwd: string; workspace?: string }
type Remote = { out: string } | { failed: string } | undefined
type Verdict = { snap: NvimReviewSnapshot } | 'skip' | 'slow' | 'elsewhere'

const queued = atom({ plugin: 'nvim-review', key: 'queued' } as const, 0)

/** nvim names its server socket `nvim.<pid>.0` inside its run directory. */
const SOCKET = /^nvim\.\d+\.0$/
const MODULE = 'require("config.review_comments")'
const SNAPSHOT = `luaeval('${MODULE}.snapshot()')`
const ack = (ids: readonly number[]) => `luaeval('${MODULE}.ack(_A)', ${JSON.stringify(ids)})`

const POLL_MS = 3000
// A live nvim answers in ~25 ms; this is only the bound on one that never will.
const QUERY_TIMEOUT_MS = 1000
const SLOW_RETRY_MS = 30_000

// Module state starts over on every reload, which costs one rescan.
let scope: Scope | undefined
// Sockets that will never answer for this session: an nvim that exited, one
// without this config, one in another cmux workspace. A socket's path holds
// its pid, so a verdict stands for the module's life.
const skip = new Set<string>()
// The nvims found to be this session's, with what each answered last.
const peers = new Map<string, NvimReviewSnapshot>()
// Sockets that timed out, and when to try them again.
const slowUntil = new Map<string, number>()
let shown = -1
let refreshing: Promise<void> | undefined

function parse(out: string): NvimReviewSnapshot | undefined {
  try {
    const v = JSON.parse(out)
    if (typeof v?.count === 'number' && Array.isArray(v.ids) && typeof v.cwd === 'string') {
      return v as NvimReviewSnapshot
    }
  } catch {
    // Not JSON: an nvim answering for something else.
  }
  return undefined
}

function sameTree(a: string, b: string): boolean {
  return a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`)
}

function plural(n: number): string {
  return `${n} review comment${n === 1 ? '' : 's'}`
}

function total(): number {
  let n = 0
  for (const snap of peers.values()) n += snap.count
  return n
}

/** What goes before a batch inserted after `before`: a blank line, unless there is one. */
function lead(before: string): string {
  if (before.trim() === '' || before.endsWith('\n\n')) return ''
  return before.endsWith('\n') ? '\n' : '\n\n'
}

/** macOS: nvim's run directories are `$TMPDIR/nvim.$USER/<random>/`. */
async function sockets($: Engine): Promise<string[]> {
  const user = await $.env.get('USER')
  const tmp = await $.env.get('TMPDIR')
  if (!user || !tmp) return []
  const run = `${tmp.replace(/\/+$/, '')}/nvim.${user}`
  let dirs
  try {
    dirs = await $.fs.list(run)
  } catch {
    return []
  }
  const listed = await Promise.all(
    dirs
      .filter(d => d.kind === 'dir')
      .map(async d => {
        try {
          return (await $.fs.list(`${run}/${d.name}`))
            .filter(f => SOCKET.test(f.name))
            .map(f => `${run}/${d.name}/${f.name}`)
        } catch {
          return [] // gone between the two listings
        }
      }),
  )
  return listed.flat()
}

/** One expression on one nvim: its output, its failure, or undefined when it was too slow. */
async function remote($: Engine, socket: string, expr: string): Promise<Remote> {
  try {
    const r = await $.process.run(
      ['nvim', '--clean', '--headless', '--server', socket, '--remote-expr', expr],
      { timeoutMs: QUERY_TIMEOUT_MS },
    )
    return r.exitCode === 0 ? { out: r.stdout } : { failed: r.stderr }
  } catch {
    return undefined
  }
}

async function probe($: Engine, socket: string): Promise<Verdict> {
  const r = await remote($, socket, SNAPSHOT)
  if (r === undefined) return 'slow'
  // A dead socket exits 2 (E247), as does an nvim without this module (a Lua
  // error); one answering anything but a snapshot is not this config's either.
  const snap = 'out' in r ? parse(r.out) : undefined
  if (!snap || !scope) return 'skip'
  if (scope.workspace) return snap.workspace === scope.workspace ? { snap } : 'skip'
  // Outside cmux an nvim may :cd into this tree later, so no lasting verdict.
  return sameTree(snap.cwd, scope.cwd) ? { snap } : 'elsewhere'
}

/** Ask one socket and record what it is. */
async function judge($: Engine, socket: string): Promise<void> {
  const verdict = await probe($, socket)
  peers.delete(socket)
  if (verdict === 'skip') skip.add(socket)
  else if (verdict === 'slow') slowUntil.set(socket, (await $.clock.now()) + SLOW_RETRY_MS)
  else if (verdict !== 'elsewhere') peers.set(socket, verdict.snap)
}

async function show($: Engine): Promise<void> {
  const count = total()
  if (count === shown) return
  shown = count
  await update($, queued, () => count)
}

/** Re-ask the nvims already found: one quick call each. */
async function recheck($: Engine): Promise<void> {
  await Promise.all([...peers.keys()].map(s => judge($, s)))
  await show($)
}

/** Ask every socket not judged yet, leaving one that timed out alone for a while. */
async function discover($: Engine): Promise<void> {
  const now = await $.clock.now()
  const fresh = (await sockets($)).filter(
    s => !skip.has(s) && !peers.has(s) && (slowUntil.get(s) ?? 0) <= now,
  )
  await Promise.all(fresh.map(s => judge($, s)))
  await show($)
}

async function cycle($: Engine): Promise<void> {
  await recheck($)
  await discover($)
}

/** One poll at a time; a caller during one waits for it. */
function refresh($: Engine): Promise<void> {
  refreshing ??= cycle($).finally(() => {
    refreshing = undefined
  })
  return refreshing
}

/** Fill the prompt with every queued batch, then ack exactly what went in. */
async function insert($: Engine): Promise<string> {
  if (peers.size === 0) await refresh($)
  else await recheck($)
  const ready = [...peers].filter(([, snap]) => snap.count > 0 && snap.text)
  if (ready.length === 0) return 'No review comments queued in nvim.'

  const batch = ready.map(([, snap]) => snap.text).join('\n\n')
  const box = await $.prompt.read()
  const filled = await $.prompt.fill({ text: lead(box.text.slice(0, box.cursor)) + batch, mode: 'insert' })
  if (!filled.isFilled) {
    return filled.refusal === 'dialog'
      ? 'A dialog is open: the review comments stay queued in nvim.'
      : 'The prompt did not take the review comments: they stay queued in nvim.'
  }

  const sent = ready.reduce((n, [, snap]) => n + snap.count, 0)
  const acks = await Promise.all(ready.map(([socket, snap]) => remote($, socket, ack(snap.ids))))
  await recheck($)
  if (acks.some(r => r === undefined || 'failed' in r)) {
    return `Inserted ${plural(sent)}, but nvim did not confirm: they may still be queued there.`
  }
  return `Inserted ${plural(sent)} from nvim.`
}

async function insertAndSay($: Engine): Promise<void> {
  $.ui.toast(await insert($))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    scope = { cwd: e.cwd, workspace: await $.env.get('CMUX_WORKSPACE_ID') }
    await $.command.register({
      name: 'nvim-review',
      description: 'Insert the review comments queued in nvim into the prompt',
    })
    $.clock.every(POLL_MS, () => refresh($))
    void refresh($)
    return next(e)
  })

  on('command.run', { command: 'nvim-review' }, async $ => {
    await insertAndSay($)
    return {}
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const count = await read($, queued)
    if (count === 0 || e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    return (
      <Box>
        <Text dimColor>nvim: {plural(count)} queued </Text>
        <Button key="insert" label="Insert" onPress={() => insertAndSay($)} />
      </Box>
    )
  })
}
