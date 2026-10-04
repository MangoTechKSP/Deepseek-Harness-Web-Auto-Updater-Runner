# DSH AutoUpdate — a self-maintaining DeepSeek Harness

A portable, multi-language launcher that keeps **DSH (DeepSeek Harness)** and its
plugins up to date, with a real backup and rollback path, and a settings panel.

- **No folder restrictions.** Unpack it anywhere — `C:\DSH`, `D:\tools\dsh`, a USB
  stick, a path full of spaces or Chinese characters. Every script derives its own
  location, and it registers its tasks with the path it was started from.
- **Multi-language, English by default.** The UI language is a setting, not a
  build. Adding a language = adding one text file.
- **Nothing is ever updated behind your back.** When something *can* be updated
  you get one question; when nothing is waiting, the start is completely silent.

---

## 1. Requirements

| | |
|---|---|
| OS | Windows 10 / 11 (64-bit) |
| Node.js | **20 or newer** — check with `node -v` (https://nodejs.org) |
| Disk | ~1 GB for DSH plus ~300 MB per backup generation (10 are kept) |
| Network | only for installing/updating. Everything else works offline. |

## 2. First run

1. Unpack the archive anywhere you like.
2. Double-click **`install.bat`** — installs DSH into the `dsh\` folder next to it
   and registers the two scheduled tasks. Takes a few minutes.
3. Double-click **`run.bat`** — the browser opens at **http://127.0.0.1:3080**.

From then on every logon does the check by itself. You only double-click
`run.bat` when you want to start it by hand.

## 3. Entry points

| File | What it does |
|---|---|
| `install.bat` | Install (or repair) DSH in this folder, then register the tasks. |
| `run.bat` | Start DSH. Asks before an update, then opens the browser. Never restarts a server that is already running. |
| `settings.bat` | **The control panel.** Language, port, profile, update channel, browser, the update question, tasks, status, and every action below. |
| `restart.bat` | Stop, then start again. **Needed after a plugin update** for the new code to load. |
| `stop.bat` | Stop the DSH server (only DSH — nothing else that happens to use the port). |
| `update-now.bat` | Run the whole update check right now, without starting a server. |
| `health.bat` | Read-only report: is every plugin compatible with the installed DSH? `health.bat --remove` drops the broken ones. |
| `backup.bat` | Take a plugin snapshot now. `backup.bat -Mode list` lists them. |
| `restore.bat` | List backups and restore one (`restore.bat -Target <name>` skips the prompt). |
| `bump.bat` | List every plugin and its available version. `bump.bat <name>` force-updates one plugin past the release-age gate. |

## 4. Language

`settings.bat` → **1 Language** lists every file in `lang\`, plus `auto`.

- `en` is the default. English is the *source* text, so there is nothing to
  translate for it and no file to keep in sync.
- `auto` (and an empty value) follows the Windows UI language.
- `zh-CN` ships as a complete example (about 250 rules).

**To add a language:** copy `lang\en.txt` to `lang\<code>.txt` (e.g. `de.txt`,
`ja.txt`, `fr.txt`) and add one rule per line:

```
exact|DSH is already up to date - nothing to install|DSH ist bereits aktuell
sub|install dir : |Installationsordner: 
sub| : |: 
```

- `exact|` replaces the whole line, `sub|` replaces a fragment inside it.
- The **English sentence is the key** — you never touch code or a script.
- Unmatched lines simply stay English, so a half-finished translation is safe.
- `sub` rules are applied longest-first. A run of spaces matches any run of
  spaces, so padded labels (`npm         : `) need only one rule.

## 5. What happens on every start

```
run.bat
 ├─ is DSH already listening?  ── yes ─→ just open the browser, change nothing
 ├─ silent update check  (installed DSH vs. the registry, and every plugin)
 │    ├─ nothing waiting ──→ start quietly, no window, no question
 │    └─ something waiting ─→ ONE popup (Yes / No)
 │           Yes → run.bat continues in a visible console, updates, verifies,
 │                 and opens the browser when it is done
 │           No  → start the current version; asked again next time
 ├─ plugin snapshot (only if the plugin set changed)
 ├─ update the DSH body if needed, with automatic rollback on failure
 ├─ compatibility + composition check
 └─ start the server on the configured port
```

At logon the same chain runs from `tools\dsh-boot-hidden.vbs` with
`DSH_OPEN_BROWSER=0`, so **nothing appears on screen unless there is a question
to ask**.

## 6. Backup and rollback — three layers

| Layer | Where | Covers | Restore with |
|---|---|---|---|
| Plugin snapshots | `backups\plugins-*` | `package.json`, `cordis*.yml`, `pnpm-lock.yaml` and the plugin bodies | `restore.bat` |
| Previous DSH install | `backups\dsh-install\previous` | the entire `dsh\` tree from before the last upgrade | `dsh-update.ps1 -Rollback` |
| Version history | `backups\dsh-install\failed-versions.json` | a version that already failed here is not retried for 12 h | `-IgnoreUpdateFailures` |

A snapshot is taken automatically before every update, every plugin change,
every restore, and at logon when the plugin set changed. Auto snapshots keep the
newest **10**; named ones keep 3 per name; a manual snapshot is never rotated
away. Rollback never needs the network.

## 7. Scheduled tasks

| Task | When | What |
|---|---|---|
| `DSH-Boot-AutoUpdate` | at logon, +45 s | the hidden chain above |
| `DSH-Plugin-AutoBackup` | every 15 minutes | snapshot only if something changed |

Both are registered **without administrator rights** and can be added or removed
from `settings.bat` (options 12 / 13).

> A scheduled task is bound to the folder it was registered from. If you move
> the folder, run `settings.bat` → 13, then 12 — or simply `install.bat` again.

## 8. Logs

| File | Content |
|---|---|
| `logs\boot.log` | the update check, the install, the verification, the rollout decisions |
| `logs\run.log` | everything the hidden `run.bat` printed |
| `backups\backup.log` | every snapshot and restore |

## 9. Environment switches

Set one before calling a `.bat` for a single run:

| Variable | Meaning |
|---|---|
| `DSH_SKIP_UPDATE=1` | skip the whole pre-flight |
| `DSH_OPEN_BROWSER=1\|0` | force the browser question |
| `DSH_FORCE_PLUGIN_UPDATE=1` | update plugins even when DSH is current |
| `DSH_UPDATE_APPROVED=1` / `DSH_UPDATE_DECLINED=1` | answer the update question in advance |
| `DSH_LANG=en` | force a language for one run |
| `DSH_POPUP_TIMEOUT=90` | seconds before the question counts as "no" |
| `DSH_NO_PAUSE=1` | never wait for a key |
| `DSH_PORT`, `DSH_PROFILE`, `DSH_TAG`, `DSH_HOME` | override the matching setting |

## 10. When something looks wrong

| Symptom | Do this |
|---|---|
| The browser cannot reach 127.0.0.1:3080 | `settings.bat` → 10 Show status; then `run.bat` and read `logs\run.log` |
| A plugin updated but the UI is unchanged | `restart.bat` — a running server keeps the old code in memory |
| "the pre-flight reported a problem" | open `logs\boot.log`; the failing step is the last one with an error |
| A DSH update fails and is rolled back | normal and safe. The old tree is restored and the version is not retried for 12 h |
| A plugin never updates by itself | `bump.bat` — it is either pinned on purpose or still inside pnpm's 7-day release-age gate |
| A DSH update is found but never installed | the new DSH would refuse to load your plugins. `health.bat --against <version>` names them |
| Port 3080 is used by something else | `settings.bat` → 2 Web port |
| Nothing should update automatically | `settings.bat` → 13 (removes the tasks), or start with `DSH_SKIP_UPDATE=1` |

---

**Principle:** updating, restoring and removing never restart a running DSH by
itself. A restart is always your decision — `restart.bat`, or the next logon.
