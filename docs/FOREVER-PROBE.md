# Forever probe — guild API measurements

What GuildSpy measures on the live client before phase 1 relies on it (`docs/PLAN.md`, phase 0).
Addon-agnostic findings also go to `C:\Projects\WoW\References\PORTING-TBC-TO-FOREVER.md`.

**Status: not measured yet.** Everything below is a question until a row says "measured (build)".

## How to run it

1. `pwsh Tools/deploy.ps1`, restart the client (new addon), `/console scriptErrors 1`.
2. Log in on a character **in a guild**; wait ~30 s.
3. `/gspy probe`, then `/gspy probe watch` (records every system message from then on).
4. Play normally; ideally get a promotion/demotion, a note edit, a join or a leave to happen while
   watching (an officer alt helps).
5. `/reload` (writes the file), then read
   `WTF\Account\<account>\SavedVariables\GuildSpy.lua`: `GuildSpyDB.probe`, `GuildSpyDB.probeLog`.
6. Repeat step 3 on a character that **cannot** view officer notes, and once right after login
   (the timeline in `probeLog` covers the first 180 s of every session).

## Questions, and where the answer is

| # | Question | Where | Answer |
|---|---|---|---|
| 1 | `GetGuildRosterInfo(i)`: how many returns, which position is what (name with surname? realm suffix? rank index 0- or 1-based? online flag? GUID?) | `probe.rows[*].info`, `probe.survey.positions` | |
| 2 | Does **every** row, offline included, carry a GUID, unique per member? | `probe.survey.guidPos`, `.uniqueGuids` vs `.rows` | |
| 3 | `GetGuildRosterLastOnline(i)`: shape, precision (hours? days?), what an online member returns | `probe.rows[*].lastOnline` | |
| 4 | `GetNumGuildMembers()` returns; does the roster enumerate offline members with show-offline as it is? | `probe.numMembers`, `probe.showOffline`, `survey.rows` | |
| 5 | When is the roster complete after login? (`GUILD_ROSTER_UPDATE` timing, partial rosters, missing GUIDs) | `probeLog` entries with `total`/`rows`/`withGuid`/`dt` | |
| 6 | Rank names and order: index 1 = Guild Master? | `probe.ranks` | |
| 7 | `CanViewOfficerNote` per character; what a non-officer sees in the officer-note slot (`""`? nil?) | `probe.canViewOfficerNote`, rows | |
| 8 | `GetGuildEventInfo(i)`: shape (type, p1, p2, rank, years/months/days/hours ago?), newest first?, how many entries kept | `probe.eventLog` | |
| 9 | `C_Club` guild club: present? `GetMemberInfo` fields (guid, notes, lastOnline*) | `probe.club` | |
| 10 | The `ERR_GUILD_*` strings, and the real text of join / leave / kick / promote / demote messages | `probe.globals`, `probeLog` (`msg`) | |
| 11 | Every guild event registers (`refused` on the login entry is empty) | `probeLog[1].refused` | |
| 12 | The TOC icon `Interface\Icons\INV_Misc_Spyglass_03` exists | `probe.icon` | |

## Findings

(none yet)
