# Forever probe — guild API measurements

What GuildSpy measures on the live client before phase 1 relies on it (`docs/PLAN.md`, phase 0).
Addon-agnostic findings also go to `C:\Projects\WoW\References\Docs\PORTING-TBC-TO-FOREVER.md`.

**Status: measured on 1.60.1.70338 (2026-10-11).** Two runs, both by characters without officer
rights, in a 151–153-member guild on connected realms (GUIDs from realms 4618 and 4620):
- run 1: Cowruzo Kashmere, rank Member, account `#1`;
- run 2: Koma Kino, rank Initiate, account `#12`. This run added the professions questions and
  re-read the event log after its burst.

Still open:
- #7: a run on a character that can view officer notes.
- #10: the real text of a promotion, a demotion, a leave and a kick.

## How to run it

1. `pwsh Tools/deploy.ps1`, restart the client (a new file), `/console scriptErrors 1`.
2. Log in on a character **in a guild**; wait ~30 s.
3. `/gspy probe`, then `/gspy probe watch` (records every system message from then on).
   `/gspy probe log` re-reads the event log at any time. `/gspy probe recipes` asks for a
   guildmate's recipe book (it opens the Professions window).
4. Play normally. Ideally get a promotion or demotion, a note edit, a join or a leave to happen
   while watching (an officer alt helps).
5. `/reload` (writes the file), then read
   `WTF\Account\<account>\SavedVariables\GuildSpy.lua`: `GuildSpyDB.probe`, `GuildSpyDB.probeLog`.

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
  for 3 s of quiet and counts the burst. `/gspy probe log` re-reads the log, and records per type
  how many entries carry the names that type needs.
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

Its one gate is `C_TradeSkillUI.IsGuildTradeSkillsEnabled()`. `ProbeProfessions.lua` asks whether
the server answers.

| # | Question | Where | Answer (run 2) |
|---|---|---|---|
| 13 | `IsGuildTradeSkillsEnabled()`, and `CanViewGuildRecipes(id)` per profession | `probe.professions.enabled`, `.canView` | **false**, and false for all 9 professions |
| 14 | Do members' `professionNRank` values carry real skill levels? | `probe.professions.survey` | **Not through this API.** 144 of 153 members have professions, with **real names** (Skinning 50, Mining 47, Leatherworking 39, Herbalism 34, Blacksmithing 27, Tailoring 24, Alchemy 22, Enchanting 22, Engineering 8), but `C_Club` reports **rank 1 for every one** |
| 15 | `QueryGuildRecipes` → `GUILD_TRADESKILL_UPDATE` → `GetGuildTradeSkillInfo` | `probe.professions.guildTradeSkill` | **Answers.** 10 header rows, all collapsed: skill line, collapsed, icon, name, online, visible, players. The 9 professions above with matching counts, plus "Test Profession [DNT]" (2933, 0 players). Member rows weren't read, because the headers were collapsed. The probe now expands them, reads the rows, and collapses them again: **re-run to see whether member rows carry a skill** |
| 16 | `QueryGuildMembersForRecipe` → `GUILD_RECIPE_KNOWN_BY_MEMBERS` | `probe.professions.recipeQueries` | Only 1 of 7 queries answered: Minor Healing Potion with **0 members**, although the guild has 22 alchemists. The other 6 got no answer within 4 s. Answers weren't matched to their query then (now they are). **No recipe knowledge was obtained in these attempts** |
| 17 | `/gspy probe recipes`: does a guildmate's recipe book open? | `probe.memberRecipes` | **Not in one attempt.** `QueryGuildMemberRecipes(guid, 171)` for Gal Orey (Alchemy, presence offline) returned nothing. No `TRADE_SKILL_SHOW` and no window; 4 s later `IsTradeSkillReady` was false, with 0 recipe ids. The probe now prefers an online crafter in either slot |

**So far:**
- **Established:** the server serves **who has which profession**, with names and counts, and
  the client's switch is off.
- **Not obtained in these attempts:** skill levels (`C_Club` reports 1) and recipe knowledge
  (one answer, 0 members; one recipe book that didn't open).
- **Unsettled:** whether skill or recipe data exists elsewhere. A re-run with the corrected probe
  (expanded headers, matched answers, an online crafter) is the next measurement.

A "who's a tailor" directory is possible from what is established. "Who can craft X" looks like it
needs addon-to-addon sharing, unless the re-run shows otherwise (#9).

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
