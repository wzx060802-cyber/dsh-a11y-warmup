import { spawn } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'a11y-warmup'
export const inject = []

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SCRIPT = path.join(HERE, 'warm.ps1')

function normalize(config) {
  const targets = Array.isArray(config?.targets) && config.targets.length
    ? config.targets.map((t) => String(t))
    : ['DeepSeek Harness']
  const intervalMs = Number(config?.intervalMs) > 0 ? Number(config.intervalMs) : 4000
  return { targets, intervalMs }
}

export function apply(ctx, config) {
  const { targets, intervalMs } = normalize(config)
  let child = null
  let stopped = false

  const stop = () => {
    stopped = true
    if (!child) return
    try { child.kill() } catch { /* already gone */ }
    child = null
  }

  const start = () => {
    if (stopped) return
    const startedAt = Date.now()
    try {
      child = spawn(
        'powershell.exe',
        [
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
          '-File', SCRIPT,
          '-Targets', targets.join(','),
          '-IntervalMs', String(intervalMs),
        ],
        { windowsHide: true, stdio: 'ignore', detached: false },
      )
      child.on('exit', () => {
        child = null
        if (stopped) return
        // A quick exit means another watcher already owns the single-instance
        // mutex: back off instead of respawning in a tight loop.
        const quick = Date.now() - startedAt < 5000
        setTimeout(start, quick ? 60000 : 3000).unref?.()
      })
      child.on('error', () => { child = null })
    } catch {
      child = null
    }
  }

  start()
  ctx.on('dispose', stop)
}

export default { name, inject, apply }
