# Forever probe — guild API measurements

What GuildSpy measures on the live client before phase 1 relies on it (`docs/PLAN.md`, phase 0).
Addon-agnostic findings also go to `C:\Projects\WoW\References\Docs\PORTING-TBC-TO-FOREVER.md`.

**Status: measured on 1.60.1.70338 (2026-10-11).** Two runs, both by characters without officer
rights, in a 151–153-member guild on connected realms (GUIDs from realms 4618 and 4620):
- run 1: Cowruzo Kashmere, rank Member, account `#1`;
- run 2: Koma Kino, rank Initiate, account `#12`. This run added the professions questions and
  re-read the event log after its burst.

**Re-measured on 1.60.1.71037 (2026-11-20, 21:49 EST, #101),** after that day's server hotfix that
hid the realm. One run by Drucida Komakino, rank Member, no officer rights, in a
369-member guild on connected realms. Every shape GuildSpy reads is unchanged:
- **The roster tuple** (§1): 17 returns in the same order. Returns 18–21 are nil in every row.
  Position 17 holds a GUID in 369 of 369 rows, all unique, and position 1 holds a name in all 369.
  `rankIndex` is still 0-based. Position 12 (achievement points) now reads `0` or `-1`.
- **Last online** (§3): four nils for an online member, `years, months, days, hours` for an
  offline one (`0,0,10,4`).
- **`GetNumGuildMembers`** (§4): two returns (`369, 107`), with show-offline on.
- **Ranks** (§6): `GuildControlGetNumRanks()` = 6, and `GuildControlGetRankName` is still 1-based
  (1 = "Guild Master").
- **The event log** (§8): 8 returns, 100 entries, oldest first (index 1 is 5 d 10 h old, index 100
  0 h). All 100 carry the names their type needs after the burst: 45 invite, 45 join, 8 quit,
  2 promote. Still no `remove` entry.
- **`C_Club`** (§9): a guild club id, 369 members, the same fields plus `clubType`,
  `isRemoteChat`, `memberId` and `role`. No `officerNote` for this character.
- **New since the hotfix:** `GetGuildInfo("player")` returns 4 values, and the 4th (the guild's
  realm) is **nil**. Since `GetRealmName()` is `""` too, GuildSpy keys a guild by its name alone
  (#104).

**Re-run through GuildSpyProbe on 1.60.1.71037 (2026-11-20, 22:35 EST, #67).** It was the
first run of `/fp steps gs guild`, with the same character and guild. All 9 steps completed, and
the 3 checks passed. The dump survived the procedure's own `/reload`. Every shape above is
unchanged:
- 369 rows, a GUID at position 17 in all 369, all unique.
- `GetNumGuildMembers` = `369, 94`; 6 ranks.
- 100 event log entries, all with their names.
- `C_Club` has the same fields, and none of the 13 `ERR_GUILD_*` / friend strings is missing.

What this run added:
- **The event log answered in one `GUILD_EVENT_LOG_UPDATE`**, not a burst: the dump counted 1
  update before its 3 s of quiet, with all 100 entries named. On 70338 it was about 55. Keep the
  debounce, since one run doesn't show the burst is gone.
- **The roster was complete at every `GUILD_ROSTER_UPDATE`** after two `/reload`s (3 minutes
  after the first, 20 s after the second): 369 of 369 rows with name and GUID, from the first
  update, 1.7–2.2 s in. The update fires every few seconds: 51 in the first 3 minutes, 12 of the
  57 in the same frame as the one before. A fresh login, where the roster may still be loading,
  isn't measured.
- **`PLAYER_ENTERING_WORLD` on a `/reload`** passed `isInitialLogin = false`,
  `isReloadingUi = true`, on both reloads. A fresh login isn't measured.
- **Professions:** rows 15–17 of the professions table re-run with the corrected probe.

Still open:
- #7: a run on a character that can view officer notes.
- #10: the real text of a promotion, a demotion, a leave and a kick.

## How to run it

The probe is `Tools/GuildSpyProbe`, a ForeverProbe module (`/fp gs`, `References\Docs\PROBES.md`),
never shipped. Until #67 it was `/gspy probe` inside the addon, saving into `GuildSpyDB.probe` and
`GuildSpyDB.probeLog`: the runs above were taken that way, and their findings hold for their build.

1. `pwsh Tools/deploy.ps1 -Probe` (GuildSpy, then ForeverProbe and the probe), `/reload`,
   `/console scriptErrors 1`.
2. Log in on a character **in a guild**.
3. `/fp steps gs guild`. The panel asks you to wait ~30 s for the roster, dumps the guild API,
   waits for the event log and the professions answers, asks for a guildmate's recipe book (it opens the
   Professions window), asks whether to record every system message from then on (#10: Yes on,
   No off, Skip keeps the saved setting), and asks for a `/reload`. One-offs: `/fp gs dump`, `eventlog` (re-reads the event log), `recipes`,
   `watch on|off`, `timeline`.
4. With watch on, play normally. Ideally get a promotion or demotion, a note edit, a join or a
   leave to happen (an officer alt helps).
5. `/reload` (writes the file), then read
   `WTF\Account\<account>\SavedVariables\GuildSpyProbe.lua`: `GuildSpyProbeDB.dump` (the dump),
   `GuildSpyProbeDB.timeline` (the first 3 minutes after each login or `/reload`, every entry
   tagged with its `load`, kept across reloads up to 300 entries), `GuildSpyProbeDB.watched` (the
   system messages, a list of their own, also capped at 300) and `GuildSpyProbeDB.log` (the
   console's lines). In the answers below, `probe.X` is now
   `GuildSpyProbeDB.dump.X`.

## Answers

### 1. `GetGuildRosterInfo(i)`

**17 returns, in Retail's order:**

| # | Field | Note |
|---|---|---|
| 1 | name | `"First Surname"`, **no realm**, even for members on the other connected realm |
| 2 | rankName | |
| 3 | rankIndex | **0-based**: 0 = Guild Master |
| 4 | level | |
| 5 | classDisplayName | |
| 6 | zone | |
| 7 | note | |
| 8 | officerNote | |
| 9 | isOnline | |
| 10 | status | |
| 11 | class | the class token |
| 12 | achievementPoints | -1 |
| 13 | (a number) | meaning unknown |
| 14 | isMobile | |
| 15 | canSoR | |
| 16 | repStanding | |
| 17 | **guid** | |

### 2. Does every row have a GUID?

**Yes.** Position 17 holds a GUID in 151 of 151 rows, offline members included, and all 151 are
unique. They are there from the first `GUILD_ROSTER_UPDATE`.

Names alone would collide across connected realms, so keying members by GUID stands.

### 3. `GetGuildRosterLastOnline(i)`

- Online member: **four nils**.
- Offline member: `years, months, days, hours` (e.g. `0,0,1,11`). Precision is **one hour**.

### 4. `GetNumGuildMembers()` and offline members

- **Two returns**: total and online (`151, 8`).
- Show-offline was on, and all 151 rows enumerate.

### 5. When the roster is complete after login

- **Names and GUIDs were all there 1.6 s after login**, at the first `GUILD_ROSTER_UPDATE`:
  151 rows, 151 GUIDs, in one run. The timeline didn't record ranks or the rank table, so this
  shows names and GUIDs arriving early. It doesn't show the whole completeness gate passing then.
- The event's argument was `false` every time.
- Updates come **in pairs**: on every member online/offline change, and otherwise about every
  30–35 s.

### 6. Ranks

- `GuildControlGetNumRanks()` = 7.
- `GuildControlGetRankName(i)` is **1-based** (1 = "Guild Master"), so a member's rank name is
  `GuildControlGetRankName(rankIndex + 1)`.
- Rank names are custom ("Pogo", "Mega Turbo GM").

### 7. Officer notes

- `CanViewOfficerNote()` is `false` for a Member; `IsGuildOfficer()` is false too.
- The officer-note slot reads **`""`**, which looks exactly like an empty note. Whether a note is
  unreadable must therefore come from `CanViewOfficerNote`, never from the value.
- The officer side hasn't been run yet.

### 8. The guild event log

- `GetGuildEventInfo(i)` has **8 returns**: type, player1, player2, rank, then years, months,
  days and hours ago.
- `GetNumGuildEvents()` = **100**, which looks like a cap.
- Index 1 is the **oldest** entry: ages fall as the index rises.
- **Names, as observed.** Two different runs on two characters, so this is not a within-run
  transition:
  - **Run 1** read the log at the first of about 55 `GUILD_EVENT_LOG_UPDATE`s, all within 0.3 s.
    Only 10 entries were saved, and player1 and player2 were nil in all of them.
  - **Run 2** read it once the burst had been quiet for 3 s. All 100 entries carried the names
    their type needs:

    | Type | Count | Names | Example |
    |---|---|---|---|
    | promote | 31 | the officer in p1, the member in p2 | `promote, "Enzo Tonic", "Kalendar Frostmarrow", "Member"` |
    | demote | 1 | the officer in p1, the member in p2 | `demote, "Enzo Matrix", "Baltack Tremblay", "Pogo"` |
    | invite | 33 | the inviter in p1, the invitee in p2 | |
    | join | 33 | the member in p1, p2 nil | |
    | quit | 2 | the member in p1, p2 nil | |
    | remove (kick) | 0 | **not observed yet** | |
- **Inferred rule, not proven:** read the log only after its burst has settled. The probe now waits
  for 3 s of quiet and counts the burst. `/gspy probe log` (now `/fp gs eventlog`) re-reads the
  log, and records per type how many entries carry the names that type needs.
- Join entries carry rank `""`. The invite above carries "Guild Master" although the inviter is a
  Member, so the rank field's meaning on an invite is unclear; don't rely on it there.

### 9. `C_Club`

- Present: a guild club id, and 151 members.
- `ClubMemberInfo` fields seen:
  - `guid`, `name`, `memberNote` (no `officerNote` for this character)
  - `level`, `classID`, `race`
  - `guildRank`, **`guildRankOrder` (1-based)**
  - `lastOnlineYear`, `lastOnlineMonth`, `lastOnlineDay`, `lastOnlineHour`
  - `zone`, `presence`, `isSelf`
  - **professions**: `profession1Name`, `profession1ID`, `profession1Rank`, and the same for
    `profession2`

### 10. System message strings

Read from the client (enUS):

| Global | Text |
|---|---|
| `ERR_GUILD_JOIN_S` | "%s has joined the guild." |
| `ERR_GUILD_LEAVE_S` | "%s has left the guild." |
| `ERR_GUILD_REMOVE_SS` | "%s has been kicked out of the guild by %s." |
| `ERR_GUILD_PROMOTE_SSS` | "%s has promoted %s to %s." |
| `ERR_GUILD_DEMOTE_SSS` | "%s has demoted %s to %s." |
| `ERR_GUILD_LEADER_CHANGED_SS` | "%s has made %s the new Guild Master." |

`ERR_GUILD_QUIT_S` and `ERR_GUILD_REMOVE_SELF` are about yourself.

Seen live:
- A join: "Zekari Tush has joined the guild.", followed at once by that member's online line.
- Online lines carry a player link: `"|Hplayer:Hank Skorpio|h[Hank Skorpio]|h has come online."`
- Offline lines are plain text.

### 11. Events

All seven events registered (no `refused` entry).

### 12. The TOC icon

`Interface\Icons\INV_Misc_Spyglass_03` exists (file id 134442).

## Guild Roster Manager on the guild channel (#8)

GRM has published Forever builds since R1.995 (2026-11-05). Before deciding on a listener (#8),
`Tools/GuildSpyProbe` (a ForeverProbe module, `/fp gs`) records what GRM actually sends. The
protocol as read from GRM's source is in #8's findings comment; this section is what the client
shows.

**How to run it:** `pwsh Tools/deploy.ps1 -ProbeOnly`, `/reload`, then `/fp steps gs grm`. That
reads the state, sends one `GRMUSER` `REQ?` on your click (each GRM user answers with its `REG`
line), waits 15 s and asks for a `/reload`. Then leave it loaded and play normally for about a
week. Results: `WTF\Account\<account>\SavedVariables\GuildSpyProbe.lua`, `GuildSpyProbeDB.grm`.
`/fp gs grm`, `users` and `samples` show them in game.

What it keeps: counts per prefix, channel and tag, and per day; up to 3 samples per tag. Raw
text is kept only for tags made of names, dates, epochs, ranks and flags; custom notes,
nicknames, birthdays, bans and unknown tags become field shapes (`s12`, `n8`). Senders are kept
as shapes (`2w`, `2w+realm`) with their roster match, except in `users` (who runs GRM).

| # | Question | Where | Answer |
|---|---|---|---|
| 18 | Does anyone in the guild run GRM, which versions, sync on? | `users`, `counts.GRMUSER` | **Nobody but the owner's own two test characters.** The one `REQ?` got one answer, from the other test account (R1.99521, sync on, all ranks) |
| 19 | Which `GRM_SYNC` tags cross the guild channel, how often? | `counts.GRM_SYNC.GUILD`, `days` | **None seen.** Not even election traffic in the ~30 s both test clients ran GRM together |
| 20 | Do alt/main links (`GRM_ADDALT`, `GRM_RMVALT`, `GRM_MAIN`, `GRM_RMVMAIN`) arrive? | the same | **None seen** |
| 21 | The shape of a sender, and of a member name inside a message ("First Surname", or with "-Realm")? Does it match a roster name? | `senders`, `senderMatch`, `nameFields` | Senders: **"First Surname"** (19 of 19), each matching a roster name as is. Member names inside messages: none seen |
| 22 | `C_Secrets.HasSecretRestrictions()` at login | `state.restrictions` | **true**, on both accounts, at every login |
| 23 | Are any GRM payloads secret? | `secret` | **No** (0 of 19) |

**Measured on 1.60.1.70888, 2026-11-11 to 12**, in a 302–308-member guild, on two accounts:
- **Before GRM was installed here** (account `#2`: 32 loads spread over about 6 hours): **0 GRM
  messages.** GRM sends `GRMVER` as it loads and `REG` 3 s later (`GRM.LoadAddon`,
  GRM_Config.lua:185 and 224 in R1.99521), so no GRM user logged in while it listened.
- **With GRM installed on both test accounts** (one session): `GRMVER` at login, `REG` and `REQ`
  only, all from the other test account. `REG` is unchanged from R1.99423: 8 fields,
  `REG?R1.99521?1794318178?5?2?false?true?true`.
- The procedure (`/fp steps gs grm`, run #247): in a guild, roster 308, restrictions on; `REQ?`
  sent (result 0); 1 answer in 15 s.

**So:** GRM listening has nothing to listen to in this guild. #8 closes with these numbers. Re-run
`/fp steps gs grm` if the guild changes or GRM becomes common (the probe stays in `Tools/`).

## Guild professions (an addon opportunity, outside GuildSpy's scope)

Forever ships Retail's guild-recipe UI unchanged. `git diff live forever` in `..\wow-ui-source`
shows no profession or recipe line differing in `Blizzard_Communities\CommunitiesMemberList.lua`
or `Blizzard_Professions`. That UI includes:
- a Professions roster column;
- clicking a member under a profession to open their recipe book (`QueryGuildMemberRecipes`);
- an "All recipes" view (`CanViewGuildRecipes` / `ViewGuildRecipes`);
- "who in the guild can craft this" (`QueryGuildMembersForRecipe`).

Its one gate is `C_TradeSkillUI.IsGuildTradeSkillsEnabled()`. The probe's `GuildProfessions.lua`
(was `ProbeProfessions.lua`) asks whether the server answers.

| # | Question | Where | Answer (run 2) |
|---|---|---|---|
| 13 | `IsGuildTradeSkillsEnabled()`, and `CanViewGuildRecipes(id)` per profession | `probe.professions.enabled`, `.canView` | **false**, and false for all 9 professions |
| 14 | Do members' `professionNRank` values carry real skill levels? | `probe.professions.survey` | **Not through this API.** 144 of 153 members have professions, with **real names** (Skinning 50, Mining 47, Leatherworking 39, Herbalism 34, Blacksmithing 27, Tailoring 24, Alchemy 22, Enchanting 22, Engineering 8), but `C_Club` reports **rank 1 for every one** |
| 15 | `QueryGuildRecipes` → `GUILD_TRADESKILL_UPDATE` → `GetGuildTradeSkillInfo` | `probe.professions.guildTradeSkill` | **Answers.** 10 header rows, all collapsed: skill line, collapsed, icon, name, online, visible, players. The 9 professions above with matching counts, plus "Test Profession [DNT]" (2933, 0 players). Member rows weren't read, because the headers were collapsed. The probe now expands them, reads the rows, and collapses them again: **re-run to see whether member rows carry a skill**. **Re-run on 71037 (#67): the member rows carry no skill.** 10 headers expanded to 197 rows, 187 of them member rows (skill line, then name, full name, class, online, zone, a number, class file, a flag, a number). The number at position 13 is **1 in all 187**, the same rank 1 as `C_Club`; position 16 is 0 or 1. The headers were collapsed again |
| 16 | `QueryGuildMembersForRecipe` → `GUILD_RECIPE_KNOWN_BY_MEMBERS` | `probe.professions.recipeQueries` | Only 1 of 7 queries answered: Minor Healing Potion with **0 members**, although the guild has 22 alchemists. The other 6 got no answer within 4 s. Answers weren't matched to their query then (now they are). **No recipe knowledge was obtained in these attempts**. **Re-run on 71037 (#67): the same.** Of 7 queries, only Minor Healing Potion was answered, again with **0 members**. The other 6 got no answer within 4 s, and no stray answer came late |
| 17 | `/gspy probe recipes` (now `/fp gs recipes`): does a guildmate's recipe book open? | `probe.memberRecipes` | **Not in one attempt.** `QueryGuildMemberRecipes(guid, 171)` for Gal Orey (Alchemy, presence offline) returned nothing. No `TRADE_SKILL_SHOW` and no window; 4 s later `IsTradeSkillReady` was false, with 0 recipe ids. The probe now prefers an online crafter in either slot. **Re-run on 71037 (#67), with an online crafter: still not.** `QueryGuildMemberRecipes(guid, 333)` for an Enchanting guildmate shown as Away returned nothing. No trade skill event came; 4 s later the view was neither a guildmate's nor ready, and the base profession read as id 0. Inconclusive by the probe's own rule, and nothing was closed |

**So far:**
- **Established:** the server serves **who has which profession**, with names and counts, and
  the client's switch is off.
- **Not obtained, now on two builds:** skill levels and recipe knowledge.
  - Skill levels: `C_Club` reports 1, and so do the crafter list's member rows (re-run, 71037).
  - Recipe knowledge: one answer with 0 members on both runs, and no recipe book opened, for an
    offline crafter (70338) or an Away one (71037).
- **Unsettled:** whether that data exists anywhere else the client can reach. The corrected probe
  (expanded headers, matched answers, an online crafter) found none of it.

A "who's a tailor" directory is possible from what is established. "Who can craft X" needs
addon-to-addon sharing (#9): the re-run found no server source for it.

## What this changes in the plan

- **The event log can attribute promotions and demotions** once its burst has settled.
  31 promote entries and 1 demote entry named the officer and the member. The plan's server-log
  matching stands for those, and for quits (2 quit entries named the member).
- **Offline kicks are unconfirmed.** No `remove` entry has been seen, so offline kick-versus-quit
  is unconfirmed until one is (#6). Live kicks are named by their system message regardless.
- **Its limits:**
  - ages only to the hour, so matching is by interval and uniqueness, as planned;
  - 100 entries, oldest first;
  - the reader waits for the burst to finish.
- **Live attribution is solid.** The promote, demote and kick messages name the officer. The
  strings are the plain enUS ones, captured with `(.+)` because names have surnames.
- **The completeness gate probably passes early.** In one run, names and GUIDs were all there at
  the first update. Whether ranks were loaded by then wasn't recorded, so treat this as likely,
  not measured.
- **`C_Club` is a second source.** It has the same GUIDs and a 1-based rank order, plus
  professions, which is an "Other ideas" candidate. The roster tuple stays the primary source.
- **`GUILD_EVENT_LOG_UPDATE` comes in bursts of dozens**, so debounce it.
