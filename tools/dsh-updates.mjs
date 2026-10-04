#!/usr/bin/env node
/**
 * dsh-updates.mjs -- read-only update check for DSH itself and for the plugins
 * of a DSH profile.
 *
 * Why this exists: run.bat / the boot task must decide *before* touching
 * anything whether there is something to install. Doing that with `npm view`
 * one package at a time is slow and leaves the answer scattered across many
 * processes. This script answers both questions in one pass and prints a single
 * JSON document.
 *
 * It only READS: the DSH install's package.json, the profile manifest, each
 * installed plugin's package.json, the profile's pnpm policy and the npm
 * registry. It never installs, writes or restarts anything, so it is safe to
 * run while a DSH server is already up.
 *
 * Two gates decide whether "a newer version exists" is actually "the next
 * install will move it":
 *
 *   1. the declared range -- pnpm update only moves inside it, so a version
 *      outside the range is reported as PINNED, not as an update;
 *   2. pnpm's minimum release age -- pnpm 11 refuses to write a lockfile entry
 *      for a version published less than `minimumReleaseAge` minutes ago, so a
 *      brand-new version is reported as HELD with the date it becomes usable.
 *      Reporting it as an update would describe an install that cannot succeed.
 *
 * Usage:
 *   node dsh-updates.mjs [--profile web] [--dsh <install dir>] [--tag next]
 *                        [--home <dsh home>] [--registry <url>] [--json]
 *                        [--out <file>] [--timeout <ms>] [--ages]
 *
 * Exit codes: 0 nothing to update, 10 updates available, 1 internal error.
 * (`held` and `pinned` entries never raise the exit code: nothing would install
 * them, so they must not make the caller start an update run.)
 */

import { createRequire } from 'node:module'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import os from 'node:os'

// --------------------------------------------------------------- arguments
function parseArgs(argv) {
  const out = {
    profile: process.env.DSH_PROFILE || 'web',
    dsh: null,
    tag: process.env.DSH_TAG || 'next',
    home: null,
    registry: null,
    json: false,
    out: null,
    timeout: 20000,
    ages: false,
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--profile') out.profile = argv[++i]
    else if (a === '--dsh') out.dsh = argv[++i]
    else if (a === '--tag') out.tag = argv[++i]
    else if (a === '--home') out.home = argv[++i]
    else if (a === '--registry') out.registry = argv[++i]
    else if (a === '--out') out.out = argv[++i]
    else if (a === '--timeout') out.timeout = Number(argv[++i]) || out.timeout
    else if (a === '--json') out.json = true
    else if (a === '--ages') out.ages = true
  }
  return out
}

const args = parseArgs(process.argv.slice(2))
const errors = []

function readJson(file) {
  try {
    // A manifest that Windows tooling wrote can start with a UTF-8 BOM, which
    // JSON.parse rejects. npm and pnpm both tolerate it, and a boot-time check
    // that dies on a BOM would be a self-inflicted outage.
    const text = readFileSync(file, 'utf8').replace(/^\uFEFF/, '')
    return JSON.parse(text)
  } catch { return null }
}

function dshHome() {
  if (args.home) return args.home
  if (process.env.DSH_HOME) return process.env.DSH_HOME
  return path.join(os.homedir(), '.dsh')
}

/**
 * The registry the *installs* will actually use. A profile that pins a mirror
 * (registry.npmmirror.com on this machine) must be checked against that same
 * mirror, otherwise this script reports a version the mirror has not synced yet
 * and the following install fails for no visible reason.
 */
function registryFromNpmrc(dir) {
  if (!dir) return null
  const file = path.join(dir, '.npmrc')
  if (!existsSync(file)) return null
  try {
    for (const raw of readFileSync(file, 'utf8').split(/\r?\n/)) {
      const line = raw.trim()
      if (!line || line.startsWith('#') || line.startsWith(';')) continue
      const eq = line.indexOf('=')
      if (eq < 0) continue
      if (line.slice(0, eq).trim() !== 'registry') continue
      const value = line.slice(eq + 1).trim().replace(/\/+$/, '')
      if (value) return value
    }
  } catch { /* an unreadable .npmrc just means "use the default" */ }
  return null
}

/**
 * pnpm's release-age gate, read out of the profile's pnpm-workspace.yaml.
 *
 * This is not a detail: pnpm 11 defaults to refusing any version younger than
 * seven days, and this profile has already been bitten by it -- its
 * minimumReleaseAgeExclude list carries a comment saying the 7-day age blocked
 * every further lockfile write. A checker that ignores the gate promises
 * updates the install step then silently declines to make.
 *
 * Only the two keys that matter here are parsed; a hand-written YAML reader
 * would be a liability, but these are a scalar and a flat list.
 */
export function readPnpmReleaseAgePolicy(profileDir) {
  const policy = {
    minutes: 10080,           // pnpm 11's own default
    source: 'default',
    exclude: [],
  }
  const file = path.join(profileDir, 'pnpm-workspace.yaml')
  if (!existsSync(file)) return policy
  try {
    const raw = readFileSync(file, 'utf8').split(/\r?\n/)
    let inExclude = false
    for (const line of raw) {
      const code = line.replace(/(^|\s)#.*$/, '').trimEnd()
      if (!code.trim()) continue
      const scalar = /^minimumReleaseAge:\s*(\d+)\s*$/.exec(code.trim())
      if (scalar) {
        policy.minutes = Number(scalar[1])
        policy.source = 'pnpm-workspace.yaml'
        continue
      }
      if (/^minimumReleaseAgeExclude:\s*\[\s*\]\s*$/.test(code.trim())) {
        inExclude = false
        continue
      }
      if (/^minimumReleaseAgeExclude:\s*$/.test(code.trim())) {
        inExclude = true
        continue
      }
      if (inExclude) {
        const item = /^\s*-\s*(.+?)\s*$/.exec(code)
        if (item) {
          policy.exclude.push(item[1].trim().replace(/^['"]|['"]$/g, ''))
          continue
        }
        // A non-indented line ends the list.
        if (!/^\s/.test(code)) inExclude = false
      }
    }
    if (policy.source === 'default') policy.source = 'pnpm-workspace.yaml (no minimumReleaseAge key)'
  } catch { /* unreadable -> keep pnpm's documented default */ }
  return policy
}

/** `name@version`, `name@range`, `name@*` or a bare `name`, like pnpm accepts. */
export function isReleaseAgeExcluded(exclude, name, version, semver) {
  for (const entry of exclude) {
    if (!entry) continue
    const at = entry.lastIndexOf('@')
    let entryName = entry
    let entryRange = '*'
    if (at > 0) {
      entryName = entry.slice(0, at)
      entryRange = entry.slice(at + 1)
    }
    if (entryName !== name) continue
    if (entryRange === '*' || entryRange === version) return true
    if (semver) {
      try { if (semver.satisfies(version, entryRange)) return true } catch { /* not a range */ }
    }
  }
  return false
}

// ------------------------------------------------------------------- semver
// Resolved out of the profile or the DSH install, exactly like the health
// checker does; a missing implementation degrades to string comparison instead
// of failing the whole check.
function loadSemver(anchors) {
  for (const anchor of anchors) {
    if (!anchor) continue
    try {
      const require = createRequire(anchor)
      return require('semver')
    } catch { /* try the next anchor */ }
  }
  return null
}

/** Last-resort ordering for "a.b.c-pre" style versions; only used when semver is absent. */
function compareLoose(a, b) {
  const part = (v) => String(v).split(/[.+-]/).map((x) => (/^\d+$/.test(x) ? Number(x) : x))
  const xa = part(a)
  const xb = part(b)
  for (let i = 0; i < Math.max(xa.length, xb.length); i++) {
    const va = xa[i]
    const vb = xb[i]
    if (va === vb) continue
    if (va === undefined) return -1
    if (vb === undefined) return 1
    if (typeof va === 'number' && typeof vb === 'number') return va < vb ? -1 : 1
    return String(va) < String(vb) ? -1 : 1
  }
  return 0
}

// ------------------------------------------------------------------ network
const cache = new Map()

/**
 * `full` asks for the complete packument, which is the only one that carries
 * the `time` map the release-age gate needs; the abbreviated document is used
 * everywhere else because it is a fraction of the size.
 */
async function fetchPackument(name, { full = false } = {}) {
  const url = packumentUrl(registry, name)
  const key = url + (full ? '|full' : '|corgi')
  if (cache.has(key)) return cache.get(key)
  const promise = (async () => {
    const res = await fetch(url, {
      headers: {
        accept: full
          ? 'application/json'
          : 'application/vnd.npm.install-v1+json, application/json',
        'user-agent': 'dsh-updates-check',
      },
      signal: AbortSignal.timeout(args.timeout),
    })
    if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`)
    return await res.json()
  })()
  cache.set(key, promise)
  return promise
}

function packumentUrl(registry, name) {
  // A scoped name keeps its "@" and only the slash is escaped, which is what
  // both registry.npmjs.org and registry.npmmirror.com expect.
  return `${registry.replace(/\/+$/, '')}/${name.replace('/', '%2F')}`
}

// ------------------------------------------------------------------- layout
const home = dshHome()
const profileDir = path.join(home, 'profiles', args.profile)
const installDir = args.dsh ? path.resolve(args.dsh) : null

const profileManifest = readJson(path.join(profileDir, 'package.json'))
if (!profileManifest) {
  console.error(`[updates] no readable profile manifest at ${path.join(profileDir, 'package.json')}`)
  process.exit(1)
}

const registry = args.registry
  || registryFromNpmrc(profileDir)
  || registryFromNpmrc(installDir)
  || 'https://registry.npmjs.org'

const semver = loadSemver([
  path.join(profileDir, 'package.json'),
  installDir ? path.join(installDir, 'package.json') : null,
])

const releaseAge = readPnpmReleaseAgePolicy(profileDir)

// ---------------------------------------------------------------- DSH itself
const dshPackageDir = installDir ? path.join(installDir, 'node_modules', '@deepseek-ai', 'dsh') : null
const dshInstalled = dshPackageDir && existsSync(path.join(dshPackageDir, 'package.json'))
  ? readJson(path.join(dshPackageDir, 'package.json'))?.version ?? null
  : null

const dshReport = {
  installDir,
  installed: dshInstalled,
  tag: args.tag,
  target: null,
  distTags: null,
  updateAvailable: false,
}

if (installDir) {
  try {
    const doc = await fetchPackument('@deepseek-ai/dsh')
    dshReport.distTags = doc['dist-tags'] ?? null
    dshReport.target = doc['dist-tags']?.[args.tag] ?? null
    if (!dshReport.target) {
      errors.push(`the registry has no dist-tag "${args.tag}" for @deepseek-ai/dsh`)
    } else {
      dshReport.updateAvailable = dshInstalled !== dshReport.target
    }
  } catch (e) {
    errors.push(`could not reach the registry for @deepseek-ai/dsh: ${e.message}`)
  }
}

// ------------------------------------------------------------------ plugins
const dependencies = profileManifest.dependencies ?? {}
const bundles = profileManifest.dsh?.profile?.bundles ?? []
// Only plugins this profile actually declares and mounts. The shipped
// @deepseek-ai bundles are DSH itself, not plugins.
const pluginNames = Object.keys(dependencies)
  .filter((n) => !n.startsWith('@deepseek-ai/') && bundles.includes(n))
  .sort()

const nodeModules = path.join(profileDir, 'node_modules')

function installedVersionOf(name) {
  const pj = path.join(nodeModules, ...name.split('/'), 'package.json')
  return existsSync(pj) ? readJson(pj)?.version ?? null : null
}

function classifySpec(spec) {
  const s = String(spec ?? '')
  if (/^(file|link|portal|workspace):/.test(s)) return 'local'
  if (/^(git\+|git:|github:|https?:|ssh:)/.test(s)) return 'git'
  return 'registry'
}

/**
 * When would this version pass pnpm's release-age gate? Returns null when it
 * already does. Failures are deliberately non-fatal: if the `time` map cannot
 * be read we say nothing about age rather than inventing a verdict.
 */
async function releaseAgeVerdict(name, version) {
  if (!releaseAge.minutes || releaseAge.minutes <= 0) return null
  if (isReleaseAgeExcluded(releaseAge.exclude, name, version, semver)) return null
  let times
  try {
    const doc = await fetchPackument(name, { full: true })
    times = doc.time ?? null
  } catch (e) {
    errors.push(`could not read publish times for ${name}: ${e.message}`)
    return null
  }
  const published = times?.[version]
  if (!published) return null
  const publishedMs = Date.parse(published)
  if (Number.isNaN(publishedMs)) return null
  const eligibleMs = publishedMs + releaseAge.minutes * 60_000
  if (Date.now() >= eligibleMs) return null
  return {
    published,
    ageMinutes: Math.floor((Date.now() - publishedMs) / 60_000),
    gateMinutes: releaseAge.minutes,
    eligibleAt: new Date(eligibleMs).toISOString(),
  }
}

const outdated = []
const held = []
const pinned = []
const skipped = []
const unknown = []

await Promise.all(pluginNames.map(async (name) => {
  const spec = dependencies[name]
  const kind = classifySpec(spec)
  if (kind !== 'registry') {
    skipped.push({ name, spec, reason: kind === 'local' ? 'installed from a local file' : 'installed from a git or URL source' })
    return
  }
  const installed = installedVersionOf(name)
  if (!installed) {
    skipped.push({ name, spec, reason: 'not installed in this profile yet' })
    return
  }
  let doc
  try {
    doc = await fetchPackument(name)
  } catch (e) {
    errors.push(`could not reach the registry for ${name}: ${e.message}`)
    return
  }
  const versions = Object.keys(doc.versions ?? {})
  const distTags = doc['dist-tags'] ?? null

  if (!semver) {
    const latest = distTags?.latest ?? null
    if (latest && compareLoose(latest, installed) > 0) {
      outdated.push({ name, spec, installed, newest: latest, distTags, note: 'compared without semver' })
    }
    return
  }

  // The newest version the declared range still accepts. Prerelease handling is
  // deliberately semver's DEFAULT here: npm and pnpm will not move `^0.1.21`
  // onto `0.1.22-rc.1`, so neither may this check, or the report would describe
  // an update that the following install refuses to make. A range that itself
  // names a prerelease (dsh-codex-connect pins `^0.1.0-alpha.4.52`) still tracks
  // later alpha builds of the same x.y.z, which is exactly the intent.
  const accepted = versions.filter((v) => {
    try { return semver.satisfies(v, spec) } catch { return false }
  })
  if (accepted.length === 0) {
    unknown.push({ name, spec, installed, reason: 'no published version matches the declared range' })
    return
  }
  const newest = accepted.sort((a, b) => semver.rcompare(a, b))[0]
  if (semver.gt(newest, installed)) {
    const verdict = await releaseAgeVerdict(name, newest)
    if (verdict) held.push({ name, spec, installed, newest, distTags, ...verdict })
    else outdated.push({ name, spec, installed, newest, distTags })
    return
  }
  if (semver.valid(spec) !== null) {
    // The spec is one exact version, so it can never move on its own. That is
    // the one case where "no update available" does not mean "up to date", and
    // it is worth saying out loud rather than hiding behind the dependency pin.
    const newestAny = [distTags?.latest, distTags?.alpha, distTags?.next]
      .filter((v) => typeof v === 'string' && semver.valid(v))
      .sort((a, b) => semver.rcompare(a, b))[0] ?? null
    if (newestAny && semver.gt(newestAny, installed)) {
      pinned.push({ name, spec, installed, newest: newestAny, distTags })
    }
  }
}))

outdated.sort((a, b) => a.name.localeCompare(b.name))
held.sort((a, b) => a.name.localeCompare(b.name))
pinned.sort((a, b) => a.name.localeCompare(b.name))
skipped.sort((a, b) => a.name.localeCompare(b.name))
unknown.sort((a, b) => a.name.localeCompare(b.name))

const report = {
  checkedAt: new Date().toISOString(),
  registry,
  profile: args.profile,
  profileDir,
  semver: semver ? semver.version ?? 'available' : 'missing',
  releaseAge: {
    minutes: releaseAge.minutes,
    source: releaseAge.source,
    exclude: releaseAge.exclude,
  },
  dsh: dshReport,
  plugins: {
    declared: pluginNames.length,
    outdated,
    held,
    pinned,
    skipped,
    unknown,
  },
  // Only updates an install would actually make count towards this.
  updateAvailable: Boolean(dshReport.updateAvailable || outdated.length > 0),
  errors,
}

// -------------------------------------------------------------------- output
const text = JSON.stringify(report, null, 2)
if (args.out) {
  try { writeFileSync(args.out, text + '\n', 'utf8') } catch (e) { errors.push(`could not write ${args.out}: ${e.message}`) }
}
if (args.json) {
  process.stdout.write(text + '\n')
} else {
  const line = (s) => process.stdout.write(s + '\n')
  const ageTag = report.releaseAge.minutes > 0
    ? `  release-age gate ${report.releaseAge.minutes}m (${report.releaseAge.source})`
    : '  release-age gate off'
  line(`[updates] registry ${registry}${semver ? '' : '  (no semver - ranges not evaluated)'}`)
  line(`[updates]${ageTag}`)
  line(report.dsh.installed
    ? `[updates] dsh        ${report.dsh.installed} -> ${report.dsh.target ?? '?'} (tag ${args.tag})${report.dsh.updateAvailable ? '   UPDATE AVAILABLE' : '   up to date'}`
    : '[updates] dsh        not installed locally')
  line(`[updates] plugins    ${pluginNames.length} declared, ${outdated.length} outdated, ${held.length} held, ${pinned.length} pinned, ${skipped.length} skipped`)
  for (const p of outdated) line(`[updates]   update     ${p.name} ${p.installed} -> ${p.newest}   (spec ${p.spec})`)
  for (const p of held) line(`[updates]   held       ${p.name} ${p.installed} -> ${p.newest} is ${p.ageMinutes}m old; the ${p.gateMinutes}m release-age gate opens ${p.eligibleAt}`)
  for (const p of pinned) line(`[updates]   pinned     ${p.name} ${p.installed} is pinned; ${p.newest} exists   (spec ${p.spec})`)
  for (const p of skipped) line(`[updates]   skipped    ${p.name} - ${p.reason}`)
  for (const p of unknown) line(`[updates]   unknown    ${p.name} - ${p.reason}`)
  for (const e of errors) line(`[updates] error      ${e}`)
  line(report.updateAvailable ? '[updates] result: updates available' : '[updates] result: everything up to date')
}

process.exit(report.updateAvailable ? 10 : 0)
