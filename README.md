# GuildSpy

**Know what's going on in your guild.** A World of Warcraft: Forever addon (1.60.1).

> **Work in progress.** Today GuildSpy only measures how the client reports the guild (`/gspy probe`).
> The tracking below is what it is being built to do.

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
| `/gspy version` | the addon's version and the client build |
| `/gspy probe` | dump how the client reports the guild (for measuring) |

## License

MIT, see `LICENSE`.
