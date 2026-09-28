# cloud-review

**Code review in Claude Code cloud sessions for GitLab, Bitbucket or any other git host.**

**English** · [Русский](README.ru.md)

Claude Code cloud sessions can clone and push only GitHub repositories. This plugin sends one
committed branch from any repository to a cloud session and brings the finished review back as
`final.md`. The cloud session pushes nothing: it reviews, it does not implement.

Why bother: cloud sessions spend a cloud credit instead of your plan's 5-hour and weekly limits. In
autumn 2026 subscribers got a one-time credit, $100 on Pro and $250 on Max. It had to be claimed by
October 7 and expires on November 5, 2026. After that, cloud sessions use your regular quota. In our
runs, a Fable review of a ~240-line merge request cost about $2.5, so $250 is roughly a hundred reviews.

## Install

As a plugin, from this repository used as a marketplace:

```bash
claude plugin marketplace add ilya-kozyrev/claude-cloud-review
claude plugin install cloud-review@cloud-review
```

Inside a Claude Code session, `/plugin marketplace add ilya-kozyrev/claude-cloud-review` and
`/plugin install cloud-review@cloud-review` do the same. The skill is `/cloud-review:cloud-review`, or
just ask Claude for "a cloud review of this branch".

By hand, as a plain skill:

```bash
git clone https://github.com/ilya-kozyrev/claude-cloud-review
mkdir -p ~/.claude/skills
cp -R claude-cloud-review/plugins/cloud-review/skills/cloud-review ~/.claude/skills/
```

Requirements:
- Claude Code with the `--cloud` flag (check: `claude --help | grep -- --cloud`). On macOS the script
  finds the desktop app's newer binary if the `claude` on your PATH is too old.
- A claude.ai login: `claude auth login`. Cloud sessions do not work with an API key.
- `git`, `python3` and `script`, which ship with macOS and Linux.

## Usage

```bash
S=~/.claude/skills/cloud-review/scripts/cloud-review.sh   # for the plugin, it lives under ~/.claude/plugins/cache/…
$S run -C ~/code/myrepo -r my-branch -b review.md -n mr42   # creates the cloud session
$S wait ~/.cache/cloud-review/runs/mr42-<time>             # waits, then writes final.md
cat ~/.cache/cloud-review/runs/mr42-<time>/final.md
$S clean ~/.cache/cloud-review/runs/mr42-<time>
```

- The default model is `claude-fable-5-1`. Pick another with `-m`, for example `-m opus`.
- Write the brief like [`examples/review-brief.md`](plugins/cloud-review/skills/cloud-review/examples/review-brief.md).
  It must be self-contained: the cloud sees only the repository at that commit. It has no access to
  your local paths, the issue tracker, the merge request page or staging.
- A review usually takes 3–5 minutes.

## How it works

1. `run` makes a one-branch clone of the commit, with no remote, in `~/.cache/cloud-review/runs/`.
2. `CCR_FORCE_BUNDLE=1 claude --cloud "<brief>"` uploads the clone as a git bundle and creates the
   cloud session. `--cloud` is interactive only, so the script runs it under `script(1)` as a
   pseudo-terminal.
3. The cloud model reviews the code and ends its answer with the line `CLOUD-REVIEW-DONE`.
4. `fetch` and `wait` call `claude -p --teleport <id>`. Teleport copies the cloud transcript into
   `~/.claude/projects/`, and the script takes the cloud model's last answer from it verbatim into
   `final.md`.

## What the script touches on your machine

- It creates `~/.cache/cloud-review/runs/<name>-<time>/` with the clone, the brief, the result and
  `usage.json` (the cloud model's token counts).
- It marks the clone's folder as trusted in `~/.claude.json`. Without that, the interactive
  `claude --cloud` stops at the "do you trust this folder" prompt. `clean` removes the mark.
- Each `fetch` is one short local Haiku turn, about $0.1 from your regular limits.

## Pitfalls we hit

- `claude --cloud` cannot be combined with `-p`: creating a session is interactive only.
- The upload refuses a repository inside `~/.claude` and a git worktree that uses
  `extensions.worktreeConfig`. That is why the clone is separate and lives in `~/.cache`.
- Folder trust does not extend to subfolders, so the script sets it for each run.
- `timeout` is an external binary and cannot run a shell function. The timeout wraps the real command
  inside the pseudo-terminal.
- Bash reads a script while it runs it. A script overwritten in place during a long `wait` used to
  fail after the review was already written. The script now ends with `main "$@"; exit $?`.
- In our desktop client, an `Agent` with `isolation: "remote"` did not go to the cloud. It ran
  locally on the plan's limits without any notice. Check this on your setup before relying on it.
- Quality: on one of our merge requests, both Fable runs found a medium defect but missed a
  high-severity one that Codex found. Use the cloud review as a second opinion, not the only gate.
  For a reviewer from another vendor, see [claude-codex-review](https://github.com/ilya-kozyrev/claude-codex-review).

## License

MIT
