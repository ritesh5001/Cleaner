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
