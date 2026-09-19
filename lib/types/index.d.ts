export declare const name = "dsh-win-computer-use";
export declare const inject: string[];
/** The slice of the cordis plugin context this plugin uses. */
interface Ctx {
    tools: {
        register: (definition: unknown) => () => void;
    };
    effect: (effect: () => unknown, label?: string) => void;
}
/** Plugin configuration as it may arrive from the loader. */
export interface Config {
    /** PowerShell executable. Default `powershell.exe` (5.1) — it has UIAutomation and System.Drawing. */
    powershell?: string;
    /** Ceiling for a single engine request when a tool does not set its own. */
    timeoutMs?: number;
    /** Idle milliseconds before the background engine retires itself. */
    idleMs?: number;
    /** Set false to disable the warm background engine (slower, but spawns nothing that outlives the call). */
    daemon?: boolean;
}
/** Register the two model-facing tools. */
export declare function apply(ctx: Ctx, userConfig?: Config): void;
export {};
