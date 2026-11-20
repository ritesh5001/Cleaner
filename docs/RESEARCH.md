# Cleaner — Market Research & Feature Roadmap

_Researched November 2026._

## 1. The landscape

| App | What it's best at | Model | Gap we can exploit |
|---|---|---|---|
| **CleanMyMac** (MacPaw) | Guided all-in-one: junk, malware, uninstaller, optimization, "Smart Insights" (Apple on-device model) | Subscription | Expensive; AI is locked to Apple's small model; opaque about *why* things are safe |
| **DaisyDisk** | Very fast, beautiful disk-usage visualization | One-time | No cleaning intelligence; you have to know what files are |
| **Pearcleaner / AppCleaner** | App uninstall + leftovers (open source) | Free | Single job only; no bulk uninstall |
| **OnyX** | Deep maintenance scripts, hidden settings | Free | Intimidating UI for normal users |
| **Sensei** | Cleanup + monitoring + duplicates | Subscription | No AI explanations |
| **New AI cleaners** (Gargantua, PoofMac, Dusty, Zephyr, DustPan) | LLM explains files | Mixed, mostly BYOK or local Ollama | Mostly single-provider, early-stage, or CLI-only |

**Key insight from the best AI cleaners:** *the model explains and ranks; fixed rules decide what is deletable.* An LLM must never be able to mark `/System` or a Photos library as safe. Cleaner follows this: `SafetyGuard` has the final say on every deletion, and AI only gives advice.

## 2. What users actually struggle with

1. **"System Data" is huge and unexplained.** This is the number-one complaint on Apple forums. The causes are local Time Machine snapshots (often 20–50 GB), caches, logs, iOS backups, old update files and Spotlight bloat on recent macOS.
2. **Developer junk.** Xcode DerivedData, DeviceSupport, simulators, npm/Gradle/Homebrew caches, Docker images and `node_modules`. On this test Mac, npm + Gradle alone were **8.3 GB**.
3. **Browser caches.** Chrome and Brave caches were **5.4 GB** on this test Mac.
4. **Fear of deleting the wrong thing.** This is why an AI that explains "what is this and what happens if I delete it" is valuable.
5. **Apps that leave junk behind** after being dragged to the Trash.

## 2b. Hands-on terminal research (this MacBook, 20 Nov 2026)

Read-only experiments on a 16 GB / 256 GB Apple Silicon MacBook (macOS 27.2) with `du`, `find`, `vm_stat`, `sysctl`, `tmutil`, `hdiutil`, `ps` and `md5`. Nothing was deleted.

### Where junk actually forms

| Location | Found | What it is | Cleaner rule |
|---|---|---|---|
| `~/.npm/_cacache` + `_npx`, `~/.gradle/caches`, Homebrew | **9.5 GB** | Package download caches | Package Manager Caches (Safe) |
| `~/Library/Caches/*` (Chrome 3 GB, Brave 2 GB, Copilot, Playwright, updaters) | **8.2 GB** | App caches | User Cache Files (Safe) |
| `**/.next`, `.turbo`, `.nuxt`… in projects | **4.9 GB** | Regenerable build output | **New:** Project Build Output (Safe) |
| `**/node_modules`, `.venv`, `Pods`, `target` | **2.6 GB** | Reinstallable dependencies | **New:** Project Dependencies (Review) |
| `~/Library/Application Support/*/{Cache,Code Cache,GPUCache,CachedData,CachedExtensionVSIXs}` | **5.1 GB** | Chromium/Electron caches *inside* app data (VS Code, Claude, OpenBot…) — invisible to normal cache cleaners | **New:** Caches Inside Apps (Safe, skipped while the app runs, and the skipped amount is reported) |
| `~/Library/Application Support/Claude/vm_bundles` | **12 GB** | Claude Desktop VM image, re-downloaded on demand | **New:** AI App VM Images (Caution) |
| `/var/folders/…/C` (`getconf DARWIN_USER_CACHE_DIR`) | **1.7 GB** | Hidden per-user macOS cache (Blender 1 GB, clang modules 300 MB) | **New:** Hidden macOS App Caches (Safe, Apple entries skipped) |
| `~/.vscode/extensions/*` not listed in `extensions.json` | **1.0 GB** | Old extension versions VS Code left behind | **New:** Old Editor Extension Versions (Safe) |
| `~/.cache/codex-runtimes/codex-runtime-install-*` | **640 MB** | Interrupted runtime downloads | **New:** Interrupted Runtime Installs (Safe) |
| `~/Downloads/*.aab/.apk/.dmg` | 313 MB | Build/installer artifacts | Installers in Downloads (now includes aab/apk/ipa) |
| Duplicates in Downloads/Desktop/Documents | **101 MB, 114 groups** | Same file saved twice | **New:** Duplicates screen (SHA-256, always keeps one) |
| `/private/var/vm` (swap + sleepimage) | 2.2 GB | Virtual memory | Explained only (macOS-managed) |
| `/private/var/db/diagnostics` + `uuidtext` | 2.0 GB | Unified logs | Explained only (macOS-managed) |

**Smart Scan total on this Mac: 17.3 GB → 29.3 GB** after the new rules, plus ~5 GB more inside apps that were running during the scan.

### Can it clean "cache memory" (RAM)?
- `purge` without admin rights → `Unable to purge disk buffers: Operation not permitted`. With the admin prompt it works, but the effect is temporary: macOS refills the file cache because cached files make the Mac faster.
- Measured on this Mac: **file cache 2.5 GB** (gets handed back to apps immediately when needed, not a problem), **compressed 6.6 GB and swap 1.6 → 5.6 GB**, and memory pressure at **Warning** (`kern.memorystatus_vm_pressure_level = 2`). That is the real slowdown.
- Biggest memory users, counting all of each app's helper processes together: Chrome 1.15 GB (23 processes), VS Code 0.8 GB, **`mcp-wordpress-remote` 0.59 GB in 60 processes** (one MCP server per WordPress site connection), Grok Bot 0.55 GB, Brave 0.4 GB.
- **Conclusion:** Cleaner shows the honest picture (pressure, compression, swap, memory per app including helpers) with one-click Quit, and keeps `purge` as an optional admin task clearly labelled "temporary relief".

### Problems found that no cleaner detects
1. **Google Drive is backing up developer folders**: 177k files queued in `~/PlayGround/.tmp.driveupload` and 23k in `~/Office`, because `node_modules`/`.next` sit inside synced folders. This costs CPU, battery, bandwidth and Drive quota. → **New health check.**
2. **That same 180k-entry staging folder made `FileManager.enumerator` silently stop the entire home-folder walk** (it covered 2.4k entries and then ended with no error). → Cleaner now uses its own walker (`DirWalker`) that lists each folder independently, and never touches sync-engine folders.
3. **A leftover installer image (`GoogleDrive.dmg`) was still mounted.** → **New:** Mounted disk images card with Eject / Eject & Trash.
4. **Background tools that start dozens of copies of themselves** (MCP servers). → **New health check.**
5. **Two browsers open at once.** → **New health check.**

### Second sweep: more junk sources (same day)

| Source | On this Mac | Cleaner |
|---|---|---|
| Homebrew old versions + downloads (`brew cleanup -n --prune=all`) | 941 MB | Health check shows exact size + "Homebrew Cleanup" task |
| Service-worker `CacheStorage` in browsers/Electron apps | 1.04 GB (27 dirs) | Web App Offline Caches (Review, skipped while app runs) |
| Old Chromium engine kept inside `Google Chrome.app` until relaunch | 732 MB | Health check: "restart Chrome" (never edit signed app bundles) |
| `Application Support/*/logs` (VS Code 139 MB) | 151 MB | App Log Folders |
| VS Code `workspaceStorage` for deleted projects | 18 entries | Editor Data for Deleted Projects (checks `workspace.json`) |
| Screenshots/recordings > 30 days | 15 files, 26 MB | Old Screenshots & Screen Recordings (Review) |
| Archives next to their extracted folder | 2 | Already-Extracted Archives (Review) |
| `.crdownload`/`.part` > 1 day | 0 | Interrupted Downloads |
| Unavailable iOS simulators | n/a | "Remove Unavailable Simulators" task |
| AI tool history (`~/.claude/projects` 1 GB, `~/.codex/sessions` 0.8 GB) | mostly < 30 days | Not auto-cleaned (it's your history); visible in Storage Explorer |

**Hard links:** Google Drive's staging folder hard-links your files, so naive size tools count the same data twice (16.7 GB reported vs 9.1 GB real). Cleaner counts each hard-linked file once (like `du`), and gives the data to the visible folder rather than the hidden staging copy.

### Claude subscription instead of an API key
- Cleaner can run the user's **own** Claude Code CLI (`claude -p --output-format json --tools "" --strict-mcp-config --no-session-persistence`). The person's Claude Pro/Max login stays inside Claude Code: Cleaner never sees or stores it, and usage counts toward their plan. Tested: ~3–6 s per answer.
- Gemini CLI is supported the same way, for people with a Google account (not installed on the test Mac, so untested).
- ⚠️ **Distribution note:** Anthropic's docs say third-party products should not offer claude.ai (subscription) login unless Anthropic has approved it. Bridging to your own Claude Code on your own Mac is fine for personal use. If you ship Cleaner to other people, keep API keys as the default and check with Anthropic before advertising subscription support.

## 3. Feature list

### ✅ Built in v0.1 (this commit)
- **Smart Scan**: 18 rules across System Junk, Developer Junk, Backups/Downloads/Leftovers, and Trash. Each rule has a safety rating (Safe / Review / Caution); only Safe items are pre-selected.
- **Leftovers of removed apps**: finds orphaned containers, preferences and caches by bundle ID, with conservative vendor matching.
- **Large & Old Files**: size and age filters, app bundles measured as a whole, sortable table.
- **Space Lens**: drill-down folder sizes for your home folder, the whole disk, or any folder.
- **Uninstaller**: app plus leftovers across 20 Library locations, last-opened date, running-app detection.
- **Memory & Maintenance**: live memory breakdown, top processes with Quit, local Time Machine snapshots (list/delete/thin), free RAM (`purge`), flush DNS, rebuild Spotlight, rebuild Launch Services, reset Quick Look.
- **AI (bring your own key)**: Claude or Gemini. Each macOS user stores their own key in their own Keychain.
  - "Ask AI" on any file, folder, app or scan result
  - One-click **AI Review** of a whole scan or the largest-files list
  - **AI Assistant** chat that can attach live Mac context (disk, memory, last scan)
  - Fetch the model list from the provider, test the connection, switch providers live
- **Safety**: everything goes to the Trash by default, protected-path guard, user exclusion list, append-only history log.
- **Menu bar** mini monitor (disk and memory) with quick actions.
- **Full Disk Access** detection and guided setup.
- `Cleaner --scan` read-only CLI dry run.

### 🔜 Next (high value, low effort)
1. **Developer project scanner**: find `node_modules`, `.venv`, `target/`, `build/` and `Pods/` in projects untouched for N days.
2. **Docker & simulators**: `docker system df`/`prune` integration; `xcrun simctl delete unavailable`.
3. **Browser data**: per-browser cache, history and cookie cleanup (Safari, Chrome, Brave, Arc, Firefox, Edge) with a "browser must be closed" check.
4. **Duplicate finder**: size → partial hash → full SHA-256, with "keep newest/oldest" rules.
5. **Login items & launch agents manager**: list, disable, and AI-explain background items (a big speed win).
6. **Scheduled scans and low-disk alerts** from the menu bar ("Disk below 10%: 12 GB of caches available").
7. **Cleanup history UI with Undo** (restore from Trash using the history log).
8. **App icon and onboarding flow** (Full Disk Access → AI key → first scan).

### 🧠 AI roadmap (the differentiator)
1. **AI "What is System Data?" breakdown**: combine snapshots, caches, backups and VM swap into one explained chart.
2. **AI tool use / agent mode**: let the model call read-only tools (`measure_folder`, `list_dir`, `run_scan`) and *propose* a cleanup plan the user approves. Claude tool use and Gemini function calling both support this.
3. **Streaming responses** in chat (SSE for both APIs).
4. **More providers**: OpenAI-compatible endpoints (OpenAI, OpenRouter, Groq) and **local models via Ollama/LM Studio**, for fully offline privacy.
5. **Similar-photo grouping and screenshot cleanup** using vision models (opt-in, local first).
6. **Natural-language search**: "show videos over 1 GB I haven't opened this year".
7. **Per-item AI verdict cache** so the same folder isn't re-asked (saves the user's API cost).
8. **Token and cost meter** per provider.

### 🚀 Distribution
- Developer ID signing + notarization (needs an Apple Developer account, $99/yr) so users can open it without Gatekeeper warnings and Full Disk Access survives updates.
- Sparkle auto-updates.
- Cannot ship on the Mac App Store: the sandbox forbids system-wide cleaning. Direct download only, which is what CleanMyMac, DaisyDisk and OnyX do too.

## 4. Hard limits (be honest with users)
- **macOS system files** under `/System` are on a sealed, read-only volume protected by SIP. No cleaner can or should delete them. "System Data" is reduced by cleaning *what macOS files under that label* (snapshots, caches, logs, backups), which Cleaner does.
- **"Free up RAM"** gives temporary relief. macOS manages memory well, and quitting heavy apps matters more. The Memory screen shows which apps those are.
- Root-owned items in `/Library/Caches` and `/Library/Logs` may be skipped without admin rights.

## Sources
- [Cindori — Best Mac cleaner apps 2026](https://cindori.com/reviews/best-mac-cleaner-apps-2026)
- [Setapp — Best Mac cleaner software](https://setapp.com/how-to/best-mac-cleaner-software)
- [Mole — Best Mac cleaner apps, ranked by what being wrong costs](https://mole.fit/blog/best-mac-cleaner-apps.md)
- [Mole — AI Mac cleaners: what a model should and should not decide](https://mole.fit/blog/ai-mac-cleaner-tools.md)
- [Apple Community — Reducing massive System Data](https://discussions.apple.com/thread/256298936)
- [Apple Community — System Data huge after macOS Tahoe 26.2](https://discussions.apple.com/thread/256240535)
- [Dr.Buho — Mac System Data too large: 10 ways](https://www.drbuho.com/how-to/clear-system-storage-mac)
- [Gargantua on Product Hunt](https://www.producthunt.com/products/gargantua)
- [Indie Hackers — Mac storage cleaner using Gemini to explain deletions](https://www.indiehackers.com/post/i-built-a-mac-storage-cleaner-that-uses-gemini-ai-to-explain-what-its-deleting-1-99-0c13c2a3e7)
- [MacPaw — Introducing Smart Insights](https://macpaw.com/news/introducing-smart-insights)
- [Google — Gemini API reference](https://ai.google.dev/api)
