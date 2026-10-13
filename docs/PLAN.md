# GuildSpy — plan (final, after 4 Codex gpt-6-astra/high rounds)

Review trail: r1 found 6 P1s (completeness, identity, rank shifts, officer-note privacy, dedupe,
attribution) and said to cut sync. r2: ship with changes. r3/r4 closed the departure interval and
the RETURN evidence rule; the last precision condition is Codex's own wording.

## Context

Guild Roster Manager (GRM) knows everything that happens in a guild, but it is a 20k-line
management suite (bans, recommendations, calendar, macro tools, whispered leader-elected sync).
The owner wants only the **informational** half, on WoW Forever 1.60.1 (Interface 16001):

> who joined / left / was kicked, who was promoted / demoted, public + officer note edits,
> who levelled, who came back after a long absence, name changes — **live** when online,
> and as a **"while you were away" digest** at login.

Not a management tool: GuildSpy never writes to the roster. `C:\Projects\WoW\GuildSpy` is empty;
the repo is initialized from sibling conventions (AltStable / Gnomesweeper / Stakeout).

GuildSpy reports **observed changes**: the difference between two complete roster observations,
enriched by live system messages and the server's guild event log. It does not claim complete
history (a join→leave or a note edited twice between your logins collapses to the net change).

### Facts that shape the design

- **GRM's GUILD-channel traffic carries almost none of this.** Joins/leaves/promotions/notes/levels
  are never broadcast; GRM's bulk sync is WHISPER between an elected leader and one member. A
  passive listener on `GRM_SYNC`/GUILD only sees *manual* edits (`GRM_JD` join date, `GRM_PD`
  promo date, alt/main links, birthdays, custom notes) and `GRMUSER` announcements. So GuildSpy
  does its own diffing; GRM listening can only ever be a small extra.
- GRM's detection recipe, kept: GUILD_ROSTER_UPDATE + periodic `C_GuildInfo.GuildRoster()`; full
  snapshot matched **by GUID** (`GRM_ScanRoster.lua:938`); `CHAT_MSG_SYSTEM` parsed with patterns
  built from `ERR_GUILD_PROMOTE_SSS`/`DEMOTE_SSS`/`JOIN_S`/`LEAVE_S`/`REMOVE_SS`; the **guild event
  log** (`GetGuildEventInfo`, `GRM_ScanRoster.lua:4264`) to attribute offline changes and tell
  quit vs kick; rank-index shift handling (`GRM_ScanRoster.lua:1021`).
- Forever: no global `GuildRoster`/`CanViewOfficerNote` → `C_GuildInfo.*`. `GetGuildRosterInfo`
  exists but its **return shape is unmeasured**; `C_Club.GetMemberInfo` (guid, notes, lastOnline*,
  rank) is unverified. Names have a surname ("Kaleid Sumner"); guild realm (4th return of
  `GetGuildInfo`) can differ from the player's. SV persist since 70009 (verify by full exit).
  `SAVED_VARIABLES_TOO_LARGE` exists.

## Scope

**v1:** join, rejoin, left (quit / kicked-by / reason unknown), promote/demote (+officer when known),
rank structure change (rename/add/remove), public note, officer note (permission-gated), level-up,
name change, returned after N days, MOTD change. Live chat lines, one login digest, a log window.

**Deferred (decide after v1 is measured in a real guild):** GuildSpy↔GuildSpy enrichment, GRM
listener, LibAccountSync between own accounts. See "Deferred" below.

**Out:** anything that writes, bans, recommendations, calendar, birthdays, guild bank.

## Architecture

Pure logic separated from the WoW shell (Gnomesweeper's `Guild.lua`/`Social.lua` split).

| File | Role |
|---|---|
| `Compat.lua` | `GuildSpy.API`: roster row → named struct (the only place that knows tuple positions, explicit indices, never `#`), `C_GuildInfo` wrappers, `MEASURED_ON_BUILD`, `Fail()`. Never `_G`. |
| `Glass.lua` | `GuildSpy.Glass = LibStub("LibGlass-1.0"):New()` |
| `Roster.lua` | **pure**: `Snapshot(...)`, `Diff(old, new, opts) -> events[]`, rank reconciliation. |
| `Patterns.lua` | **pure**: patterns from localized `ERR_GUILD_*` (escape magic chars, anchor, `%s`/`%1$s` → `(.+)`); `ParseSystem(msg)`. |
| `EventLog.lua` | **pure** matcher over rows read by the shell: `{kind, p1, p2, rank, y, m, d, h}` → age interval. |
| `Scanner.lua` | shell: events, debounce, polling, completeness gate, pending list, calls Diff, feeds Log. |
| `Log.lua` | structured entries, caps/pruning, chat output, digest. Text rendered at display time. Observations, receiving and retention (#36, docs/SYNC.md). |
| `Wire.lua` | **pure**: sync messages as text (#37). |
| `AccountSync.lua` | sync between my accounts over LibAccountSync-1.0 (#37, docs/SYNC.md §4): a protocol core (two run side by side in tests) and the shell (library, scanner's guild, catch-up line). |
| `UI.lua` | Log window, styled like the roster (#19): "new" summary, New / Earlier, type tabs, time scope, rank filter (current rank, #23), name search, Mark all as read. A row's tooltip has the member's current notes (#25; the officer note only while readable). |
| `Options.lua` | Options > AddOns > GuildSpy and its About page (#4, Gnomesweeper recipe): login summary, level-up threshold, days away for "back", chat line per change type. `Options.Set` is the one place a setting changes; `Options.Validate` resets saved values no page could set. |
| `Minimap.lua` | Minimap button, addon compartment and key binding (#5): LDB + LibDBIcon (vendored like Gnomesweeper), `AddonCompartmentFunc*`, `Bindings.xml` (Key Bindings > GuildSpy). Left-click the log, right-click the settings; the tooltip has the guild, who's online and what's new. |
| `GuildSpy.lua` | init, SV validation/migration, slash `/guildspy` `/gspy` (`help`,`log`,`scan`,`probe`). |

### Identity

- Guild key = `guildName .. "-" .. guildRealm`; no work until both are non-empty; pending work is
  dropped on `PLAYER_GUILD_UPDATE` (left / changed guild).
- Member key = **GUID**. The probe must confirm `GetGuildRosterInfo` (or `C_Club`) returns it for
  every row, offline included. If it doesn't, stop and re-plan (no name-keyed fallback mode).
  Same GUID + new name = NAME; same name + new GUID = different character.

### Scan pipeline

1. Login: load + validate SV; request `C_GuildInfo.GuildRoster()` after ~5 s. Poll every 60 s while in a guild (levels, notes
   fire no message) + `QueryGuildEventLog()` on the same cadence. `GUILD_ROSTER_UPDATE` debounced 2 s.
2. **Completeness gate** (replaces GRM's 50% heuristic): rows enumerated == `GetNumGuildMembers()`
   total (show-offline behaviour measured by the probe; force it on if needed and restore), every
   row has GUID+name+rank, GUIDs unique, rank table loaded. An incomplete scan is discarded.
   **Recovery**: after 5 consecutive incomplete scans, print one warning; `/gspy rebaseline` drops
   the guild's snapshot (log kept) so the next complete scan is a silent baseline.
3. **Departures need two complete scans**: a GUID missing from one complete scan **keeps its member
   record** in the snapshot, flagged `missingSince` and `missingAfter` (the observation before it
   vanished). The LEAVE's attribution interval is `(missingAfter, missingSince]`. Still missing in the next complete scan
   ≥ 30 s later → LEAVE (from the retained record) and move to `formers`. Reappears → flag cleared
   silently, no JOIN/REJOIN. (All other changes are emitted on the first complete scan.)
4. **First complete observation of a guild = baseline only.** No events.
5. **Rank reconciliation first**: compare rank lists (count + names by index). If the structure
   changed, emit one RANKS_CHANGED, map old→new by name where unambiguous, and only report a member
   PROMOTE/DEMOTE when the mapped rank differs **and** a system message or event-log entry confirms
   it; otherwise suppress. Lower index = higher rank (verify in probe).
6. Diff events: JOIN / REJOIN (GUID in `formers`; after pruning, "joined" makes no first-time claim),
   LEAVE, PROMOTE/DEMOTE, NOTE, ONOTE, LEVEL (`new > old` and (`new ≥ minLevel` or a multiple of 10
   crossed in `(old, new]`)), NAME, RETURN, MOTD. A net rank change is reported as "from A to C";
   when evidence only covers the last step it's labelled "last step by X" (no transition rebuilding).
7. **Officer notes**: per member `onote` + guild `onoteBaselineAt`, only updated when
   `C_GuildInfo.CanViewOfficerNote()` is true now. Unreadable ≠ empty: a non-officer alt neither
   updates nor clears the baseline. First readable observation seeds silently. ONOTE log entries
   are hidden (chat, digest, window, search) whenever the current character cannot view officer notes.
8. **RETURN** (needs positive proof of inactivity): each member stores an absolute
   `lastSeenAt` (= observedAt if online, else observedAt − lastOnline; day precision is enough,
   validated in phase 0). Emit RETURN only when the **previous** snapshot already showed the
   member inactive for ≥ N days at that observation (`prevObservedAt − old.lastSeenAt ≥ N`, default
   14) and this scan shows **real activity**: the member is observed online, or the new
   `lastSeenAt` is newer than the old one by more than the measured precision of last-online (a
   change inside the rounding is not a login). Report "back after at least X days", where X is
   that proven lower bound. If our own observation gap leaves inactivity unknown, nothing is
   reported. It fires once because `lastSeenAt` moves on.

### Attribution

Every diff event has an **observation interval** `(previous complete scan, this scan]`. All
matching uses that interval, and it must be **unique**; if it's ambiguous, there's no actor.

- **Live**: `CHAT_MSG_SYSTEM` → ParseSystem → ephemeral **pending list**
  `{at, kind, targetName, actorName, toRank}` (≤ 50, 10 min TTL). A diff event takes the actor and
  exact time from the single pending entry with the same target + kind (+ destination rank) whose
  `at` is inside its interval. A message arriving after the diff that already recorded the event
  goes through the enrichment rule below. Otherwise unmatched entries just expire, because the diff
  is the source of truth.
- **Server log**: when `GUILD_EVENT_LOG_UPDATE` arrives, match by kind + target + destination rank +
  age interval overlapping the event's observation interval. LEAVE without a unique `quit`/`remove`
  match = "left (reason unknown)", never "quit".
- **Enrichment, no duplicates**: log entries recorded this session without an actor stay
  enrichable for 10 min. Later evidence (log refresh or late message) fills `actor`/`approx`/
  `left reason` **in place**. That updates the window but prints no new chat line.

### Login digest

- The boundary is a **sequence number, per guild and account-wide** (`guild.shownSeq`). The digest
  shows log entries with `seq > shownSeq`, then advances it. Alt switches and `/reload` show only
  what nobody on the account has been shown yet. Time-based matching uses `guild.observedAt`
  (the last complete scan), never a logout time.
- **Digest timing**: wait for the session's first complete scan, plus the departure-confirmation
  scan if any GUIDs went missing, plus the first event-log refresh. Cap the wait at 90 s, then print
  whatever is settled and mark anything unresolved as "pending". Those resolve later as live lines.
- The block itself: one summary (`GuildSpy — since 3d 4h ago: 2 joined,
  1 left, 3 promoted, 5 levelled… [open log]`, clickable `|Haddon:guildspy|h` link) + up to 8 detail
  lines prioritized (membership > rank > notes > levels). No per-event spam for catch-up. Events
  arriving live after that print one line each (per-type toggles, GRM-like colors).
- Log entries carry a monotonic `seq`; the window's "new" marker uses the seq, not event time.

### Storage (`GuildSpyDB`, account-wide; versioned, named fields)

```
GuildSpyDB = { version=1, minimap={},
  accountSync={...},   -- (#37) LibAccountSync's own store (household key, peers): never edit or copy
  settings={ digest=false|nil, levelMin=n|nil, returnDays=n|nil,   -- nil: the default (on, 10, 14)
             capSound=false|nil, syncAccounts=false|nil,           -- (#34, #37) nil: on
             chat={ [kind]=false } },                               -- a kind's chat line off (#4)
  nextSeq=1, window={ x, y },
  guilds = { [guildKey] = { observedAt=epoch, shownSeq=n, onoteBaselineAt=epoch|nil,
    viewedSeq=n,   -- the log window's "new" marker (#3): the last seq seen there
    ranks = { "Guild Master", ... }, motd = "...",
    members = { [guid] = { name, rank, level, class, note, onote, online, lastSeenAt, missingSince, missingAfter } },
    formers = { [guid] = { name, leftAt, rankName, level } },
    nextChg=n,     -- (#36) this client's change counter (never below the clock in ms): account sync pages by it
    peerMark = { [peerGuid] = n },   -- (#37) per account of mine: its counter I have up to
    log = { { seq, at, approx=bool|nil, kind, guid, name, actor, from, to,
              after=epoch|nil,   -- (#19) the previous scan: a scan-noticed change is in (after, at]
              -- (#36) the observation, docs/SYNC.md §1:
              uid, lo, hi, obs, origin, trust="self"|"guild", here=bool, rev, chg,
              ns="g:<reporter>"|nil, reporter },
            ... } } } }
```
Caps are enforced **on append** (plus a sweep at login): log ≤ 1500 entries and ≤ 180 days per
guild for my accounts' observations, and ≤ 500 / 60 days for guildmates' reports, each kept in
retention order (observed time, namespace, uid; docs/SYNC.md §7); formers ≤ 500 and ≤ 365 days; at most 5 guilds, dropping the least recently observed; note
strings are already bounded by the game. Shape is validated on load, and an unreadable guild table
is reset to "baseline needed". No per-character SV.

## Phases (each a PR)

0. **Repo init + probe.** `/gspy probe` dumps (explicit indices, nil-safe): full
   `GetGuildRosterInfo(i)` tuple for a few online+offline rows, `GetGuildRosterLastOnline`,
   `GetNumGuildMembers` vs show-offline, `C_Club.GetGuildClubId`/`GetMemberInfo`,
   `CanViewOfficerNote`, rank names/indices, the full `GetGuildEventInfo` tuple for 10 entries,
   the `ERR_GUILD_*` globals, and every guild `CHAT_MSG_SYSTEM` text seen this session. Results →
   `docs/FOREVER-PROBE.md`. Nothing persisted until shapes are measured.
1. **Core**: Compat, Roster/Patterns/EventLog (pure, tested), Scanner, Log, chat output, digest, slash.
2. **UI**: log window, options, minimap/compartment.

## Deferred (not on the roadmap until v1 is measured)

- **Sync with guildmates and between my accounts:** no longer deferred. v1 was measured in a real
  guild, and the owner asked for both (2026-10-12). The design is **docs/SYNC.md** (three Codex
  rounds), built in phases #36, #37, #38.
- **GRM listener.** Passive `GRM_SYNC`/GUILD only yields manual join/promo dates and alt links,
  incomplete (removals, rank-restricted senders: `GRM_GuildSync.lua:8300`) and a protocol to track.
  Cheaper variant if wanted: read GRM's "Joined: <date>" text out of public notes.

## Repo init (mirrors siblings)

- `GuildSpy.toc` (16001, `@project-version@`, `SavedVariables: GuildSpyDB`, `AddonCompartmentFunc`,
  LibGlass XML first), MIT `LICENSE` (Spotnick), `README.md`, `CHANGELOG.md` (`## Unreleased`),
  `.pkgmeta` (LibGlass external pinned `r5`, LibGlass dev-file ignores, no inline YAML comments),
  `.gitignore` (`Libs/LibGlass-1.0/`, `.claude/settings.local.json`, `.release/`, `*.zip`),
  `.gitattributes`.
- Vendored `Libs/`: LibStub, CallbackHandler, LibDataBroker, LibDBIcon (copied from Gnomesweeper).
  No ChatThrottleLib until a comms feature exists.
- `.github/workflows/package-check.yml` from Gnomesweeper, renamed + expected file list.
- `Tools/deploy.ps1`, `Tools/LibGlassPin.ps1` from Gnomesweeper/GlassChat.
- `tests/`: `run.ps1`, `harness.lua`, `wow_stubs.lua` (+ guild stubs: roster rows, event log,
  system messages, CanViewOfficerNote), `events-1.60.1.70338.txt`, `fetch_libglass.sh`,
  `test_toc.lua`, `test_roster.lua`, `test_patterns.lua`, `test_eventlog.lua`, `test_scanner.lua`.
  Fixtures: partial login roster, show-offline off, officer→alt→officer, rank insert/rename,
  delayed event log, repeated actions, guild switch, surname names, pattern magic characters.
- **Agent instructions like the siblings**: `AGENTS.md` (generic AltStable sections: platform,
  validation, testing rules, deploy loop, release, conventions, git, model tiers, review policy via
  `$wow-addon-review`, `MEASURED_ON_BUILD`) + GuildSpy specifics; `CLAUDE.md` overlay (Opus default,
  adversarial review via `/codex-consult` → Fable fallback, and the things a cold reviewer must not
  override: GUID identity, completeness gate, officer-note privacy, SV shape).
- **Skills** `.claude/skills/codex-consult` (copy) and `.claude/skills/client-update` (adapted
  from Gnomesweeper's); `.claude/settings.json` allowlist like siblings.
- `docs/PLAN.md` (this plan), `docs/FOREVER-PROBE.md`.
- `git init` on `main`, initial scaffold commit, then work on branches. GitHub repo only when asked.

### Phase 0 as built (deviations from the list above)

- No vendored `Libs/` yet: LibStub comes with LibGlass, and LibDataBroker/LibDBIcon/CallbackHandler
  arrive with `Minimap.lua` in phase 2 (unloaded files shouldn't ship). They did, in #5.
- No `Tools/LibGlassPin.ps1` and no `.claude/settings.json`: Gnomesweeper reads the pin inline in
  `deploy.ps1`/`run.ps1`, and no sibling commits a settings file.
- Tests are `test_toc.lua` and `test_probe.lua`; the Roster/Patterns/EventLog/Scanner tests and their
  fixtures come with phase 1's files.

### Phase 1 as built (reviewed by Codex, gpt-6-astra high)

The review raised 11 findings and 9 were fixed:
- officer-note permission is checked at display time;
- missing members keep their rank by name across a structure change;
- RETURN uses the member's own last observation;
- live multi-step promotions are marked "last step";
- ambiguous live evidence blocks the log fallback;
- the interval is strictly `(lo, hi + 10 s]`, and a message is used up once it has explained an event;
- saved records are validated;
- each guild session has its own digest deadline;
- caps hold mid-session.

Two were declined, deliberately:
- **A live leave/kick message confirms a departure on the first missing scan.** The two-scan rule
  guards against a roster that looks short. A server message saying the member left is proof on
  its own, and waiting made kicks show 30 s late. The completeness gate still applies.
- **The guild key falls back to the player's realm when `GetGuildInfo` gives no guild realm.** On
  Retail that return is empty for a guild on the player's own realm, so refusing would never track
  such guilds. The measured guild (connected realms) returns its realm. If a same-realm guild ever
  shows both keys, revisit.

## Other ideas (not v1)

GRM-derived: "in guild since" / "at this rank since" in roster tooltips (from our own observations);
rejoin details ("left 3 months ago as Officer"); read-only inactivity list; anniversaries.
New: member-count / online-count history; guild-info text change; "X is online for the first time
in 30 days" toast; export log to a copy box.

## Verification

- `pwsh tests/run.ps1` green, with targeted fixtures for each gate/diff rule.
- In game (`pwsh Tools/deploy.ps1`, `/console scriptErrors 1`, full restart): `/gspy probe`;
  officer promotes/edits note live → line with actor; log out, change something from another
  account, log in → one digest with attribution; non-officer alt → no officer-note noise or
  visibility, back to officer → no false ONOTE; `/reload` → no replay; full exit → persisted.

## Name

**GuildSpy** — owner's decision (DebuffSpy family). Sync and the GRM listener are deferred, also by
the owner's decision.
