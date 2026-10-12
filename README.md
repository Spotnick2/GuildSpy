# GuildSpy

**Know what's going on in your guild.** A World of Warcraft: Forever addon (1.60.1).

> **Work in progress.** The tracking and the log window work; options and the minimap button are
> next.

- **Who joined, left or was kicked**, and who rejoined.
- **Who was promoted or demoted**, and by whom when the game says so.
- **Public and officer note changes** (officer notes only if your character can read them).
- **Level-ups, name changes**, and **who came back** after a long absence.
- **Live** while you're online, and one short **"while you were away"** summary when you log in,
  with a log you can open, filter and search.

GuildSpy only reads. It never changes ranks, notes or membership: it isn't a guild management tool.
It keeps the informational side of Guild Roster Manager and nothing else.

## Commands

| Command | What it does |
|---|---|
| `/gspy` or `/guildspy` | the list of commands |
| `/gspy log` | open the log window (it's also a tab in the guild window, J) |
| `/gspy log <n>` | print the last n changes in chat |
| `/gspy status` | what GuildSpy knows about your guild |
| `/gspy scan` | look at the roster now |
| `/gspy rebaseline` | start over from the current roster (the log is kept) |
| `/gspy version` | the addon's version and the client build |
| `/gspy probe` | dump how the client reports the guild (for measuring) |

## License

MIT, see `LICENSE`.
