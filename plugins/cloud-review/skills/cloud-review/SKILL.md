---
name: cloud-review
description: Read-only code review of a branch in a Claude Code cloud session — works for GitLab, Bitbucket or any git host, spends the cloud-session credit instead of local plan limits. Triggers — cloud review, облачное ревью, review in the cloud, second reviewer, cloud credits.
---

# Cloud review

A cloud session reviews one committed branch and returns its verdict as `final.md`. Use it as a second or
backup reviewer. It is not the only gate: check every finding against the code yourself.

```bash
S=<this skill's base directory>/scripts/cloud-review.sh   # the base directory is shown when the skill loads
$S run -C <repo> -r <branch|sha> -b review.md -n <name>   # prints run:, session:, view:
$S wait <run>          # Bash with run_in_background: 0 done, 2 not finished by the deadline, 1 error
$S fetch <run>         # one check: 0 → <run>/final.md, 2 still working
$S clean <run>         # remove the clone, the teleported transcript and the trust entry
```

Runs live in `~/.cache/cloud-review/runs/<name>-<time>/`: `meta`, `prompt.md`, `final.md`, `usage.json`
(the cloud model's tokens), `create.typescript`, `teleport.log`, `repo/`.

## Steps

1. **The brief is a self-contained file.** It says what to check, gives the diff range as
   `git diff <base-sha>..HEAD`, the finding format and the verdict line. The cloud only sees the
   repository at that commit. It cannot see local absolute paths, other repos, your notes, the issue
   tracker, the MR page or staging. For a second round, paste the earlier findings into the brief.
2. **Commit first.** The script clones the commit given by `-r`, so uncommitted work is not uploaded.
   The diff base must be an ancestor of that commit, or it will not be in the bundle.
3. `run` takes about 30–60 s. Then start `wait` in the background; a review usually takes 3–5 minutes.
4. Read `final.md` and verify each finding in the code. To see the session or continue it, open the
   `view:` link, or run `claude --teleport <id>` from `<run>/repo`.
5. When done, run `clean <run>`.

## Why it is built this way

- Cloud sessions clone and push GitHub only. `CCR_FORCE_BUNDLE=1 claude --cloud` uploads a local repo
  as a bundle instead. The script therefore makes a one-branch clone without a remote, so the bundle
  holds just that history and not every local branch. The session cannot push back.
- `claude --cloud` refuses `-p`/`--print`: creating a session is interactive only. The script runs it
  under `script(1)` as a pseudo-terminal. Before that it marks the clone's folder as trusted in
  `~/.claude.json`, because the trust dialog would block. Trust does not cover subfolders, so it is set
  per run, and `clean` removes it.
- The upload refuses a repo under `~/.claude` and a worktree that has per-worktree config
  (`extensions.worktreeConfig`). That is why the clone lives in `~/.cache`.
- `claude -p --model haiku --teleport <id> "OK"` copies the cloud transcript into `~/.claude/projects/`.
  The script takes the cloud model's last message from that JSONL; Haiku only answers "OK" and
  paraphrases nothing. The reviewer is told to end with `CLOUD-REVIEW-DONE`, which is how the script
  knows the review is finished.
