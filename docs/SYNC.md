# GuildSpy sync: design (v0.5, after Codex rounds 1–3)

Owner's goal (2026-10-12, after v0.1.0 shipped and was tested in game): "sync between my accounts
and with other users from the guild". Replaces docs/PLAN.md "Deferred" once agreed.

- Round 1 rejected v0.2's destructive merge (destination-only facts with a 36 h window, a
  "covered" rule dropping local changes, skipped partial batches, guild claims written into trusted
  fields, imports evicting local history, late imports behind the digest boundary).
- Round 2 found v0.3 "substantially safer" and left: UID ownership (a guildmate could forge a
  higher rev of my uid), a time-based cursor that can skip same-tick changes, retention churn
  between accounts, grouping that hides transitions, and an overstated one-responder bound.
- Round 3: "v0.4 is good enough to start the no-transport phase-1 PR", with P2 corrections folded
  in below (retention tie-break, canonical text, forwarded namespaces, supersession order,
  non-backfill stated), one P1 for phase 3 (messages already queued in ChatThrottleLib), and an
  optional cut taken: no gap ledger, a bounded recent-history request instead.

## Principles

1. **Observations are never destroyed or rewritten by anyone but their observer.** Each entry is
   one observer's observation, kept as recorded, with its provenance. Sync adds observations.
2. **Provenance is bound to the transport,** never to the payload: own accounts by LibAccountSync's
   proof, guildmates by the GUILD sender name.
3. **The digest and live chat stay about this account's own scans.** Imported observations reach
   the player through the window and one batched catch-up line.
4. **Retention is deterministic** (by observation time and uid, never by arrival), with a separate
   quota for guild reports.
5. **Guild exchange is best effort,** and says so. Account sync is complete (paged, resumable).

## 1. Entry fields (additive; docs/PLAN.md "Storage" updated)

- `uid` = `<writer>:<n>`, writer a random per-session token (never stored), n a counter. Given
  once to entries that lack one, then permanent. A uid is **not** a credential (§2).
- `lo`, `hi`: the diff event's observation interval (`ev.lo`, `ev.hi`), stored as is from now on.
- `obs`: the **immutable observed time** for ordering and retention: `hi` (or the exact `at`
  when the observer had one at creation), fixed at creation; enriching `at` never moves it.
- `origin`: the observing character ("First Surname"); `nil` for legacy entries (§8).
- `trust`: `"self"` (observed by one of my accounts) or `"guild"`. Never taken from a payload.
- `here`: true when observed by **this** account (created by this client's scans). Receiver-local:
  never sent, never set on receipt. The digest, live chat and guild export use `here`.
- `rev`: bumped by the observer when it enriches its own entry (actor, approx, how, lastStep, at).
- `chg`: this client's **persisted, strictly increasing change counter** (`gs.nextChg`), set on
  creation, admission and every accepted revision. The account-sync cursor. Wall time stays for
  display and retention only.
- `reporter` (guild entries): the GUILD sender who sent it to us; key for its identity (§2).

## 2. Receiving (pure: Log.Receive)

Identity is `(namespace, uid)`: namespace `"self"` for observations by my accounts, `"g:" ..
reporter` for a guildmate's. A guild report **forwarded by my other account keeps `g:<reporter>`**
(the namespace travels with the entry; LibAccountSync only proves which of my accounts relayed
it). Two namespaces never alias each other.

- **Supersession runs first:** a self record arriving by account for a uid held as a guild record
  with the same `origin` replaces it whatever the revisions, inherits nothing from it, and keeps
  this client's `here`.
- **Account copy** (authenticated own account): unknown → admit (trust `self`, its `origin`).
  Known self uid with higher `rev` → replace its mutable fields. A known **guild** record with the
  same uid whose `origin` matches is superseded by the account copy (the authenticated path wins;
  the guild copy is dropped). Guild-origin entries carried by an account copy keep `trust =
  "guild"` and their `reporter`.
- **Guild copy:** accepted only if its `origin` equals the transport sender (a guildmate reports
  only what that character saw, §5). It lives in namespace `g:<sender>`: it can never touch a self
  entry or another reporter's. Higher `rev` replaces only that reporter's own record. If a self
  entry with the same uid exists, the guild copy is ignored.
- Equal or lower `rev`: ignored, `chg` unchanged, not counted as new.
- Admission is checked against retention (§7) **before** a seq or chg is allocated.
- **Text is stored canonical:** validated, unescaped. Display escaping (`|` doubled) happens at
  every rendering boundary (chat, rows, tooltips), never in storage, so forwarding never changes it.

## 3. The window (phase 1: no grouping)

- One row per observation. Guildmates' reports also have their own **Reports** tab (and show
  under All, unless the setting says Never). A row not observed by me (`trust == "guild"`) shows a
  small "reported" mark; its tooltip says "Reported by Ann Lee" and gives its interval or exact time and its own
  actor as that reporter's claim. Self rows from my other accounts say "Seen on <origin>".
- `/gspy log <n>` prints provenance too ("(reported by Ann Lee)").
- New markers, search (also on reporter/origin), filters and time scope work per row as today.
- Grouping likely duplicates is **deferred**. If ever added: only with a common intersection of
  intervals, never across a recorded intervening reversal, ambiguous matches left apart, presented
  as "possibly the same change".

## 4. Account sync (LibAccountSync, complete)

- **Embedded in GuildSpy's own `Libs\LibAccountSync-1.0`** (owner, 2026-10-12): no separate
  addon (no AltStableSyncLink-style plugin). A `.pkgmeta` external pinned `r5` with its ignore
  list, gitignored like LibGlass, deployed by `..\LibAccountSync\Tools\deploy.ps1 -Addon GuildSpy`
  from `Tools/deploy.ps1`; its TOC line before our files; tests load the real library
  (`..\LibAccountSync`; CI fetches the pin). One instance, tag `GuildSpy`, `messages = true` (else
  disabled). Store `GuildSpyDB.accountSync`, in GuildSpy's own saved variables (GuildSpy has no
  file-transfer feature, so AltStableSync's separate-SV reason doesn't apply).
- **Capability:** `CAP|1` to every `Peers()` entry on each discovery pass (login, peer change,
  every 5 min) until answered; forgotten when the peer leaves.
- **Pull by change counter, one page in flight per peer and guild:**
  `REQ|<rid>|<guildKey>|<cursor>` → `PAGE|<rid>|<guildKey>|<cursor>|<next>|<more>` + entries with
  `chg > cursor` in chg order, one library payload ≤ 12 KB encoded. The requester accepts a PAGE
  only for its outstanding `rid` and matching `cursor`, stores `next` only after the whole page,
  then asks again if `more`. Timeout 30 s → same request again. An empty page returns `next`.
- **Polling:** a pull per capable peer at login +10 s, when it appears, and every 5 min.
- Shared: every entry, officer notes included (display stays gated by `CanViewOfficerNote()`
  everywhere: Log.Visible, MemberNotes, tooltips, search, counts). Guild-origin entries too,
  keeping `trust = "guild"` and `reporter`. No read-state sync.

## 5. Guild sync (GUILD addon messages, best effort)

- Prefix `GuildSpy`, GUILD only, ChatThrottleLib v32 vendored (Gnomesweeper's), one priority;
  never WHISPER; no relaying.
- **Sent:** only entries with `here` and `origin` = **the sending character** (transport identity
  proves only that), public kinds: JOIN, REJOIN, LEAVE, PROMOTE, DEMOTE, RANK, NAME, NOTE, LEVEL,
  RETURN. Never ONOTE, MOTD, RANKS, legacy entries (no origin) or imports. Fixed per-kind wire
  projection; an entry encoding to > 250 B is not sent.
- **Ask (no gap ledger, round-3 cut):** `Q|1|<qid>|<since>` for the last 14 days (`since` =
  now − 14 d, or my oldest entry if newer), qid unique (writer token + counter). Sent after the
  first complete scan, and as a **directed** `Q|1|<qid>|<since>|<responder>` when a peer's `H`
  (hello, once per session after its first scan) shows someone who hasn't answered this session.
  At most one Q per 2 min. Repeats are absorbed by `(namespace, uid)`/`rev`. Best effort: what's
  received is what online peers saw.
- **Answer:** a peer with matching entries waits 2–8 s jitter, sends `A|1|<qid>`, then entries
  `E|1|<qid>|...` **in batches of 5**, checking before each batch whether another `A` for that qid
  arrived (then it stops; on simultaneous `A`s the alphabetically first responder continues, the
  other stops). An answer cut off this way is incomplete; the requester tracks each responder's
  continuation separately and may ask that responder directly. Order: `(observed time, uid)`, newest first, ≤ 40 per answer; the last
  says `more|<cursor>` when truncated. Continuation `Q|1|<qid2>|<from>|<to>|<responder>|<cursor>`
  is answered only by that responder. A responder answers at most one Q per 60 s (coalesced).
  Pending answers are bound to the guild key and dropped on any guild change; each batch re-checks.
- **Queued sends (round-3 P1, to solve in phase 3):** ChatThrottleLib sends what it already holds
  without our check. So GuildSpy keeps its own small queue and hands CTL **one message at a time**,
  the next only from the previous one's callback, after re-checking the guild key; a guild change
  drops our queue, leaving at most one message in flight.
- **Cost (stated, not hidden):** usually one answer per Q; two responders can overlap before hearing
  each other (expected about one batch; not a hard bound). Worst case with many simultaneous logins is one answer
  per requester: 40 logins ≈ 40 answers ≈ 1,600 messages (~400 KB), the same order as GRM's.
- **Accept reports from: rank X and up** (GRM's `syncRank`, GRM_Core.lua:1085, 5621). Default:
  every rank (GRM's default, GRM_Core.lua:970-973). The sender's rank comes from my roster; a
  sender not in it is refused. At most 200 entries admitted per reporter per session; when the
  cap is hit, that reporter's continuation stops for the session.

## 6. Validation and display safety

Strict grammar per message type and version; one bad field drops the message. guid
`^Player%-%d+%-%x+$`; names ≤ 48 B; levels 1..cap; rank ≤ 32 B; note ≤ 31 chars; `lo ≤ hi`,
`hi` (or exact `at`) within `[now − retention age, now + 10 min]` (an old `lo` is fine: a long
absence). Control characters are refused; `|` is kept as data and escaped only when displayed.

## 7. Retention

Two quotas per guild, each kept in **deterministic order** by `(obs, namespace, uid)`, never by
arrival or seq: self observations 1500 / 180 d; guild reports 500 / 60 d.
A received entry that would fall outside its quota is **not admitted** (no seq, no chg, no
catch-up count), and the account cursor still advances past it, so two accounts can't swap
entries back and forth. Owned accounts share the self quota: older history imported later can't
evict newer observations. **Non-backfill, by design:** a record refused for lack of room is not
offered again later, even if room appears (e.g. after a supersession). Account sync is complete
for what retention admits, not beyond it.

## 8. Migration (phase 1)

Legacy entries get a uid once; `trust = "self"`, `here = true`, `origin = nil` (unknown: the file
is account-wide and may have been written by any alt), `lo = after`, `hi = at` and `obs = at` as a
**fallback**, not the original scan boundary (a departure's real `hi` can precede its logged `at`). They sync to my
other accounts (shown "Seen on this account") but are never guild-exported.

## 9. Notifications

- No digest entry for imports. Guild reports may print chat lines per the owner's setting (§10),
  batched on the same quiet-period boundary as the catch-up line, at most 5 lines per batch.
- One catch-up line, batched: counts of newly admitted, display-eligible observations (after
  retention; excluding revision-only updates and officer notes this character can't read), after
  a 10 s quiet period, at most 60 s after the first: "GuildSpy: 12 observations from your other
  account, 5 reports from guildmates [open log]". Not in combat? (chat is fine) — sent anyway.

## 10. Settings

On their own page, **Options > AddOns > GuildSpy > Sharing** (a sub-page like About, registered
with `Settings.RegisterCanvasLayoutSubcategory`, built on first show, Options.Set as today; owner,
2026-10-12). It also shows, read-only: which of my accounts were last seen syncing and when, and
how many guildmates with GuildSpy were heard this session.

Sync with my other accounts (on). Share with guildmates (on, as GRM: `syncEnabled = true`,
GRM_Core.lua:1084). Guildmates' reports: in chat and in the log / only in the log / never
(default: chat and log). Accept reports from: rank X and up (every rank).

## 11. Phases (each an issue and PR)

1. (#36) Fields and migration, `Log.Receive`, `chg`, deterministic quotas, provenance in rows, tooltips
   and `/gspy log`. No transport, no grouping.
2. (#37) Account sync over LibAccountSync.
3. (#38) Guild sync over GUILD.

## Decided by the owner

- Guild sharing on by default, as GRM (2026-10-12).

- Guildmates' reports are a setting (2026-10-12): **In chat and in the log** (default), **Only in
  the log**, **Never**. In the log they have their own **Reports** tab (and show under All). In
  chat, a batch shows at most 5 lines, then "+N more [open log]"; the first time, one line adds
  that this can be turned off in /gspy options. Observations from my other accounts keep the one
  catch-up line.
