# Changelog

## Unreleased

- **A reflective glass** for the log window: a smoked shell with a lit rim and a soft header
  reflection, and a calm reading pane under the list, where the roster's marble was. The tab in
  the guild window keeps the marble. `/gspy glass` switches back to the previous look.
- **LibGlass r10.**

## v0.3.0

Who has which profession, in the guild window, and a cleaner glass. The Professions tab is new:
a profession without its icon, or a member under the wrong one, is worth a report.

- **Guild professions.** A Professions tab in the guild window lists who has which profession, as
  in retail: a heading per profession with its count and who's online, its members under it, show
  offline members, and a search. No skill levels or recipes: the server doesn't share them. Turn
  the tab off in the settings.
- **A cleaner glass** for the log window (LibGlass r6): thin rims, no grain, softer shine.

## v0.2.0

Sharing: between your own accounts, and with guildmates who use GuildSpy. Sharing gets its real
test on the Forever beta, between players: reports of what arrives, or doesn't, are welcome.

- **Sync between your accounts.** While another of your WoW accounts is online in the same guild,
  the two share their logs over Battle.net: what one saw while the other was offline shows up on
  both, marked with the character that saw it, and one chat line says how many arrived. Only ever
  within your current guild. Turn it off, and see which of your accounts last synced, in Options >
  AddOns > GuildSpy > Sharing.
- **Sharing with guildmates.** Guildmates with GuildSpy share what they saw over guild addon
  messages: what happened while you were offline arrives from whoever was online, marked "reported
  by" them, with its own Reports tab in the log. Your own observations only, never officer notes,
  the message of the day or the rank list. Choose in Options > AddOns > GuildSpy > Sharing whether
  their reports show in chat and the log, only the log, or not at all, and from which rank up.
  A guildmate's level-up you already saw yourself isn't kept twice.
- **No duplicate level-ups between your accounts.** When both saw the same level-up, only the most
  precise record is kept: "reached level 22" and "reached level 23", seen live on one, replace
  "leveled from 21 to 23" noticed later by the other. Duplicates already saved are cleaned up at
  login.
- **Reaching the level cap stands out**: "Ann Lee reached level 60, the level cap!" in gold, in chat,
  the login summary (listed before the other level-ups) and the log window, with a fanfare. Turn
  the sound off in the settings ("Sound at the level cap").
- **Notes in the log's tooltips.** Hover a row to see the member's note, and their officer note if
  your character can read officer notes.

## v0.1.0

The first release: know what's going on in your guild, live and while you were away.
`/gspy` for the commands. Found a bug? Report it on GitHub (the link is on the About page).

- **Know what's going on in your guild.** Joins, rejoins and leaves (kicked, and by whom),
  promotions and demotions with the officer who did them, rank changes, public note edits, officer
  note edits (only if you can read officer notes), level-ups, name changes, members back after two
  weeks or more, and a new message of the day.
- **Live, and while you were away.** Changes show in chat as they happen. At login, one short
  summary covers what changed since you last looked, on any character of your account.
- **A log window**, in the guild window (J) as a GuildSpy tab and on its own with `/gspy log` or
  the summary's [open log] link, styled like the guild roster: a line counting what's new, New and
  Earlier sections, class icons and colours, how long ago ("about" when the time is a guess; the
  tooltip says where it came from), filter by type, by time (today, 7 or 30 days) and by rank
  (for guilds that use ranks as raid teams: members in it now, who left it, and who moved in or
  out), search by name, and Mark all as read. `/gspy log 20` prints the last 20 in chat; `/gspy status` shows what
  GuildSpy knows.
- **Settings** in the game's Options > AddOns > GuildSpy (or `/gspy options`): the login summary
  on or off, from which level a level-up is reported, how long away counts as "back", and a chat
  line on or off for each type of change. An About page lists the commands.
- **A minimap button**, also in the minimap's addon list: left-click opens or closes the log,
  right-click opens the settings, and its tooltip shows your guild, who's online and what's new.
  Hide it in the settings or with `/gspy minimap`. **A key binding** to open the log, under the
  game's Key Bindings > GuildSpy (no key by default).
