/**
 * Transport and lifecycle for the PowerShell engine (`scripts/win.ps1`).
 *
 * Two transports, one engine, so nothing above this file has to care:
 *   - daemon: a long-lived `powershell.exe` listening on 127.0.0.1 that already
 *     paid the Add-Type / assembly-load cost once. Measured on this machine:
 *     ~800 ms per one-shot call versus ~40 ms per daemon call, and a whole
 *     multi-step batch fits in one round trip.
 *   - one-shot: fallback when no daemon can be started (sandbox refuses the
 *     spawn, the script is missing, the daemon is wedged). Same dispatch table
 *     on the engine side, so a batch still runs as a batch -- just slower.
 *
 * A hung engine is worse than a slow one: the daemon is single-threaded, so one
 * stuck UIA call would block every later request. On a read timeout we kill the
 * daemon by pid (reported by `ping`) and let the next call start a fresh one.
 * We never auto-retry a request that was already written -- the engine may have
 * performed half of it, and re-running a click is not idempotent.
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { connect } from 'node:net'
import { createHash, randomUUID } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/** One engine reply. `ok` is the engine's verdict; transport errors throw instead. */
export interface EngineResult {
  ok: boolean
  error?: string
  [key: string]: unknown
}

/** Everything the engine needs to know about its runtime environment. */
export interface EngineConfig {
  /** Absolute path of `scripts/win.ps1`. */
  script: string
  /** PowerShell executable; Windows PowerShell 5.1 has UIAutomation and System.Drawing. */
  powershell: string
  /** Default per-request ceiling when the caller does not supply one. */
  timeoutMs: number
  /** Idle milliseconds after which the daemon shuts itself down. */
  idleMs: number
  /** When false, every call spawns a fresh process. */
  daemon: boolean
  /** Diagnostic sink; never throws. */
  log: (message: string) => void
}

/** Transport-level failure. `phase` decides whether a retry is safe. */
class TransportFailure extends Error {
  constructor(
    message: string,
    readonly phase: 'connect' | 'io',
  ) {
    super(message)
    this.name = 'TransportFailure'
  }
}

interface Pending {
  resolve: (value: EngineResult) => void
  reject: (error: Error) => void
  timer: NodeJS.Timeout
  cleanup: () => void
}

/** Owns the engine process and turns tool calls into engine requests. */
export class Engine {
  private readonly dir: string
  private readonly portFile: string
  private child: ChildProcess | null = null
  private port = 0
  private daemonPid = 0
  private starting: Promise<number> | null = null
  private stampCache: { version: string; hash: string } | null = null
  private acquiredVersion = ''

  constructor(private readonly config: EngineConfig) {
    this.dir = join(tmpdir(), 'dsh-computer-use')
    mkdirSync(this.dir, { recursive: true })
    this.portFile = join(this.dir, 'daemon-port.txt')
  }

  /** Run one engine action. Throws only when no transport could deliver it. */
  async call(
    action: string,
    args: Record<string, unknown>,
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<EngineResult> {
    if (process.platform !== 'win32') throw new Error('dsh-computer-use only supports Windows')
    if (!existsSync(this.config.script)) throw new Error(`engine script is missing: ${this.config.script}`)
    const payload = { action, ...args }
    if (this.config.daemon) {
      try {
        return await this.viaDaemon(payload, timeoutMs, signal)
      } catch (error) {
        const failure = error as TransportFailure
        this.config.log(`daemon transport failed (${failure.phase ?? 'unknown'}): ${failure.message}; falling back to a one-shot engine call`)
      }
    }
    return this.oneShot(payload, timeoutMs, signal)
  }

  /** Stop a daemon we own. Deliberately not called on plugin unload: the daemon
   *  is meant to survive a hot reload so the next call is warm, and it retires
   *  itself after `idleMs` of silence. */
  async shutdown(): Promise<void> {
    if (this.port > 0) {
      try {
        await this.roundTrip(this.port, { action: 'shutdown' }, 3000)
      } catch {
        /* the daemon may already be gone */
      }
    }
    this.forget()
  }

  private forget(): void {
    this.port = 0
    this.daemonPid = 0
    this.child = null
    this.starting = null
  }

  /** Kill the daemon we are talking to (wedged, or running stale engine bytes)
   *  so the next call can start a healthy one. */
  private killDaemon(): void {
    const pid = this.daemonPid
    if (pid > 0) {
      try {
        process.kill(pid)
      } catch {
        /* already gone */
      }
    }
    try {
      this.child?.kill()
    } catch {
      /* already gone */
    }
    this.forget()
  }

  private async viaDaemon(
    payload: Record<string, unknown>,
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<EngineResult> {
    const port = await this.ensureDaemon()
    try {
      return await this.roundTrip(port, payload, timeoutMs, signal)
    } catch (error) {
      const failure = error as TransportFailure
      // Only a connection that never got established is safe to retry: at that
      // point the engine has done nothing yet.
      if (failure.phase === 'connect') {
        this.forget()
        const retryPort = await this.ensureDaemon()
        return await this.roundTrip(retryPort, payload, timeoutMs, signal)
      }
      this.killDaemon()
      throw failure
    }
  }

  private async ensureDaemon(): Promise<number> {
    // A stat() is far cheaper than a ping, so the cheap check runs every call
    // and the real probe only when the engine file actually changed under us.
    if (this.port > 0 && this.acquiredVersion === this.scriptVersion()) return this.port
    if (this.starting !== null) return this.starting
    this.starting = this.startDaemon()
    try {
      this.port = await this.starting
      this.acquiredVersion = this.scriptVersion()
      return this.port
    } finally {
      this.starting = null
    }
  }

  /** Cheap "has the engine file changed" token (mtime + size). */
  private scriptVersion(): string {
    try {
      const info = statSync(this.config.script)
      return `${Math.floor(info.mtimeMs)}-${info.size}`
    } catch {
      return ''
    }
  }

  private async startDaemon(): Promise<number> {
    // Reuse a daemon left behind by an earlier plugin generation (hot reloads
    // are frequent; re-paying the ~600 ms start every time is exactly the cost
    // this file exists to remove).
    const existing = this.readPortFile()
    let avoidPort = 0
    if (existing > 0) {
      const verdict = await this.probe(existing)
      if (verdict === 'ok') {
        this.port = existing
        this.config.log(`reusing warm engine daemon on port ${existing}`)
        return existing
      }
      // A stale daemon still holds its port and would answer every later probe
      // with the same outdated stamp -- without killing it here, the poll loop
      // below would spin on it until the deadline and then give up entirely.
      if (verdict === 'stale') {
        this.killDaemon()
        avoidPort = existing
      }
    }
    rmSync(this.portFile, { force: true })
    const child = spawn(
      this.config.powershell,
      [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', this.config.script,
        '-Action', 'serve',
        '-PortFile', this.portFile,
        '-IdleMs', String(this.config.idleMs),
      ],
      { stdio: 'ignore', windowsHide: true },
    )
    child.unref()
    this.child = child
    child.on('error', () => { this.forget() })
    child.on('exit', () => { if (this.child === child) this.forget() })

    const deadline = Date.now() + 20000
    while (Date.now() < deadline) {
      await delay(50)
      const port = this.readPortFile()
      if (port <= 0 || port === avoidPort) continue
      if ((await this.probe(port)) === 'ok') return port
    }
    try {
      child.kill()
    } catch {
      /* already gone */
    }
    this.forget()
    throw new TransportFailure('the engine daemon did not come up within 20s', 'connect')
  }

  private readPortFile(): number {
    try {
      if (!existsSync(this.portFile)) return 0
      const raw = readFileSync(this.portFile, 'utf8').trim()
      const port = Number(raw)
      return Number.isInteger(port) && port > 0 && port < 65536 ? port : 0
    } catch {
      return 0
    }
  }

  /**
   * Ask a daemon on `port` whether it is usable.
   * `stale` means it is alive but runs different engine bytes than the script on
   * disk -- it must be retired rather than reused, or an engine edit would never
   * take effect.
   */
  private async probe(port: number): Promise<'ok' | 'stale' | 'dead'> {
    try {
      const reply = await this.roundTrip(port, { action: 'ping' }, 4000)
      if (typeof reply.pid === 'number') this.daemonPid = reply.pid
      if (reply.ok !== true) return 'dead'
      const remote = typeof reply.stamp === 'string' ? reply.stamp : ''
      const local = this.scriptStamp()
      // An old daemon from before fingerprinting reports no stamp: trust it
      // rather than looping, the next restart will carry the stamp.
      if (remote !== '' && local !== '' && remote !== local) {
        this.config.log(`engine script changed on disk (daemon ${remote.slice(0, 12)}, file ${local.slice(0, 12)}); retiring the stale daemon`)
        return 'stale'
      }
      return 'ok'
    } catch {
      return 'dead'
    }
  }

  /** SHA-256 of `scripts/win.ps1`, matching the engine's own `ping.stamp`.
   *  Content, not mtime: a timestamp comparison across two runtimes is one
   *  timezone conversion away from never matching. Memoized per file version so
   *  a long-lived client does not re-hash on every probe. */
  private scriptStamp(): string {
    try {
      const info = statSync(this.config.script)
      const version = `${Math.floor(info.mtimeMs)}-${info.size}`
      if (this.stampCache?.version === version) return this.stampCache.hash
      const hash = createHash('sha256').update(readFileSync(this.config.script)).digest('hex')
      this.stampCache = { version, hash }
      return hash
    } catch {
      return ''
    }
  }

  /** One request/response line over loopback TCP. Never uses piped stdio:
   *  the file sandbox denies pipes, and Chinese payloads survive TCP intact. */
  private roundTrip(
    port: number,
    payload: Record<string, unknown>,
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<EngineResult> {
    return new Promise<EngineResult>((resolve, reject) => {
      let buffer = ''
      let settled = false
      const socket = connect(port, '127.0.0.1')
      const pending: Pending = {
        resolve,
        reject,
        timer: setTimeout(() => {
          finish(() => reject(new TransportFailure(`engine request timed out after ${timeoutMs}ms`, 'io')))
        }, timeoutMs),
        cleanup: () => { socket.destroy() },
      }
      const finish = (fn: () => void): void => {
        if (settled) return
        settled = true
        clearTimeout(pending.timer)
        signal?.removeEventListener('abort', onAbort)
        pending.cleanup()
        fn()
      }
      const onAbort = (): void => finish(() => reject(new TransportFailure('cancelled', 'io')))
      signal?.addEventListener('abort', onAbort, { once: true })
      socket.setEncoding('utf8')
      socket.on('connect', () => {
        socket.write(`${JSON.stringify(payload)}\n`, (error) => {
          if (error) finish(() => reject(new TransportFailure(`engine write failed: ${error.message}`, 'io')))
        })
      })
      socket.on('data', (chunk: string) => {
        buffer += chunk
        const end = buffer.indexOf('\n')
        if (end < 0) return
        const line = buffer.slice(0, end)
        finish(() => {
          try {
            resolve(JSON.parse(line) as EngineResult)
          } catch (error) {
            reject(new TransportFailure(`engine returned unparsable JSON: ${(error as Error).message}`, 'io'))
          }
        })
      })
      socket.on('error', (error: Error) => {
        const established = !socket.connecting
        finish(() => reject(new TransportFailure(`engine socket error: ${error.message}`, established ? 'io' : 'connect')))
      })
      socket.on('close', () => {
        finish(() => reject(new TransportFailure('engine closed the connection before replying', 'io')))
      })
    })
  }

  /** Cold path: one process per call, arguments and result swapped via files. */
  private async oneShot(
    payload: Record<string, unknown>,
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<EngineResult> {
    const inFile = join(this.dir, `in-${randomUUID()}.json`)
    const outFile = join(this.dir, `out-${randomUUID()}.json`)
    writeFileSync(inFile, JSON.stringify(payload), 'utf8')
    try {
      await new Promise<void>((resolvePromise, rejectPromise) => {
        const child = spawn(
          this.config.powershell,
          [
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', this.config.script,
            '-ArgsJsonFile', inFile,
            '-OutFile', outFile,
          ],
          { stdio: 'ignore', windowsHide: true },
        )
        let settled = false
        const finish = (fn: () => void): void => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          signal?.removeEventListener('abort', onAbort)
          fn()
        }
        const timer = setTimeout(() => {
          try { child.kill() } catch { /* already exited */ }
          finish(() => rejectPromise(new Error(`engine call timed out after ${timeoutMs}ms`)))
        }, timeoutMs)
        const onAbort = (): void => {
          try { child.kill() } catch { /* already exited */ }
          finish(() => rejectPromise(new Error('cancelled')))
        }
        signal?.addEventListener('abort', onAbort, { once: true })
        child.on('error', (error) => finish(() => rejectPromise(error)))
        child.on('exit', (code) => {
          finish(() => {
            if (!existsSync(outFile)) {
              rejectPromise(new Error(`engine produced no result (exit ${String(code)})`))
              return
            }
            resolvePromise()
          })
        })
      })
      return JSON.parse(readFileSync(outFile, 'utf8')) as EngineResult
    } finally {
      rmSync(inFile, { force: true })
      rmSync(outFile, { force: true })
    }
  }
}

/** Small sleep helper (no timers module needed). */
function delay(ms: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms))
}
