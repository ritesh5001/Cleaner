# Cleaner

A native macOS (SwiftUI) storage cleaner and optimizer with **bring-your-own AI**: each user connects their own Claude or Gemini API key.

See [docs/RESEARCH.md](docs/RESEARCH.md) for the market research and the full roadmap.

## Build & run

Requires macOS 14+ and either the Xcode Command Line Tools or Xcode.

```bash
./scripts/build-app.sh          # builds build/Cleaner.app
open build/Cleaner.app

swift run Cleaner               # quick dev run without bundling
swift run -c release Cleaner --scan   # read-only dry run, prints what Smart Scan finds
```

### First launch
1. **Full Disk Access**: System Settings → Privacy & Security → Full Disk Access → add `build/Cleaner.app`. Without it, macOS hides Mail, Safari, Trash, iOS backups and app containers.
2. **AI**: Settings → AI → paste a Claude key (console.anthropic.com) or a Gemini key (aistudio.google.com). Use *Fetch available models* to pick a model your key can use.

> Ad-hoc signed builds look like a new app to macOS after every rebuild, so Full Disk Access and the Keychain "Always Allow" prompt reappear. Build with `SIGN_ID="Apple Development: …" ./scripts/build-app.sh` to avoid this.

## Architecture

```
Sources/Cleaner/
  App/        CleanerApp (+ --scan CLI), AppState, RootView (sidebar)
  Core/       SafetyGuard · CleanupRules + RuleEvaluator · Cleaner (trash/delete + history)
              Apps (catalog, leftovers) · SystemInfo (disk, memory, FDA) · Utilities (sizes, shell)
  Features/   JunkScanner · LargeFileFinder · SpaceLensModel · UninstallerModel · MaintenanceModel
  AI/         AIClients (Claude, Gemini) · Keychain · AISettings/AIService · Prompts · AssistantModel
  Views/      one SwiftUI view per screen + shared components
```

**Safety model**
- `SafetyGuard.blockReason(for:)` is checked right before *every* deletion. Rules and AI can't override it.
- Items go to the Trash by default (except items already in the Trash).
- Every removal is appended to `~/Library/Application Support/Cleaner/history.log`.
- Admin tasks use the standard macOS password prompt and fixed, non-user-supplied commands.

**AI privacy**: only metadata (paths with `~` for home, sizes, dates, and optionally names inside a folder) is sent. File contents are never uploaded. All prompts are in `AI/Prompts.swift` so they're easy to audit.

### Note on `@Local`
The macOS 27 SDK implements SwiftUI's `@State` as a macro whose plugin only ships with full Xcode. Views use `@Local` (`Views/LocalState.swift`), a `@StateObject`-backed drop-in, so the app builds with the Command Line Tools alone.
