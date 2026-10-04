// i18n.mjs -- shared translator for the Node side, mirroring tools/dsh-common.ps1.
//
// The English sentence IS the key; lang/<name>.txt holds
//     exact|English sentence|Translated sentence
//     sub|English fragment|Translated fragment
// Anything not listed stays English, which is why English needs no file.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.dirname(here)
const langDir = path.join(root, 'lang')

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

function readSettings() {
  try {
    return JSON.parse(fs.readFileSync(path.join(root, 'settings.json'), 'utf8').replace(/^\uFEFF/, ''))
  } catch { return {} }
}

export function resolveLang() {
  const s = readSettings()
  let want = process.env.DSH_LANG || s.lang || ''
  if (String(want).toLowerCase() === 'auto') want = ''   // follow the system
  if (!want) { try { want = Intl.DateTimeFormat().resolvedOptions().locale } catch { want = 'en' } }
  for (const n of [want, String(want).split(/[-_]/)[0], 'en']) {
    if (n && fs.existsSync(path.join(langDir, n + '.txt'))) return n
  }
  return 'en'
}

export function loadTranslator(name = resolveLang()) {
  if (name === 'en') return (s) => s
  const exact = new Map()
  const subs = []
  let text = ''
  try { text = fs.readFileSync(path.join(langDir, name + '.txt'), 'utf8') } catch { return (s) => s }
  for (const line of text.split(/\r?\n/)) {
    if (!line || line.startsWith('#')) continue
    const p = line.split('|')
    if (p.length < 3) continue
    const kind = p[0].trim()
    const from = p[1]
    const to = p.slice(2).join('|')
    if (kind === 'exact') exact.set(from.replace(/\s+/g, ' ').trim().toLowerCase(), to)
    else if (kind === 'sub') subs.push({ re: new RegExp(escapeRe(from).replace(/ +/g, '\\s+'), 'gi'), to })
  }
  // Longest fragment first, so "install backup ready" wins over "install backup".
  subs.sort((a, b) => b.re.source.length - a.re.source.length)
  return (s) => {
    if (!s) return s
    const m = /^(\s*)(\[[A-Za-z][A-Za-z-]*\]\s+)?(.*)$/.exec(s)
    const lead = m ? (m[1] + (m[2] || '')) : ''
    let body = m ? m[3] : s
    const hit = exact.get(body.replace(/\s+/g, ' ').trim().toLowerCase())
    if (hit) return lead + hit
    for (const r of subs) body = body.replace(r.re, () => r.to)
    return lead + body
  }
}
