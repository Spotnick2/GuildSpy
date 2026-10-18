# AGENTS.md — Shared Context for Agents

Shared baseline for any agent working in this repo (Claude Code, Codex, Copilot all read
`AGENTS.md`). Keep durable project rules here. `CLAUDE.md` is a Claude-specific overlay —
this file is the source of truth; where the two overlap, this one wins.

## Review policy

Use `$wow-addon-review` as the shared source of truth for review routing, committed-diff scope,
client/API evidence handling, validation, finding format, and merge-readiness verdicts.

Repository-specific additions:

- Post every pull-request review and follow-up review on the PR, then link the posted review in the
  final response.
- Match `MEASURED_ON_BUILD` in `Compat.lua` to
  `C:\Projects\WoW\References\Forever\api\forever-api-<version>.<build>.md`. Runtime measurements live in
  `docs/FOREVER-PROBE.md`; addon-agnostic Forever findings live in the canonical
  `C:\Projects\WoW\References\Docs\PORTING-TBC-TO-FOREVER.md`.
- For an adversarial second opinion on a plan or a risky diff, use `/codex-consult`
  (`.claude/skills/codex-consult`).

## What this project is

GuildSpy is a **World of Warcraft: Forever addon** (Interface `16001`, **Lua 5.1**) that tells you
what happens in your guild: who joined, left or was kicked, who was promoted or demoted, public and
officer note edits, level-ups, name changes, who came back after a long absence. **Live** while
you're online, and as one **"while you were away" digest** at login.

It keeps only the *informational* half of Guild Roster Manager
(`C:\Projects\WoW\References\Addons\Guild\GuildRosterManager`). **It is not a management tool: it
never writes to the roster** (no notes, ranks, invites, kicks, bans). The design, decided with the
owner and reviewed adversarially (Codex, four rounds), is `docs/PLAN.md`. Read it before changing
detection, attribution, the digest or the saved shape.

Forever runs Vanilla content on Blizzard's **Mainline (Retail) codebase**: content assumptions are
Vanilla, API assumptions are Retail. Read `C:\Projects\WoW\References\Docs\PORTING-TBC-TO-FOREVER.md`
before touching an unfamiliar API.

- **Namespace:** one global table `GuildSpy`; every file starts `local ADDON = ...` /
  `GuildSpy = GuildSpy or {}`.
- **SavedVariables:** `GuildSpyDB`, account-wide (so alts in the same guild share one baseline).
  Its shape is in `docs/PLAN.md` "Storage". Once released, the shape is a contract: add fields,
  don't repurpose them. Verify persistence with a **full client exit**, never a `/reload`.
- **Status:** phase 1 (detection, log, chat lines, digest) and the log window (#3). Phase 2 still
  adds the options page and the minimap button. The guild API shapes are measured:
  `docs/FOREVER-PROBE.md`.

## Layout

TOC load order: `Libs\LibGlass-1.0\LibGlass-1.0.xml` → `Libs\LibAccountSync-1.0\LibAccountSync-1.0.xml`
(a `.pkgmeta` external like LibGlass, gitignored; deployed by `..\LibAccountSync\Tools\deploy.ps1`;
the tests answer `LibStub("LibAccountSync-1.0")` with a scripted fake) → the vendored `Libs\` (LibStub,
CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0, copied from Gnomesweeper; the tests load
recording fakes instead) → `Compat.lua` → `Glass.lua` → `Roster.lua` → `Patterns.lua` →
`EventLog.lua` → `Log.lua` → `Wire.lua` → `Scanner.lua` → `AccountSync.lua` → `GuildSync.lua` → `Professions.lua` → `UI.lua` → `Options.lua` → `Minimap.lua` →
`Probe.lua` → `ProbeProfessions.lua` → `GuildSpy.lua`. `Bindings.xml` isn't in the TOC: the
client finds it by name (the package check names it).

- **`Compat.lua`**: `GuildSpy.API`, the only route to client APIs that moved or may be absent, and
  `MEASURED_ON_BUILD`. **The only place that will know a guild tuple's positions.** Nothing is
  injected into `_G`.
- **`Glass.lua`**: `GuildSpy.Glass = LibStub("LibGlass-1.0"):New()`, this addon's instance of the
  embedded glass material (`Libs\LibGlass-1.0`, a `.pkgmeta` external, gitignored). Material changes
  are LibGlass PRs. `Glass.MEDIA` is the library's, never our own art.
- **`Probe.lua`**: phase 0's measurements, for measuring only. `/gspy probe` dumps the roster tuple
  (finding the GUID by looking), last-online, ranks, `C_Club`, the event log and the `ERR_GUILD_*`
  strings into `GuildSpyDB.probe`; a login timeline of roster completeness is always kept in
  `GuildSpyDB.probeLog`; `/gspy probe watch` also records every system message.
- **Pure files** use **no WoW API**; tests load them with every global forbidden (`newPureEnv` in
  `tests/harness.lua`):
  - `Roster.lua`: `Roster.Apply(state, scan, now, opts)`, the diff. It updates one guild's saved
    state in place and returns events `{ kind, guid, name, from, to, lo, hi }`.
  - `Patterns.lua`: system message → `{ kind, actor, target, rank }`, built from the client's
    `ERR_GUILD_*` strings.
  - `EventLog.lua`: `Attribute(ev, pending, entries, now)` attaches an actor only from a unique
    match in the interval.
- **`Log.lua`**: entries (stored as data, rendered at display), caps on append, chat lines, and
  the digest.
- **`Scanner.lua`**: the shell. It handles events and debounces, polls every 60 s, applies the
  completeness gate (`API.ReadRoster`), keeps the pending live messages, reads the event log once
  its burst settles, enriches entries in place, and times the digest.
- **`UI.lua`**: the log window (#3): one panel in two hosts, a GuildSpy side tab in Blizzard's guild
  window and a standalone glass window. **It never opens, toggles or writes a field of Blizzard's
  window** (a Forever taint trap); only `hooksecurefunc`, `HookScript`, `SetChecked` on its tabs, and
  child frames of our own. `tests/test_ui.lua` fails on any field write. Its look (#19) uses the
  roster's own art and Blizzard templates checked in `wow-ui-source`; a template the client lacks
  (`DoesTemplateExist`) falls back to `UIPanelButtonTemplate`.
- **`ProbeProfessions.lua`**: measuring only. It records whether the server serves guild
  professions and recipes (it serves names only: `docs/FOREVER-PROBE.md`).
- `tests/` — Lua 5.1 unit tests. `Tools/deploy.ps1` — dev deploy. `docs/` — plan and measurements.
  None of them ship (`.pkgmeta`).

## Design rules that a cold reviewer must not override

From `docs/PLAN.md`; each one closed a real failure in review.

- **Members are keyed by GUID**, never by name. Same GUID + new name = a name change; same name +
  new GUID = another character. If the probe shows no GUID for every row, stop and re-plan.
- **Only a complete roster is diffed** (rows == total, every row with GUID+name+rank, GUIDs unique,
  ranks loaded). A departure needs **two** complete scans; the first complete observation of a
  guild is a silent baseline.
- **Officer notes**: unreadable is not empty. A character that can't view them neither updates nor
  clears the baseline, and never sees officer-note entries in chat, digest, window or search.
- **Attribution is conservative**: an actor or time is attached only from a unique match inside the
  event's observation interval; ambiguity means no actor. A leave without a matching quit/kick is
  "left (reason unknown)", never "quit".
- **The digest boundary is a log sequence number**, per guild and account-wide; time matching uses
  the last complete scan, never a logout time.
- **Names have surnames** ("Kaleid Sumner"): system-message patterns capture with `(.+)`, never
  `(%S+)`, and are built from the client's localized `ERR_GUILD_*` globals.

## Build & validate

No build step. The Lua 5.1 toolchain is at `C:\Program Files (x86)\Lua\5.1\` (`lua.exe`, `luac.exe`).

- `pwsh tests/run.ps1` — `luac -p` on every TOC file, then every `tests/test_*.lua`. Must be green
  before every commit. It needs a **LibGlass checkout** (`$env:LIBGLASS`, else `..\LibGlass`) and
  warns when it's not at the `.pkgmeta` pin.

## Testing

- `tests/wow_stubs.lua` is an **allowlist model of the Forever client**, driven through the global
  `WoW` table: globals are strict (reading an unstubbed one errors), and `RegisterEvent` throws on an
  event missing from `tests/events-1.60.1.70338.txt` (checked against the dump by `test_toc`).
- **The stubs must model Forever, not Classic or Retail.** Before stubbing a global, confirm it's in
  the API dump. The guild tuple shapes in the stub are **measured on 70338**
  (`docs/FOREVER-PROBE.md`); keep them matched to it on every new measurement or build.
- `tests/harness.lua`: `check`, `eq`, `done`, `tocFiles`, `loadAddon({ db, setup })`, `newPureEnv`.
  Internals are reached through `GuildSpy._test`.
- Add a test as `tests/test_<area>.lua`; `run.ps1` picks it up. Prove a new test bites: break the
  behaviour and watch it go red.

## Deploying for in-game testing

```
pwsh Tools/deploy.ps1
pwsh Tools/deploy.ps1 -AddOnsPath "D:\...\_classic_beta_\Interface\AddOns"
```

Deploys LibGlass from its checkout first (its own `Tools\deploy.ps1`), then the addon, with
`@project-version@` rewritten to `dev` in the deployed copy only. **Never commit a literal version
over that keyword.** In game: `/console scriptErrors 1`. A new file or a TOC change needs a client
restart (the script says so); otherwise `/reload`.

## Releasing

CurseForge's packager builds from the tag webhook, reading `.pkgmeta`; no API key lives here.
`git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`. Every tag needs a player-facing
`CHANGELOG.md` section (`## vX.Y.Z`). The same version is also a **GitHub release** (TimeIsMoney's
model): run the package check on the tag (`gh workflow run package-check.yml --ref vX.Y.Z`),
download its `guildspy-package` artifact (`GuildSpy-vX.Y.Z.zip`), then
`gh release create vX.Y.Z <zip> --title "GuildSpy X.Y.Z" --notes-file <notes>`, the notes being
that version's changelog section. `.github/workflows/package-check.yml` dry-runs the BigWigs
packager on PRs and `main` and checks the zip's shape. Check the published zip by hand afterwards.

## Conventions

- **Right-size for a single maintainer.** Prefer the simplest thing that works. No speculative
  config, no edge-case handling nobody asked for. The GRM listener is **deferred** by the owner's
  decision (`docs/PLAN.md` "Deferred"). Sync is designed in `docs/SYNC.md`: its principles
  (observations never rewritten by another observer, provenance bound to the transport, digest
  about this account's own scans, deterministic retention) are rules, as the design rules above.
- **Match the surrounding code**; lift helpers from the siblings (`..\Gnomesweeper`, `..\AltStable`,
  `..\GlassPanel` `Compat.lua`) instead of rewriting them.
- **Boy-Scout, bounded.** Small cleanups only in files you're already editing; refactors in their
  own commit.
- **Propose, don't expand.** Mention out-of-scope work instead of doing it.
- **Measured beats reasoned.** If a claim about the client can be checked in game, check it.
- **Never `StaticPopup`** (taint); never reassign Blizzard globals (`SlashCmdList.X = fn`, never
  `SlashCmdList = SlashCmdList or {}`).

## Git conventions

- **Every change goes through an issue and a pull request, always** (owner's decision):
  issue → branch → PR (`Closes #N`) → review posted on the PR (routed by `$wow-addon-review`;
  Codex, or Fable when Codex is unavailable) → the owner merges. **The owner runs the PR
  review**; the agent that opened the PR never starts one itself, and addresses what is posted.
  `docs/WORKFLOW.md` has the loop, stacked PRs, and the review recipe. Repo:
  `github.com/Spotnick2/GuildSpy` (public). CurseForge project 1741939,
  `https://www.curseforge.com/wow/addons/guildspy`.
- Branch off `main`, named for the work (`phase2/log-window`). Never commit directly to `main` (the
  initial scaffold was the one exception). Commit and push only as part of that loop.
- Short imperative subject; body only if it adds something; end with the `Co-Authored-By:` trailer
  for the model that did the work.

## Cost control & model usage

- Prefer inline tools over subagents; at most ~2 subagents per turn. Compact after heavy work.
- *Haiku:* searches, deploys, rote edits. *Sonnet:* routine implementation and tests.
  *Opus:* the diff/attribution logic, the saved shape, adapter semantics, hard debugging.
