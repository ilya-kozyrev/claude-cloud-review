#!/usr/bin/env bash
# cloud-review.sh — read-only code review in a Claude Code cloud session, for any git host.
# Cloud sessions clone and push only GitHub; this uploads a one-branch clone (no remote) as a
# git bundle, lets a cloud model review it, and brings the final answer back through
# `claude --teleport`, which copies the cloud transcript into ~/.claude/projects/.
# The session cannot push anything: review only. Needs a claude.ai login and Claude Code with --cloud.
#
#   cloud-review.sh run   -r <ref> -b <brief.md> -n <name> [-C <repo>] [-m <model>]
#   cloud-review.sh fetch <run-dir>        # exit 0 done (final.md), 2 not finished, 1 error
#   cloud-review.sh wait  <run-dir> [interval_s=120] [deadline_s=2700]
#   cloud-review.sh clean <run-dir>        # drop the clone, teleported transcripts, trust entry
set -euo pipefail

RUNS="${CLOUD_REVIEW_RUNS:-$HOME/.cache/cloud-review/runs}"  # not under ~/.claude: the upload refuses that
DONE_MARK="CLOUD-REVIEW-DONE"

die() { echo "cloud-review: $*" >&2; exit 1; }

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

with_timeout() {  # with_timeout <seconds> cmd...; macOS has no `timeout` unless coreutils is installed
  local t=$1; shift
  if command -v timeout >/dev/null; then timeout "$t" "$@"
  elif command -v gtimeout >/dev/null; then gtimeout "$t" "$@"
  else "$@"; fi
}

in_pty() {  # in_pty <typescript-file> <seconds> cmd...; BSD and util-linux `script` differ
  # The timeout goes inside the pty, on the real command: `timeout` is an external binary and
  # cannot run this shell function.
  local out=$1 t=$2; shift 2
  if command -v timeout >/dev/null; then set -- timeout "$t" "$@"
  elif command -v gtimeout >/dev/null; then set -- gtimeout "$t" "$@"; fi
  case "$(uname -s)" in
    Darwin|*BSD) script -q "$out" "$@" ;;
    *) script -q -e -c "$(printf '%q ' "$@")" "$out" ;;
  esac
}

claude_bin() {
  # An old CLI on PATH may lack --cloud; the macOS desktop app ships a current one.
  if [ -n "${CLAUDE_CODE_EXECPATH:-}" ] && "$CLAUDE_CODE_EXECPATH" --help 2>/dev/null | grep -q -- '--cloud'; then
    echo "$CLAUDE_CODE_EXECPATH"; return
  fi
  local app
  app=$(ls -d "$HOME/Library/Application Support/Claude/claude-code/"*/claude.app/Contents/MacOS/claude 2>/dev/null \
        | awk -F/ '{print $(NF-4) "\t" $0}' | sort -V | tail -1 | cut -f2-)
  if [ -n "$app" ] && "$app" --help 2>/dev/null | grep -q -- '--cloud'; then echo "$app"; return; fi
  if command -v claude >/dev/null && claude --help 2>/dev/null | grep -q -- '--cloud'; then command -v claude; return; fi
  die "no claude CLI with --cloud found (need Claude Code >= 2.1.2xx)"
}

set_trust() {
  # `claude --cloud` is interactive and stops at the folder-trust dialog, and trust does not cover
  # subdirectories: trust each run's clone (on) and drop the entry on clean (off).
  python3 - "$1" "$2" <<'EOF2'
import json, os, sys
path, mode = os.path.realpath(sys.argv[1]), sys.argv[2]
p = os.path.expanduser("~/.claude.json")
d = json.load(open(p))
projects = d.setdefault("projects", {})
if mode == "on":
    projects.setdefault(path, {})["hasTrustDialogAccepted"] = True
else:
    projects.pop(path, None)
tmp = p + ".cloud-review.tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, p)
EOF2
}

meta() { sed -n "s/^$2=//p" "$1/meta" | head -1; }

projects_dir() {
  python3 -c 'import os,re,sys; print(os.path.expanduser("~/.claude/projects/") + re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(sys.argv[1])))' "$1"
}

cmd_run() {
  local repo="" ref="" brief="" name="" model="claude-fable-5-1" OPTIND opt
  while getopts "C:r:b:n:m:h" opt; do
    case $opt in
      C) repo=$OPTARG ;; r) ref=$OPTARG ;; b) brief=$OPTARG ;; n) name=$OPTARG ;; m) model=$OPTARG ;;
      h) usage; exit 0 ;; *) usage; exit 1 ;;
    esac
  done
  [ -n "$ref" ] && [ -n "$brief" ] && [ -n "$name" ] || { usage; exit 1; }
  [ -f "$brief" ] || die "brief not found: $brief"
  [ -n "$repo" ] || repo=$(git rev-parse --show-toplevel)
  local sha; sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}") || die "unknown ref $ref in $repo"

  mkdir -p "$RUNS"
  local run; run="$RUNS/$name-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$run"
  # A fresh one-branch repo: the bundle carries only this history, not every local branch.
  git init -q "$run/repo"
  git -C "$run/repo" fetch -q --no-tags "$repo" "$sha" > "$run/fetch-git.log" 2>&1 \
    || die "git fetch of $sha failed, see $run/fetch-git.log"
  git -C "$run/repo" checkout -q -b "review/$name" FETCH_HEAD
  set_trust "$run/repo" on

  local bin; bin=$(claude_bin)
  {
    cat <<EOF
You are a code reviewer in a Claude Code cloud session. The repository was uploaded as a git bundle of one
branch (HEAD = $sha); it has no remote and you cannot push. Nothing outside the repository is reachable:
local absolute paths, stands, GitLab, files a brief names by absolute path. Work read-only (git, grep, reading
files); do not edit, commit or run the test suite. Start your first message with your model id.
Your final message is the review itself, complete and self-contained; its last line is exactly $DONE_MARK

EOF
    cat "$brief"
  } > "$run/prompt.md"
  printf 'name=%s\nref=%s\nsha=%s\nmodel=%s\nsource=%s\nstarted=%s\n' \
    "$name" "$ref" "$sha" "$model" "$repo" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$run/meta"

  # --cloud refuses --print; a pseudo-terminal lets the interactive create run unattended.
  local rc=0
  (cd "$run/repo" && CCR_FORCE_BUNDLE=1 in_pty "$run/create.typescript" 300 \
      "$bin" --model "$model" --cloud "$(cat "$run/prompt.md")" < /dev/null > /dev/null 2>&1) || rc=$?
  local session
  session=$(LC_ALL=C grep -a -o 'session_[A-Za-z0-9]*' "$run/create.typescript" | head -1 || true)
  if [ -z "$session" ]; then
    LC_ALL=C sed -E 's/\x1b\[[0-9;?<>]*[a-zA-Z]//g' "$run/create.typescript" | tr -d '\r' | grep -a -v '^[[:space:]]*$' | tail -15 >&2
    die "no cloud session created (exit $rc), see $run/create.typescript"
  fi
  echo "session=$session" >> "$run/meta"
  echo "run: $run"
  echo "session: $session"
  echo "view: https://claude.ai/code/$session"
}

cmd_fetch() {
  local run=${1:?run dir}; [ -f "$run/meta" ] || die "not a run dir: $run"
  local session model bin pdir
  session=$(meta "$run" session); model=$(meta "$run" model)
  [ -n "$session" ] || die "no session in $run/meta"
  bin=$(claude_bin)
  (cd "$run/repo" && with_timeout 240 "$bin" -p --model haiku --teleport "$session" \
      "Reply with the single word OK. Do not run any tools." > "$run/teleport.log" 2>&1) \
    || die "teleport failed, see $run/teleport.log"
  pdir=$(projects_dir "$run/repo")
  local jsonl; jsonl=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -1)
  [ -n "$jsonl" ] || die "no teleported transcript in $pdir"
  # Last message of the cloud model (the local haiku turn is skipped), all its text blocks.
  python3 - "$jsonl" "$model" "$run" "$DONE_MARK" <<'EOF'
import json, sys
path, model, run, mark = sys.argv[1:5]
rows = [json.loads(l) for l in open(path)]
asst = [r for r in rows if r.get("type") == "assistant" and r["message"].get("model") == model]
usage = {}
for r in asst:
    u = r["message"].get("usage") or {}
    for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"):
        usage[k] = usage.get(k, 0) + (u.get(k) or 0)
json.dump({"model": model, "messages": len(asst), **usage}, open(f"{run}/usage.json", "w"), indent=2)
texted = [r for r in asst if any(c.get("type") == "text" for c in r["message"]["content"])]
if not texted:
    print(f"no {model} text yet ({len(asst)} assistant rows)"); sys.exit(2)
last_id = texted[-1]["message"].get("id")
text = "\n".join(c["text"] for r in texted if r["message"].get("id") == last_id
                 for c in r["message"]["content"] if c.get("type") == "text").strip()
if not text.rstrip().endswith(mark):
    print("not finished; last text: " + text[-300:].replace("\n", " ")); sys.exit(2)
open(f"{run}/final.md", "w").write(text[: text.rstrip().rfind(mark)].rstrip() + "\n")
print(f"done: {run}/final.md ({len(text)} chars, {len(asst)} {model} rows)")
EOF
}

cmd_wait() {
  local run=${1:?run dir} interval=${2:-120} deadline=${3:-2700} start rc
  start=$(date +%s)
  while :; do
    # Sleep first: the session needs a couple of minutes, and every fetch is a teleport.
    sleep "$interval"
    rc=0; cmd_fetch "$run" || rc=$?
    [ "$rc" -ne 2 ] && return "$rc"
    [ $(( $(date +%s) - start )) -ge "$deadline" ] && { echo "cloud-review: deadline ${deadline}s reached" >&2; return 2; }
  done
}

cmd_clean() {
  local run=${1:?run dir}; [ -f "$run/meta" ] || die "not a run dir: $run"
  rm -rf "$(projects_dir "$run/repo")"
  set_trust "$run/repo" off
  rm -rf "$run/repo"
  echo "cleaned: $run (meta, prompt, final.md kept)"
}

main() {
  case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    fetch) shift; cmd_fetch "$@" ;;
    wait) shift; cmd_wait "$@" ;;
    clean) shift; cmd_clean "$@" ;;
    -h|--help|"") usage ;;
    *) usage; exit 1 ;;
  esac
}

# One line, read whole before it runs: bash reads a script as it executes, so a copy of this file
# overwritten during a long `wait` must not be read past this point.
main "$@"; exit $?
