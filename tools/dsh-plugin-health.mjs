#!/usr/bin/env node
/**
 * dsh-plugin-health.mjs -- offline compatibility check for a DSH profile.
 *
 * Why this exists: after a DSH update a community plugin can stop being
 * supported (its peer range no longer matches the new DSH, its client half
 * asks for a package this DSH does not ship, its bundle patch disappeared).
 * DSH then boots with a dead plugin and the reason scrolls by in the console.
 * This script looks for exactly those cases BEFORE the server starts, prints
 * them in the console, and (with --remove) drops the offending plugin from the
 * profile so the next start composes cleanly.
 *
 * Removal is done by editing the profile manifest and deleting the plugin
 * folder - no pnpm run, no network, so it also works for a plugin that has been
 * unpublished or when the machine is offline.
 *
 * Exact-version exemptions count: when the profile's compatibility.json grants
 * "<name>@<version>" for the runtime in question, DSH loads that plugin despite
 * the mismatch, so this script reports it as an accepted risk instead of a
 * broken plugin - and --remove can never delete a plugin the user approved.
 *
 * It never starts, stops or restarts DSH.
 *
 * Usage:
 *   node dsh-plugin-health.mjs [--profile web] [--dsh <install dir>]
 *                              [--home <dsh home>] [--remove] [--json]
 *                              [--protect name,name]
 *                              [--against <dsh version>]
 *
 * --against asks a hypothetical question: "if this DSH became <version>, how
 * many of these plugins would it refuse to load?" DSH drops a plugin whose
 * @deepseek-ai/dsh-* peer ranges do not accept the runtime, and it only says so
 * in the console at start-up - so this is the check worth running BEFORE an
 * upgrade is installed. With --against nothing is ever removed.
 *
 * Exit codes: 0 = nothing wrong (or everything handled), 1 = internal error.
 */

import { createRequire } from 'node:module'
import { existsSync, readFileSync, statSync, writeFileSync, rmSync } from 'node:fs'
import { loadTranslator } from './i18n.mjs'

// Every line this script prints goes through the active language file.
const tr = loadTranslator()
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import os from 'node:os'

function parseArgs(argv) {
  const out = { profile: 'web', dsh: null, home: null, remove: false, json: false, protect: ['dshmarket'], against: null }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--profile') out.profile = argv[++i]
    else if (a === '--dsh') out.dsh = argv[++i]
    else if (a === '--home') out.home = argv[++i]
    else if (a === '--against') out.against = argv[++i]
    else if (a === '--protect') out.protect = String(argv[++i] ?? '').split(',').filter(Boolean)
    else if (a === '--remove' || a === '--auto-remove') out.remove = true
    else if (a === '--json') out.json = true
  }
  return out
}

const args = parseArgs(process.argv.slice(2))
const log = []
const say = (line) => { const out = tr(line); log.push(out); if (!args.json) console.log(out) }

function dshHome() {
  if (args.home) return args.home
  if (process.env.DSH_HOME) return process.env.DSH_HOME
  return path.join(os.homedir(), '.dsh')
}

function readJson(file) {
  try { return JSON.parse(readFileSync(file, 'utf8')) } catch { return null }
}

function dirOf(file) {
  try { return statSync(file).isDirectory() ? file : path.dirname(file) } catch { return null }
}

// ---------------------------------------------------------------- profiles
const home = dshHome()
const profileDir = path.join(home, 'profiles', args.profile)
if (!existsSync(path.join(profileDir, 'package.json'))) {
  say(`[health] no profile at ${profileDir} - nothing to check`)
  process.exit(0)
}

const manifest = readJson(path.join(profileDir, 'package.json')) ?? {}
const dependencies = manifest.dependencies ?? {}
const bundles = manifest.dsh?.profile?.bundles ?? []
// Only plugins this profile declares itself; the shipped @deepseek-ai bundles
// are the ruler, not the measured.
const userPlugins = bundles.filter((n) => dependencies[n] !== undefined && !n.startsWith('@deepseek-ai/'))

// Where a package may live: the profile, the DSH install, the shared mirror.
const roots = [
  path.join(profileDir, 'node_modules'),
  args.dsh ? path.join(args.dsh, 'node_modules') : null,
  path.join(home, 'profiles', 'node_modules'),
].filter(Boolean)

function resolvePackage(name) {
  for (const root of roots) {
    const dir = path.join(root, ...name.split('/'))
    const pj = path.join(dir, 'package.json')
    if (existsSync(pj)) {
      const pkg = readJson(pj)
      if (pkg) return { dir, pkg }
    }
  }
  return null
}

// ------------------------------------------------------------------ semver
let semver = null
for (const anchor of [path.join(profileDir, 'package.json'), args.dsh ? path.join(args.dsh, 'package.json') : null].filter(Boolean)) {
  if (semver) break
  try {
    const require = createRequire(anchor)
    semver = require('semver')
  } catch { /* try the next anchor */ }
}
if (!semver) say('[health] note: no semver implementation found - version-range checks are skipped')

const dshVersion = args.dsh ? readJson(path.join(args.dsh, 'node_modules', '@deepseek-ai', 'dsh', 'package.json'))?.version ?? null : null
// --against never touches anything: it only predicts what a future DSH would do.
if (args.against && args.remove) {
  say('[health] --against is a prediction, not a repair - --remove is ignored for it')
  args.remove = false
}
const runtimeVersion = args.against ?? dshVersion

// ---------------------------------------------------- accepted exemptions
// DSH can be told to load one exact package@version on one exact runtime
// anyway (`dsh plugin allow-version`, persisted in the profile's
// compatibility.json). When the user has accepted that risk the plugin really
// does load, so it must NOT be reported as unsupported: otherwise this check
// contradicts the running DSH, and `--remove` could delete a plugin the user
// deliberately approved.
// On disk compatibility.json IS the bare exemption map
// ({"dsh-win-toolkit@0.1.3": ["0.2.0-rc.2"]}); DSH's reader wraps it in
// { exemptions, warnings }, so accept either shape here.
const rawCompat = readJson(path.join(profileDir, 'compatibility.json')) ?? {}
const exemptions = rawCompat.exemptions ?? rawCompat
function isExempted(name, version) {
  if (!runtimeVersion) return false
  const allowed = exemptions[`${name}@${version}`]
  return Array.isArray(allowed) && allowed.includes(runtimeVersion)
}
if (dshVersion) {
  say(args.against
    ? `[health] profile ${args.profile} | DSH ${dshVersion} -> ${args.against} | ${userPlugins.length} community plugin(s)`
    : `[health] profile ${args.profile} | DSH ${dshVersion} | ${userPlugins.length} community plugin(s)`)
}

// ------------------------------------------------------------ per-plugin
const broken = []
const warnings = []
const exemptedNotes = []

for (const name of userPlugins) {
  const found = resolvePackage(name)
  if (!found) {
    broken.push({ name, reasons: ['its package folder is gone - nothing resolves it any more'] })
    continue
  }
  const pkg = found.pkg
  const structural = []   // breakage that is true whichever DSH runs
  const policy = []       // a mismatch with THIS runtime, which an exemption can excuse
  const exempted = isExempted(name, pkg.version)

  // 1. the bundle patch it declares must exist
  const patch = pkg.dsh?.bundle?.patch
  if (typeof patch === 'string' && patch) {
    const file = path.resolve(found.dir, patch)
    if (!existsSync(file)) structural.push(`its declared bundle patch ${patch} is missing`)
  } else if (pkg.dsh === undefined) {
    structural.push('it has no dsh metadata any more, so the profile cannot load it as a plugin')
  }

  // 2. the package names its client half injects must exist in this DSH
  const inject = pkg.dsh?.client?.inject
  if (Array.isArray(inject)) {
    const missing = inject.filter((n) => !resolvePackage(String(n)))
    if (missing.length > 0) structural.push(`its web half injects ${missing.join(', ')}, which this DSH does not provide`)
  }

  // 3. an explicit "which DSH versions do I support" declaration
  const declaredRange = pkg.dsh?.compatibility?.dsh
  if (runtimeVersion && typeof declaredRange === 'string' && semver) {
    try {
      if (!semver.satisfies(runtimeVersion, declaredRange, { includePrerelease: true })) {
        policy.push(`it declares support for DSH ${declaredRange}, and this DSH is ${runtimeVersion}`)
      }
    } catch { /* an unparsable range is not evidence of breakage */ }
  }
  const releaseVerdict = runtimeVersion ? pkg.dsh?.compatibility?.dshReleases?.[runtimeVersion] : undefined
  if (typeof releaseVerdict === 'string' && /incompat|broken|unsupported/i.test(releaseVerdict)) {
    policy.push(`it marks DSH ${runtimeVersion} as "${releaseVerdict}"`)
  }

  // 4. peer dependencies: a version mismatch is hard evidence, a missing
  //    non-DSH peer (react and friends) is only worth a warning because the
  //    host may hand it over at runtime.
  const peers = pkg.peerDependencies ?? {}
  const optionalPeers = pkg.peerDependenciesMeta ?? {}
  const unsat = new Set()
  for (const [peerName, range] of Object.entries(peers)) {
    if (args.against && peerName.startsWith('@deepseek-ai/dsh')) {
      // The hypothetical question. DSH refuses to load a plugin whose
      // @deepseek-ai/dsh-* peers do not accept the runtime it is running, so
      // compare every such range straight against the version under test.
      //
      // Note there is deliberately NO optional-peer skip here: DSH does not
      // honour peerDependenciesMeta for this gate. Measured against a real
      // dsh 0.2.0-rc.2, it skipped dshmarket, dsh-free-search and
      // @nanmicoder/dsh-agent-teams even though all of them mark their
      // @deepseek-ai/dsh-* peers optional.
      if (semver && typeof range === 'string' && range) {
        try {
          if (!semver.satisfies(args.against, range, { includePrerelease: true })) unsat.add(range)
        } catch { /* ignore unparsable ranges */ }
      }
      continue
    }
    if (optionalPeers[peerName]?.optional === true) continue
    const peer = resolvePackage(peerName)
    if (!peer) {
      const line = `needs ${peerName}${range ? '@' + range : ''}, which is not installed`
      if (peerName.startsWith('@deepseek-ai/')) policy.push(line)
      else warnings.push({ name, reason: line })
      continue
    }
    const actual = peer.pkg.version
    if (semver && typeof range === 'string' && range) {
      try {
        if (!semver.satisfies(actual, range, { includePrerelease: true })) {
          policy.push(`needs ${peerName}@${range} but this DSH ships ${peerName}@${actual}`)
        }
      } catch { /* ignore unparsable ranges */ }
    }
  }
  if (unsat.size > 0) {
    policy.push(`its @deepseek-ai/dsh-* peers accept ${[...unsat].join(' , ')}, so DSH ${args.against} would refuse to load it`)
  }

  const reasons = [...structural, ...policy]
  if (reasons.length > 0) {
    // An exemption the user granted outranks a version-range mismatch: DSH
    // really does load that plugin, so calling it broken would contradict the
    // running server - and `--remove` must never delete a plugin the user
    // explicitly approved. Genuine structural breakage still wins.
    if (exempted && structural.length === 0) exemptedNotes.push({ name, version: pkg.version, reasons })
    else broken.push({ name, version: pkg.version, reasons })
  }
}

for (const w of warnings) say(`[health] warning: ${w.name} ${w.reason} (kept)`)
for (const e of exemptedNotes) {
  say(`[health] note: ${e.name}${e.version ? '@' + e.version : ''} does not declare DSH ${runtimeVersion}, but you granted an exact-version exemption - it loads anyway (risk accepted)`)
}

if (broken.length === 0) {
  say(args.against
    ? `[health] all ${userPlugins.length} community plugin(s) would still load on DSH ${args.against}`
    : '[health] every community plugin matches this DSH build')
  if (args.json) console.log(JSON.stringify({ profile: args.profile, dsh: dshVersion, against: args.against, wouldDrop: [], broken: [], warnings, exempted: exemptedNotes }, null, 2))
  process.exit(0)
}

const dshBin = args.dsh ? path.join(args.dsh, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js') : null
const removed = []

/**
 * Drop a plugin by editing the profile manifest and deleting its folder.
 * This is deliberately offline: `pnpm remove` has to re-resolve the whole
 * dependency set, so it fails exactly when it is needed most - a plugin whose
 * package is gone from the registry, or a machine without network.
 */
function removeByManifest(name) {
  const manifestPath = path.join(profileDir, 'package.json')
  const json = readJson(manifestPath)
  if (!json) return { ok: false, detail: 'the profile manifest is not readable JSON' }
  const deps = json.dependencies ?? {}
  const wasDep = Object.prototype.hasOwnProperty.call(deps, name)
  const bundles = json.dsh?.profile?.bundles
  const wasBundle = Array.isArray(bundles) && bundles.includes(name)
  if (!wasDep && !wasBundle) return { ok: false, detail: 'the manifest no longer declares it' }
  if (wasDep) delete deps[name]
  if (wasBundle) json.dsh.profile.bundles = bundles.filter((n) => n !== name)
  try {
    writeFileSync(manifestPath, JSON.stringify(json, null, 2) + '\n', 'utf8')
  } catch (e) {
    return { ok: false, detail: `writing the profile manifest failed: ${e.message}` }
  }
  // rmSync unlinks a junction/symlink instead of walking into it, so nothing
  // outside this profile is ever deleted.
  const dir = path.join(profileDir, 'node_modules', ...name.split('/'))
  let folder = 'no installed folder to delete'
  if (existsSync(dir)) {
    try {
      rmSync(dir, { recursive: true, force: true })
      folder = 'installed folder deleted'
    } catch (e) {
      folder = `installed folder left in place (${e.message})`
    }
  }
  const what = [wasDep ? 'dependency' : null, wasBundle ? 'bundle' : null].filter(Boolean).join(' + ')
  return { ok: true, detail: `${what} dropped from the manifest, ${folder}` }
}

for (const item of broken) {
  say(args.against
    ? `[health] WOULD BE SKIPPED BY DSH ${args.against}: ${item.name}${item.version ? '@' + item.version : ''}`
    : `[health] PLUGIN NOT SUPPORTED BY THIS DSH: ${item.name}${item.version ? '@' + item.version : ''}`)
  for (const r of item.reasons) say(`[health]   - ${r}`)

  // A prediction must never mutate the profile.
  if (args.against) continue

  if (!args.remove) {
    say('[health]   (not removed: run with --remove to drop it)')
    continue
  }
  if (args.protect.includes(item.name)) {
    say('[health]   protected on purpose - remove it by hand if you really want to lose it')
    continue
  }

  say(`[health]   removing it from profile "${args.profile}" ...`)
  let result = removeByManifest(item.name)

  if (!result.ok && dshBin && existsSync(dshBin)) {
    // Fall back to pnpm in case the manifest was already inconsistent.
    const res = spawnSync(process.execPath, [dshBin, 'plugin', '--profile', args.profile, 'remove', item.name], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    const tail = String(res.stdout ?? '').trim().split('\n').slice(-3).join(' | ')
    result = res.status === 0
      ? { ok: true, detail: tail || 'removed through the plugin command' }
      : { ok: false, detail: `${result.detail}; the plugin command failed too (exit ${res.status}) ${tail || String(res.stderr ?? '').trim().split('\n').slice(-2).join(' | ')}` }
  }

  if (result.ok) {
    removed.push(item.name)
    say(`[health]   ${result.detail}`)
    say('[health]   it is gone at the next start (this script never restarts DSH)')
  } else {
    say(`[health]   could not remove it: ${result.detail}`)
  }
}

if (args.against) say(`[health] DSH ${args.against} would drop ${broken.length} of ${userPlugins.length} community plugin(s): ${broken.map((b) => b.name).join(', ')}`)
if (args.json) console.log(JSON.stringify({ profile: args.profile, dsh: dshVersion, against: args.against, wouldDrop: args.against ? broken.map((b) => b.name) : [], broken, removed, warnings, exempted: exemptedNotes }, null, 2))
if (removed.length > 0) say('[health] the profile lockfile is left untouched; the next plugin install or update refreshes it')
say(args.against
  ? `[health] result: ${broken.length} plugin(s) would not survive the upgrade to ${args.against}`
  : `[health] result: ${broken.length} unsupported plugin(s), ${removed.length} removed`)
process.exit(0)
