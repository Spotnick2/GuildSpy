---
name: client-update
description: Handle a new WoW Forever client build for GuildSpy - find (or have AltStable produce) the new API dump in C:\Projects\WoW\References, diff it against the previous build for names this addon uses, and prepare the MEASURED_ON_BUILD bump PR. Use when the owner says there is a new build/API bump, "apidump done", "new api build", or a build newer than MEASURED_ON_BUILD shows up in C:\Projects\WoW\References.
version: 1.0.0
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob]
---

# A new Forever client build

Adapted from AltStable's `client-update` skill. **GuildSpy does not own the dump tooling**: the
dump addon and its converters live in `..\AltStable\Tools\ForeverAPIDump\`, and the converted dumps
are shared by every Forever project in `C:\Projects\WoW\References\forever-api-<version>.<build>.md`.

## Who does what

| Step | Who | What |
|---|---|---|
| 1. Dump | **owner**, in game | only if `C:\Projects\WoW\References` has no dump for the new build yet: deploy AltStable's dump addon, `/apidump`, `/reload` |
| 1. Convert | you | `pwsh ..\AltStable\Tools\ForeverAPIDump\Convert-Dump.ps1` (skip if the file already exists — another session may have done it) |
| 2. Diff | you | `pwsh ..\AltStable\Tools\ForeverAPIDump\Compare-Dumps.ps1` |
| 3. Check | you | grep this repo for every changed name |
| 4. Bump PR | you | edits, tests, branch, PR (commit/push only when asked) |

**Never delete old dumps**; that is the owner's call.

## 2–3. Diff and check

- The documented sections (functions, events, tables, **widget methods**, namespace functions) are
  the client. The `_G` walks pick up whatever addons were loaded — never a finding on their own.
- For every documented change, grep `*.lua` and `tests/` for the name. GuildSpy's surface is the
  guild API (`GetGuildRosterInfo`, `GetGuildRosterLastOnline`, `GetNumGuildMembers`,
  `GuildControlGetRankName`, `GetGuildEventInfo`, `C_GuildInfo.*`, `C_Club.*`), the `GUILD_*` and
  `CHAT_MSG_SYSTEM` events, the `ERR_GUILD_*` strings, and frames/fonts: a removed or re-signatured
  function we call is a bug to fix before the bump, not a note.
- **Re-measure the guild shapes:** ask the owner to run `/gspy probe` on the new build and
  `/reload`, then compare `GuildSpyDB.probe` with `docs/FOREVER-PROBE.md`. The legacy guild globals
  are in the dump by name only, so a changed tuple order shows up nowhere else.

## 4. The bump PR

Branch `build-<build>` from `main`:

1. `Compat.lua` — `GuildSpy.MEASURED_ON_BUILD = "<version>.<build>"`.
2. `AGENTS.md`, `.claude/skills/codex-consult/SKILL.md` — the dump file name they cite.
3. `tests/wow_stubs.lua` — the dump file name in the header, and `GetBuildInfo` if it is stubbed.
4. The event list the stub validates against: regenerate `tests/events-<build>.txt` from the new
   dump with `python ..\Gnomesweeper\Tools\make_events_fixture.py <dump.md>` (run from this repo).
   Point `EVENTS_FIXTURE` (`tests/wow_stubs.lua`) and the default dump path (`tests/test_toc.lua`)
   at the new build, and delete the old fixture.

Then `pwsh tests\run.ps1` green, `pwsh Tools\deploy.ps1`, a `/reload` in game, and `/gspy probe`.
Commit, push and open the PR (`Closes #N`) **only when the owner asks** — the owner runs every review.

Addon-agnostic findings about the new build go in `C:\Projects\WoW\References\PORTING-TBC-TO-FOREVER.md`,
not here.
