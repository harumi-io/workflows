#!/usr/bin/env bash
# Self-check for the `Load review prompt` step of claude-code-review.yml.
#
# Extracts that step's script straight out of the workflow (so this cannot drift from what CI runs)
# and exercises the four branches that matter, in a throwaway git repo:
#   1. no marker            -> full review, diff scoped BASE...HEAD
#   2. valid marker         -> incremental review, diff scoped LAST..HEAD, {LAST_COMMIT} substituted
#   3. unreachable marker   -> falls back to a full review rather than an empty one
#   4. oversized diff       -> truncated, with the notice that tells the review to fetch the rest
# Plus: a diff line that looks like the heredoc delimiter must not be able to inject a variable.
#
# Run: bash scripts/check-review-prompt.sh
set -euo pipefail

WORKFLOW="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/claude-code-review.yml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Pull the step's script out of the YAML: everything indented under the `Load review prompt`
# step's `run: |` until the next step begins.
ruby -e '
  lines = File.readlines(ARGV[0])
  start = lines.index { |l| l =~ /name: Load review prompt/ }
  abort "step not found" unless start
  run_at = (start...lines.length).find { |i| lines[i] =~ /^\s+run: \|/ }
  body = []
  lines[(run_at + 1)..].each do |l|
    break if l =~ /^      - name:/
    body << l.sub(/^          /, "")
  end
  File.write(ARGV[1], body.join)
' "$WORKFLOW" "$TMP/step.sh"

test -s "$TMP/step.sh" || { echo "FAIL: extracted an empty script"; exit 1; }

cd "$TMP"
git init -q repo && cd repo
git config user.email t@t.t && git config user.name t
echo "base" > f.txt && git add f.txt && git commit -qm base
BASE=$(git rev-parse HEAD)
echo "one" >> f.txt && git commit -qam one
MID=$(git rev-parse HEAD)
echo "two" >> f.txt && git commit -qam two
HEAD_SHA=$(git rev-parse HEAD)

run_step() { # $1=fake HOME for the marker, rest via env
  HOME="$1" GITHUB_ENV="$TMP/env" GITHUB_OUTPUT="$TMP/out" \
  PROMPT_FULL="FULL REVIEW INSTRUCTIONS" \
  PROMPT_SIMPLE="INCREMENTAL SINCE {LAST_COMMIT}" \
  BASE_SHA="$BASE" HEAD_SHA="$HEAD_SHA" MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-150000}" \
  bash "$TMP/step.sh" > "$TMP/log" 2>&1 || { echo "FAIL: step exited nonzero"; cat "$TMP/log"; exit 1; }
  : > "$TMP/env.prev"; cp "$TMP/env" "$TMP/env.prev"
}
prompt_of() { ruby -e '
  body = File.read(ARGV[0])
  m = body.match(/^REVIEW_PROMPT<<(\S+)\n(.*?)^\1$/m) or abort "no REVIEW_PROMPT block"
  print m[2]
' "$TMP/env"; }

fail() { echo "FAIL: $1"; exit 1; }

# 1. No marker -> full review over BASE...HEAD
rm -f "$TMP/env" "$TMP/out"; mkdir -p "$TMP/h1"
run_step "$TMP/h1"
grep -q "HAS_PREVIOUS_SESSION=false" "$TMP/out" || fail "no marker should mean no previous session"
P=$(prompt_of)
grep -q "FULL REVIEW INSTRUCTIONS" <<<"$P" || fail "full prompt missing"
grep -q "range: ${BASE}\.\.\.${HEAD_SHA}" <<<"$P" || fail "full review should diff BASE...HEAD"
grep -q "^+one" <<<"$P" && grep -q "^+two" <<<"$P" || fail "full diff should carry both commits"
echo "ok 1 - full review, diff inlined over BASE...HEAD"

# 2. Valid marker -> incremental, {LAST_COMMIT} substituted, diff scoped to what is new
rm -f "$TMP/env" "$TMP/out"; mkdir -p "$TMP/h2/.claude/projects"
echo "$MID" > "$TMP/h2/.claude/projects/.last-reviewed-commit"
run_step "$TMP/h2"
grep -q "HAS_PREVIOUS_SESSION=true" "$TMP/out" || fail "valid marker should continue the session"
P=$(prompt_of)
grep -q "INCREMENTAL SINCE ${MID}" <<<"$P" || fail "{LAST_COMMIT} not substituted"
grep -q "range: ${MID}\.\.${HEAD_SHA}" <<<"$P" || fail "incremental should diff LAST..HEAD"
grep -q "^+two" <<<"$P" || fail "incremental diff should carry the new commit"
grep -q "^+one" <<<"$P" && fail "incremental diff must not re-include already-reviewed work"
echo "ok 2 - incremental review scoped to the new commit only"

# 3. Unreachable marker (rebase / force-push) -> full review, not an empty one
rm -f "$TMP/env" "$TMP/out"; mkdir -p "$TMP/h3/.claude/projects"
echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$TMP/h3/.claude/projects/.last-reviewed-commit"
run_step "$TMP/h3"
grep -q "HAS_PREVIOUS_SESSION=false" "$TMP/out" || fail "unreachable marker must fall back to full"
grep -q "unreachable" "$TMP/log" || fail "should say why it fell back"
P=$(prompt_of)
grep -q "FULL REVIEW INSTRUCTIONS" <<<"$P" || fail "fallback should use the full prompt"
grep -q "^+one" <<<"$P" || fail "fallback must review from the base, not an empty range"
echo "ok 3 - unreachable marker falls back to a full review"

# 4. Oversized diff -> truncated, and says so. The threshold has to sit under the real diff size
# (~111 bytes for these two commits), or this asserts nothing.
rm -f "$TMP/env" "$TMP/out"; mkdir -p "$TMP/h4"
FULL_DIFF_BYTES=$(git diff "${BASE}...${HEAD_SHA}" | wc -c | tr -d ' ')
[ "$FULL_DIFF_BYTES" -gt 50 ] || fail "fixture diff too small to exercise truncation"
MAX_DIFF_BYTES=50 run_step "$TMP/h4"
P=$(prompt_of)
grep -q "TRUNCATED at 50 bytes" <<<"$P" || fail "truncation notice missing"
grep -q "git diff ${BASE}\.\.\.${HEAD_SHA}" <<<"$P" || fail "should name the range to fetch the rest"
echo "ok 4 - oversized diff truncated with a recoverable notice"

# 5. A diff that impersonates the heredoc delimiter must not inject an env var
rm -f "$TMP/env" "$TMP/out"; mkdir -p "$TMP/h5"
printf 'REVIEW_PROMPT_EOF_0000\nINJECTED=yes\n' >> f.txt && git commit -qam evil
HEAD_SHA=$(git rev-parse HEAD)
run_step "$TMP/h5"
grep -q "^INJECTED=yes" "$TMP/env" && fail "crafted diff wrote a variable into GITHUB_ENV"
grep -q "INJECTED=yes" <<<"$(prompt_of)" || fail "the crafted line should still be reviewable content"
echo "ok 5 - crafted delimiter stays data, cannot inject into GITHUB_ENV"

# 6. Defaults that are load-bearing for behaviour, not just style.
#    - allowed_bots must stay empty: a bot's PR is mechanical, and reviewing it produces suggestions
#      someone then dismisses by hand. This was set to `github-actions[bot]` once and had to be
#      undone; the check exists so it cannot drift back silently.
#    - extra_allowed_tools must keep Grep, which is the difference between a review that can answer
#      "what else calls this changed function?" and one that can only guess.
ruby -e '
  require "yaml"
  d = YAML.load_file(ARGV[0])
  inputs = (d[true] || d["on"])["workflow_call"]["inputs"]

  bots = inputs.fetch("allowed_bots").fetch("default", nil)
  abort "FAIL: allowed_bots default must be empty, got #{bots.inspect}" unless bots.to_s.empty?

  tools = inputs.fetch("extra_allowed_tools").fetch("default", "")
  %w[Read Grep Glob].each do |t|
    abort "FAIL: extra_allowed_tools default lost #{t}" unless tools.include?(t)
  end
  abort "FAIL: extra_allowed_tools needs a trailing comma" unless tools.end_with?(",")

  turns = inputs.fetch("max_turns").fetch("default")
  abort "FAIL: max_turns default #{turns} too low; 30 truncated real reviews" unless turns >= 80
' "$WORKFLOW"
echo "ok 6 - load-bearing defaults intact (no bot reviews, search allowed, turns >= 80)"

# 7. The reporting protocol must reach every prompt, in both branches. This is what keeps a run that
#    hits the turn ceiling from having produced nothing: findings go out as they are confirmed, and
#    always as a plain PR comment — never as an inline/diff-attached suggestion.
for h in h1 h2; do
  rm -f "$TMP/env" "$TMP/out"
  run_step "$TMP/$h"
  P=$(prompt_of)
  grep -q "Post each finding as its own comment with .gh pr comment" <<<"$P" \
    || fail "$h: prompt must direct findings to gh pr comment"
  grep -q "Never post it as an inline or diff-attached review comment" <<<"$P" \
    || fail "$h: prompt must forbid inline/diff-attached comments"
  grep -q "AS SOON AS you have confirmed it" <<<"$P" || fail "$h: prompt must forbid batching"
  grep -q "highest-severity first" <<<"$P" || fail "$h: prompt must order by severity"
  grep -q "not post a duplicate" <<<"$P" || fail "$h: prompt must guard against re-posting"
done
echo "ok 7 - reporting protocol (plain PR comments, no inline suggestions) present in both branches"

# 8. The inline-comment MCP tool must NOT be allowed — that is what makes a finding render as a
#    diff-attached suggestion instead of a plain comment, which is the behaviour this whole
#    workflow exists to avoid. Also pin the timeout, since turns do not bound wall-clock.
ruby -e '
  require "yaml"
  d = YAML.load_file(ARGV[0])
  args = d["jobs"]["code-review"]["steps"].find { |s| s["name"] == "Run Claude Code Review" }["with"]["claude_args"]
  if args.include?("mcp__github_inline_comment__create_inline_comment")
    abort "FAIL: inline-comment tool is allowed; findings would render as diff-attached suggestions"
  end
  job = d["jobs"]["code-review"]
  abort "FAIL: no timeout-minutes on the job" unless job["timeout-minutes"]
  names = job["steps"].map { |s| s["name"] }
  abort "FAIL: no incomplete-review notice step" unless names.include?("Report an incomplete review")
  notice = job["steps"].find { |s| s["name"] == "Report an incomplete review" }
  abort "FAIL: notice must run on failure" unless notice["if"].to_s.include?("failure()")
  saver = job["steps"].find { |s| s["name"] == "Save last reviewed commit" }
  abort "FAIL: marker must only advance on success" unless saver["if"].to_s.include?("success()")
' "$WORKFLOW"
echo "ok 8 - inline-comment tool NOT allowed, timeout set, incomplete runs announced, marker gated on success"

echo "all checks passed"
