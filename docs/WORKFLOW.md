# Working on GuildSpy

Single maintainer, so this is deliberately light. **Every change goes through an issue and a pull
request**, always (owner's decision, 2026-10-11). The repo is `github.com/Spotnick2/GuildSpy`.

## The loop

```
issue  ->  branch  ->  PR  ->  Codex review  ->  address  ->  owner merges
```

1. **Find or open the issue.** Milestones map to the plan's phases (`docs/PLAN.md`). Labels:
   - `measure`: needs the live client;
   - `ui`;
   - `postponed`: deferred by the owner;
   - `idea`.

   An issue's body holds the decided design: update it when the design changes.
2. **Branch off `main`**, named for the work: `phase2/log-window`, `fix/digest-twice`. Never commit
   to `main`. A branch that builds on an unmerged one is a **stacked PR**: its base is that branch,
   and GitHub retargets it to `main` when the base merges.
3. **Before every commit:** `pwsh tests/run.ps1` green (`luac -p` on every TOC file, then the tests).
   For a behaviour change, prove the new test bites: break the behaviour and watch it go red.
4. **Open the PR** with `Closes #N`, a short summary, and how it was tested (unit, in game).
5. **Run the review** (below) and post its verdict as a PR comment.
6. **Address or rebut** each finding: fix it in a commit on the branch, or say in the thread why
   not. Declined findings with a lasting reason also go in `docs/PLAN.md`.
7. **The owner merges.** Commit and push only as part of this loop.

In-game measurements (`/gspy probe`) go in `docs/FOREVER-PROBE.md`. Findings that hold for every
Forever addon go in `C:\Projects\WoW\References\PORTING-TBC-TO-FOREVER.md`.

## The review on a PR

**Routing.** The model, the effort and whether a review is needed follow the shared
`$wow-addon-review` skill (AGENTS.md "Review policy"). This section is only the Codex invocation it
calls for.
- Codex is a *different model family*, so it brings different blind spots.
- The owner's reviewer is `gpt-6-astra`.
- Ask before `high` unless the owner has already said so for that work.
- Codex is a local CLI, not a GitHub App: the review runs locally and is posted to the PR for the
  record.
- `.claude/skills/codex-consult` has the flags and why each one is there.

**Scope: the PR's committed diff against its actual base.** For a stacked PR, the base is the
branch it sits on, not `main`. It is never the working tree.

```bash
base=$(gh pr view <N> --json baseRefName -q .baseRefName)
git fetch origin "$base"
git diff "origin/$base...<branch>"      # what the PR contains; Codex reads files with git show <branch>:<path>
# Write the prompt to a file: that diff command, the files, numbered questions (below).
timeout 900 codex exec -m gpt-6-astra -c model_reasoning_effort=<effort> \
  --ephemeral --skip-git-repo-check -s read-only \
  -o <scratchpad>/verdict.md < <scratchpad>/prompt.txt > <scratchpad>/progress.log 2>&1
gh pr comment <N> --body-file <scratchpad>/verdict.md
```

- **Feed the prompt on stdin** (`< file`). On this machine, a prompt passed as an argument in a
  non-TTY shell has hung waiting for stdin (codex-consult).
- **Read the answer from `-o`**, not stdout.
- **`--ephemeral`** keeps no session log; `-s read-only` stops Codex editing the tree. The `-o` file
  is still written.
- **Never say "review the code" and "do not run commands" together.** Codex reads files through
  shell commands, so that contradiction makes it refuse.

### Prompt shape

Give it:
- **The facts it must not re-argue:** `AGENTS.md`, `docs/PLAN.md` and `docs/FOREVER-PROBE.md`.
  The guild API shapes there are measured on the live client.
- **The files to read**, by path.
- **Numbered questions**, with wrong data shown before style.
- **The P1/P2/P3 tags.**
- **A closing note:** this is a single-maintainer hobby addon, so no new scope and no complexity
  nobody asked for.

### Reconciling

Take its bug-catching seriously; be skeptical when it wants more rigor.

**Track record:**
- **The plan (4 rounds):** 6 real P1s in round 1 (completeness, identity, rank shifts, officer-note
  privacy, dedupe, attribution).
- **Phase 1's code:** 11 findings. 9 were fixed. 2 were declined with reasons in `docs/PLAN.md`:
  a server leave message is proof by itself, and a same-realm guild has no guild realm.

## Fallback

If `codex` is unavailable (usage limits, disabled), the PR still gets its independent review:
Fable runs it instead, and the posted comment says so. It is the same family, so a weaker
adversary, but better than none.
