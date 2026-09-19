#!/usr/bin/env node
/**
 * Pre-publish guard for dsh-win-computer-use.
 *
 * It exists because of one concrete near-miss: the engine lives in
 * `scripts/win.ps1` but the package's `files` list only carried `lib/`, so the
 * published tarball would have installed cleanly and then failed on the very
 * first tool call ("engine script is missing"). Nothing in the TypeScript build
 * catches that — the plugin's own path resolution is a runtime string join.
 *
 * So this checks the thing that actually ships: the packed file list.
 *
 * Wired to `prepublishOnly` (publish-time only, never on a consumer's machine)
 * and runnable by hand with `npm run preflight`.
 */
import { execSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const failures = []
const notes = []

function check(label, ok, detail = '') {
  const line = `${ok ? 'PASS' : 'FAIL'}  ${label}${detail === '' ? '' : ` -- ${detail}`}`
  if (ok) notes.push(line)
  else failures.push(line)
}

const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))

// 1. The engine script must be pure ASCII: Windows PowerShell 5.1 decodes a
//    BOM-less .ps1 as ANSI, so one non-ASCII byte can swallow line breaks and
//    the script fails at parse time on the user's machine.
const engine = join(root, 'scripts', 'win.ps1')
if (!existsSync(engine)) {
  check('engine script exists', false, engine)
} else {
  const bytes = readFileSync(engine)
  let bad = 0
  for (const byte of bytes) if (byte > 127) bad += 1
  check('scripts/win.ps1 is pure ASCII', bad === 0, bad === 0 ? `${bytes.length} bytes` : `${bad} non-ASCII byte(s)`)
}

// 2. A bundle manifest is what makes the package installable at all.
const patch = pkg.dsh?.bundle?.patch
check('package.json declares dsh.bundle.patch', typeof patch === 'string' && patch.length > 0, String(patch))
if (typeof patch === 'string') {
  const patchPath = join(root, patch)
  check('bundle patch file exists', existsSync(patchPath), patchPath)
  if (existsSync(patchPath)) {
    const text = readFileSync(patchPath, 'utf8')
    check('bundle patch names this package', text.includes(pkg.name), pkg.name)
  }
}

// 3. `private: true` makes `npm publish` refuse outright.
check('package is publishable (private is not true)', pkg.private !== true)

// 3b. No UTF-8 BOM. Windows PowerShell's `Set-Content -Encoding UTF8` writes one,
//     so any script that round-trips package.json through PowerShell plants it --
//     and the BOM ships inside the tarball, where stricter JSON readers choke.
const pkgBytes = readFileSync(join(root, 'package.json'))
check(
  'package.json has no UTF-8 BOM',
  !(pkgBytes[0] === 0xef && pkgBytes[1] === 0xbb && pkgBytes[2] === 0xbf),
  pkgBytes[0] === 0xef ? 'starts with EF BB BF' : 'clean',
)

// 4. Artifacts that the runtime path resolution depends on.
check('lib/index.js built', existsSync(join(root, 'lib', 'index.js')))
check('lib/bridge.js built', existsSync(join(root, 'lib', 'bridge.js')))

// 5. The real test: what does the tarball actually contain? Asking npm itself
//    avoids re-implementing its `files`/ignore semantics and catches the exact
//    class of bug this file was written for.
if (process.env.DSH_CU_PREFLIGHT_PACK === '1') {
  notes.push('SKIP  pack contents (recursion guard)')
} else {
  try {
    // A fixed command string through the shell: on Windows a `.cmd` shim cannot
    // be spawned directly, and passing an args array through a shell is what
    // Node deprecated (DEP0190). Nothing here comes from user input.
    const raw = execSync('npm pack --dry-run --json', {
      cwd: root,
      encoding: 'utf8',
      env: { ...process.env, DSH_CU_PREFLIGHT_PACK: '1' },
      stdio: ['ignore', 'pipe', 'ignore'],
    })
    // npm may prepend notices to the JSON report; take the outermost array.
    const start = raw.indexOf('[')
    const end = raw.lastIndexOf(']')
    if (start < 0 || end < start) throw new Error(`unexpected npm pack output: ${raw.slice(0, 200)}`)
    const files = (JSON.parse(raw.slice(start, end + 1))[0]?.files ?? []).map((entry) => entry.path)
    // npm normalizes the leading "./" out of packed paths, so compare the same way.
    const normalizedPatch = typeof patch === 'string' ? patch.replace(/^\.\//, '') : ''
    const required = ['package.json', 'lib/index.js', 'lib/bridge.js', 'scripts/win.ps1', normalizedPatch]
    for (const want of required) {
      if (typeof want !== 'string') continue
      check(`tarball contains ${want}`, files.includes(want))
    }
    notes.push(`INFO  tarball would ship ${files.length} files`)
  } catch (error) {
    check('npm pack --dry-run succeeded', false, error instanceof Error ? error.message.split('\n')[0] : String(error))
  }
}

for (const line of notes) console.log(line)
if (failures.length > 0) {
  console.error('')
  for (const line of failures) console.error(line)
  console.error(`\npreflight: ${failures.length} check(s) failed -- do not publish.`)
  process.exit(1)
}
console.log('\npreflight: OK')
