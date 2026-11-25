#!/usr/bin/env bash
# Fork only: decides whether Fork Auto Release should promote the current
# nightly today. Run from a full clone of the fork by fork-auto-release.yml.
#
# It promotes only when all of these hold:
#   - nightly is main's head
#   - main contains an upstream release (vX.Y.Z) that the current Latest
#     release does not contain, i.e. the fork has synced to a new release
#   - Fork Release Check recorded a pass for this commit and these assets
#   - that pass is at least OBSERVE_HOURS old (default 24)
#   - no run of the build, test, Docker or check workflows for this commit
#     failed since that pass
#
# Writes release=true|false and details to $GITHUB_OUTPUT. Exits 1 when a
# check failed, so the run turns red and GitHub notifies the repository owner;
# "nothing to do yet" exits 0.
set -euo pipefail

REPO=${GITHUB_REPOSITORY:?}
UPSTREAM=${UPSTREAM:-EasyTier/EasyTier}
OBSERVE_HOURS=${OBSERVE_HOURS:-24}
OUT=${GITHUB_OUTPUT:-/dev/null}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
NOW=${NOW:-$(date -u +%s)}

note() { echo "$*"; echo "$*" >> "$SUMMARY"; }
finish() { # release reason
  echo "release=$1" >> "$OUT"
  note ""
  if [ "$1" = true ]; then note "**Promoting:** $2"; else note "**Not promoting:** $2"; fi
  exit 0
}
blocked() {
  echo "release=false" >> "$OUT"
  note ""
  note "**Blocked:** $*"
  echo "::error::$*"
  exit 1
}
epoch() { date -u -d "$1" +%s; }
when() { date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'; }

note "### Fork Auto Release"
note ""

# ------------------------------------------------------------- candidate
SHA=$(gh api "repos/$REPO/git/ref/tags/nightly" --jq .object.sha 2>/dev/null || true)
MAIN=$(gh api "repos/$REPO/branches/main" --jq .commit.sha)
[ -n "$SHA" ] || finish false "there is no nightly release; Nightly has not published main yet."
if [ "$SHA" != "$MAIN" ]; then
  finish false "nightly is ${SHA:0:8} but main is ${MAIN:0:8}; waiting for Nightly to publish main."
fi
echo "sha=$SHA" >> "$OUT"
note "- Candidate: nightly at \`${SHA:0:8}\` (main)"

# ------------------------------------------------- new upstream release?
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/$UPSTREAM.git"
UP_TAG=
for tag in $(git ls-remote --tags --refs upstream 'refs/tags/v*' | sed 's|.*refs/tags/||' |
             grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV); do
  git fetch -q --no-tags upstream "+refs/tags/$tag:refs/tags/upstream/$tag"
  if git merge-base --is-ancestor "upstream/$tag" "$SHA"; then UP_TAG=$tag; break; fi
done
[ -n "$UP_TAG" ] || finish false "main contains no upstream release tag."
echo "up_tag=$UP_TAG" >> "$OUT"
note "- Newest upstream release in main: \`$UP_TAG\`"

LATEST=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null || true)
if [ -n "$LATEST" ]; then
  git fetch -q --no-tags origin "+refs/tags/$LATEST:refs/tags/$LATEST"
  echo "latest=$LATEST" >> "$OUT"
  note "- Current Latest: \`$LATEST\`"
  if git merge-base --is-ancestor "upstream/$UP_TAG" "refs/tags/$LATEST^{commit}"; then
    finish false "Latest \`$LATEST\` already includes $UP_TAG; waiting for the next upstream release."
  fi
else
  note "- Current Latest: none"
fi

# --------------------------------------------------- recorded pass + age
gh release download nightly --repo "$REPO" --pattern SHA256SUMS --dir "$RUNNER_TEMP/auto-release-now" --clobber
SUMS_NOW=$(sha256sum "$RUNNER_TEMP/auto-release-now/SHA256SUMS" | cut -d' ' -f1)

PASSED_AT=
PASS_RUN=
while IFS=$'\t' read -r id created run; do
  [ -n "$id" ] || continue
  meta=$(gh api "repos/$REPO/actions/runs/$run" --jq '[.path, .head_branch, .event, .conclusion] | join(" ")')
  read -r path branch event conclusion <<<"$meta"
  case "$path" in
    .github/workflows/fork-release-check.yml|.github/workflows/fork-promote.yml|.github/workflows/fork-auto-release.yml) ;;
    *) continue ;;
  esac
  if [ "$branch" != main ] || [ "$event" = pull_request ] || [ "$conclusion" != success ]; then continue; fi
  rm -rf "$RUNNER_TEMP/auto-release-verdict"
  mkdir -p "$RUNNER_TEMP/auto-release-verdict"
  gh api "repos/$REPO/actions/artifacts/$id/zip" > "$RUNNER_TEMP/auto-release-verdict.zip"
  unzip -q -o "$RUNNER_TEMP/auto-release-verdict.zip" -d "$RUNNER_TEMP/auto-release-verdict"
  v="$RUNNER_TEMP/auto-release-verdict/verdict.json"
  if [ "$(jq -r .sha "$v")" = "$SHA" ] && [ "$(jq -r .sums "$v")" = "$SUMS_NOW" ]; then
    t=$(epoch "$created")
    if [ -z "$PASSED_AT" ] || [ "$t" -lt "$PASSED_AT" ]; then PASSED_AT=$t; PASS_RUN=$(jq -r .run "$v"); fi
  fi
done < <(gh api "repos/$REPO/actions/artifacts?name=fork-release-verdict-$SHA&per_page=100" \
           --jq '.artifacts[] | select(.expired | not) | [.id, .created_at, .workflow_run.id] | @tsv')

# Runs of these workflows for this commit must not fail during observation.
WATCHED='.github/workflows/(core|gui|mobile|test|nightly|fork-docker|fork-release-check)\.yml'
failures_since() { # epoch -> "name: url" lines
  local since
  since=$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)
  gh api --paginate "repos/$REPO/actions/runs?branch=main&head_sha=$SHA&created=%3E%3D$since&per_page=100" \
    --jq '.workflow_runs[] | select(.event != "pull_request")
          | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure")
          | [.path, .name, .html_url] | @tsv' |
    grep -E "^$WATCHED"$'\t' | cut -f2,3 | sed 's/\t/: /' || true
}

if [ -z "$PASSED_AT" ]; then
  # No pass yet. If the latest check of this commit failed, say so loudly.
  last=$(gh api "repos/$REPO/actions/workflows/fork-release-check.yml/runs?branch=main&head_sha=$SHA&per_page=20" \
    --jq '[.workflow_runs[] | select(.event != "pull_request" and .status == "completed")][0] | [.conclusion, .html_url] | @tsv' 2>/dev/null || true)
  if [ "${last%%$'\t'*}" = failure ]; then
    blocked "Fork Release Check failed for ${SHA:0:8} ($UP_TAG): ${last#*$'\t'}"
  fi
  finish false "Fork Release Check has not recorded a pass for ${SHA:0:8} yet."
fi
echo "check_run=$PASS_RUN" >> "$OUT"
note "- Fork Release Check passed at $(when "$PASSED_AT"): $PASS_RUN"

failed=$(failures_since "$PASSED_AT")
if [ -n "$failed" ]; then
  note ""
  note "Failed since the pass:"
  while IFS= read -r line; do note "- $line"; done <<<"$failed"
  blocked "a run for ${SHA:0:8} failed during the observation period; not promoting $UP_TAG."
fi

READY_AT=$((PASSED_AT + OBSERVE_HOURS * 3600))
if [ "$NOW" -lt "$READY_AT" ]; then
  finish false "observing for ${OBSERVE_HOURS}h after the pass; earliest promotion $(when "$READY_AT")."
fi
finish true "${SHA:0:8} contains upstream $UP_TAG, passed Fork Release Check and nothing failed in the ${OBSERVE_HOURS}h since."
