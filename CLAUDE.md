# CLAUDE.md — Claude-specific overlay

`AGENTS.md` is the shared, cross-agent baseline (what GuildSpy is, layout, design rules,
build/test/deploy, conventions, model tiers). This file only adds the Claude-specific bits. When
the two overlap, AGENTS.md is the source of truth. The design is `docs/PLAN.md`.

## Model, in one line

The latest Opus is the default for direct work in the main thread. Subagents default to the latest
Sonnet (routine implementation, tests) or Haiku (exploration, deploys). **Code review is carved out**:
the shared `$wow-addon-review` skill governs routing (see "Review policy" in AGENTS.md).

## Adversarial review — prefer a *different* family

For a second opinion on a **plan or design**, the value is decorrelated blind spots:

1. **First choice: Codex / GPT** via `/codex-consult` (`.claude/skills/codex-consult`). The owner
   critiques plans and designs with `gpt-6-astra` at `high` (asked for on this project's plan);
   ask before using `high` elsewhere. **PR code reviews are routed by `$wow-addon-review`**, not by
   this line (`docs/WORKFLOW.md`).
2. **Fallback when Codex is unavailable:** Fable. Same family, so a weaker adversary.
3. **Stay in the main thread** when the question is about this codebase's specifics (below).

Loop: Claude drafts → Codex attacks → Claude reconciles. Take its bug-catching seriously; be
skeptical when a cold model wants to **ratchet complexity** for a single-owner addon. `docs/PLAN.md`
went through four rounds: it has the trail.

### This codebase's specifics (local judgment beats a cold reviewer)

Hand these to any external review, and don't let a blind reviewer override them:

- **The design rules in AGENTS.md** (GUID identity, the completeness gate and two-scan departures,
  officer-note privacy, conservative attribution, the sequence-number digest boundary). Each closed
  a concrete failure; changing one needs the same scrutiny.
- **Measured, not assumed.** Guild tuple positions, last-online precision and the system-message
  text come from `docs/FOREVER-PROBE.md`. A reviewer citing Retail's `GetGuildRosterInfo` order or
  Classic-era `GuildRoster()` is arguing from a client this isn't.
- **`GuildSpyDB` shape** is persisted account-wide; once released, don't break it.
- **Test stubs model Forever.** A stub returning a shape the client doesn't would make a broken
  build pass; stub fidelity is part of the review surface.
- **Forever, not TBC or Retail.** Lua 5.1; names have surnames; the guild realm can differ from the
  player's.

## Fable usage

Adversarial critique only as the Codex fallback, and post-phase diff review. Implementation use
needs the owner's explicit per-turn approval.
