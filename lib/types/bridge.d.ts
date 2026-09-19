/** One engine reply. `ok` is the engine's verdict; transport errors throw instead. */
export interface EngineResult {
    ok: boolean;
    error?: string;
    [key: string]: unknown;
}
/** Everything the engine needs to know about its runtime environment. */
export interface EngineConfig {
    /** Absolute path of `scripts/win.ps1`. */
    script: string;
    /** PowerShell executable; Windows PowerShell 5.1 has UIAutomation and System.Drawing. */
    powershell: string;
    /** Default per-request ceiling when the caller does not supply one. */
    timeoutMs: number;
    /** Idle milliseconds after which the daemon shuts itself down. */
    idleMs: number;
    /** When false, every call spawns a fresh process. */
    daemon: boolean;
    /** Diagnostic sink; never throws. */
    log: (message: string) => void;
}
/** Owns the engine process and turns tool calls into engine requests. */
export declare class Engine {
    private readonly config;
    private readonly dir;
    private readonly portFile;
    private child;
    private port;
    private daemonPid;
    private starting;
    private stampCache;
    private acquiredVersion;
    constructor(config: EngineConfig);
    /** Run one engine action. Throws only when no transport could deliver it. */
    call(action: string, args: Record<string, unknown>, timeoutMs: number, signal?: AbortSignal): Promise<EngineResult>;
    /** Stop a daemon we own. Deliberately not called on plugin unload: the daemon
     *  is meant to survive a hot reload so the next call is warm, and it retires
     *  itself after `idleMs` of silence. */
    shutdown(): Promise<void>;
    private forget;
    /** Kill the daemon we are talking to (wedged, or running stale engine bytes)
     *  so the next call can start a healthy one. */
    private killDaemon;
    private viaDaemon;
    private ensureDaemon;
    /** Cheap "has the engine file changed" token (mtime + size). */
    private scriptVersion;
    private startDaemon;
    private readPortFile;
    /**
     * Ask a daemon on `port` whether it is usable.
     * `stale` means it is alive but runs different engine bytes than the script on
     * disk -- it must be retired rather than reused, or an engine edit would never
     * take effect.
     */
    private probe;
    /** SHA-256 of `scripts/win.ps1`, matching the engine's own `ping.stamp`.
     *  Content, not mtime: a timestamp comparison across two runtimes is one
     *  timezone conversion away from never matching. Memoized per file version so
     *  a long-lived client does not re-hash on every probe. */
    private scriptStamp;
    /** One request/response line over loopback TCP. Never uses piped stdio:
     *  the file sandbox denies pipes, and Chinese payloads survive TCP intact. */
    private roundTrip;
    /** Cold path: one process per call, arguments and result swapped via files. */
    private oneShot;
}
