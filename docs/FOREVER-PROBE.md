# Forever probe — guild API measurements

What GuildSpy measures on the live client before phase 1 relies on it (`docs/PLAN.md`, phase 0).
Addon-agnostic findings also go to `C:\Projects\WoW\References\PORTING-TBC-TO-FOREVER.md`.

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

- **Complete 1.6 s after login**, at the first `GUILD_ROSTER_UPDATE` (151 rows, 151 GUIDs).
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
- **Names arrive with the burst.** Read at the first of about 55 `GUILD_EVENT_LOG_UPDATE`s (all
  within 0.3 s), player1 and player2 were nil in every entry (run 1). Read once the burst had been
  quiet for 3 s, **all 100 entries had names** (run 2). Examples:
  - `join, "Koma Kino"`
  - `invite, "Cowruzo Kashmere", "Koma Kino"` (inviter, invitee)
- Never read the log before its burst has settled.
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
| 14 | Do members' `professionNRank` values carry real skill levels? | `probe.professions.survey` | **No.** 144 of 153 members have professions, with **real names** (Skinning 50, Mining 47, Leatherworking 39, Herbalism 34, Blacksmithing 27, Tailoring 24, Alchemy 22, Enchanting 22, Engineering 8), but **every rank is 1**: a placeholder |
| 15 | `QueryGuildRecipes` → `GUILD_TRADESKILL_UPDATE` → `GetGuildTradeSkillInfo` | `probe.professions.guildTradeSkill` | **Answers.** 10 header rows, all collapsed: skill line, collapsed, icon, name, online, visible, players. The 9 professions above with matching counts, plus "Test Profession [DNT]" (2933, 0 players). Member rows weren't read, because the headers were collapsed |
| 16 | `QueryGuildMembersForRecipe` → `GUILD_RECIPE_KNOWN_BY_MEMBERS` | `probe.professions.recipeQueries` | Only 1 of 7 queries answered: Minor Healing Potion with **0 members**, although the guild has 22 alchemists. The other 6 got no answer within 4 s. **Recipe knowledge isn't served** |
| 17 | `/gspy probe recipes`: does a guildmate's recipe book open? | `probe.memberRecipes` | **No.** `QueryGuildMemberRecipes(guid, 171)` for Gal Orey (Alchemy) returned nothing. No `TRADE_SKILL_SHOW` and no window; `IsTradeSkillReady` false, 0 recipe ids |

**Verdict:** the server tracks **who has which profession**, with names and counts, and nothing
deeper: no skill levels and no recipes. That matches the client's switch being off. A guild
directory along the lines of "who's a tailor" is possible; "who can craft X" is not, short of
addon-to-addon sharing. That sharing is what Skilled/AltTrackerProfessions-style sync would add.

## What this changes in the plan

- **The event log does attribute, once its burst has settled.** It names the actor and the
  target, so the plan's server-log matching stands: offline promotions, demotions and kicks get
  their officer, and quit versus kicked is told apart. Its limits:
  - ages only to the hour, so matching is by interval and uniqueness, as planned;
  - 100 entries, oldest first;
  - the reader must wait for the burst to finish.
- **Live attribution is solid.** The promote, demote and kick messages name the officer. The
  strings are the plain enUS ones, captured with `(.+)` because names have surnames.
- **The completeness gate costs little.** The roster is whole at the first update, so the gate
  rarely has to wait.
- **`C_Club` is a second source.** It has the same GUIDs and a 1-based rank order, plus
  professions, which is an "Other ideas" candidate. The roster tuple stays the primary source.
- **`GUILD_EVENT_LOG_UPDATE` comes in bursts of dozens**, so debounce it.
