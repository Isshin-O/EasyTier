#!/usr/bin/env bash
# Fork only: release gate for the current `nightly` prerelease, run by Fork
# Release Check. It decides what would be promoted and refuses anything that
# is not exactly main, fully built and tested, based on an upstream release
# and backed by a Fork Docker image of the same commit.
#
# Needs: GH_TOKEN, GITHUB_REPOSITORY, a full clone of this repository in the
# working directory, docker buildx, jq.
# Env:   STRICT=true   any failed check fails the script (false on PRs)
#        ASSETS_DIR    where the candidate assets are downloaded (candidate)
# Writes key=value lines to $GITHUB_OUTPUT and a report to $GITHUB_STEP_SUMMARY.

set -uo pipefail

REPO=$GITHUB_REPOSITORY
UPSTREAM=EasyTier/EasyTier
STRICT=${STRICT:-true}
ASSETS_DIR=${ASSETS_DIR:-candidate}
OUTPUT=${GITHUB_OUTPUT:-/dev/stdout}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stderr}
# Assets the platform tests need. Promote still checks every asset.
WANTED=(
  'easytier-linux-x86_64-*.zip'
  'easytier-linux-aarch64-*.zip'
  'easytier-windows-x86_64-*.zip'
  'easytier-gui_*_x64-setup.exe'
  'app-x86_64-release.apk'
  'SHA256SUMS'
)

FAILED=0
REPORT=()
pass() { REPORT+=("| ✅ | $* |"); echo "ok: $*"; }
fail() { REPORT+=("| ❌ | $* |"); echo "::error::$*"; FAILED=1; }
warn() { REPORT+=("| ⚠️ | $* |"); echo "::warning::$*"; }
out() { echo "$1=$2" >> "$OUTPUT"; }

report() {
  {
    echo "### Release gate"
    echo
    echo "Candidate: \`${SHA:-?}\` → release \`${TAG:-?}\`, image \`${IMAGE:-?}@${DIGEST:-?}\`"
    echo
    echo "| | Check |"
    echo "|---|---|"
    printf '%s\n' "${REPORT[@]}"
    echo
    echo "${DETAILS:-}"
  } >> "$SUMMARY"
}
trap report EXIT

# ------------------------------------------------------------ nightly release

release=$(gh api "repos/$REPO/releases/tags/nightly") || { fail "No nightly release."; exit 1; }
SHA=$(gh api "repos/$REPO/git/ref/tags/nightly" --jq .object.sha)
SHA8=${SHA:0:8}
MAIN=$(gh api "repos/$REPO/branches/main" --jq .commit.sha)
out sha "$SHA"
out sha8 "$SHA8"

if [ "$(jq -r '.draft or (.prerelease | not)' <<<"$release")" = false ]; then
  pass "nightly is a published prerelease"
else
  fail "nightly must be a published prerelease"
fi
if jq -e --arg s "$SHA" '.body | contains("Commit: [" + $s + "]")' <<<"$release" >/dev/null; then
  pass "nightly notes and tag both name $SHA8"
else
  fail "nightly notes do not match its tag $SHA8; the last Nightly Release did not finish"
fi
if [ "$SHA" = "$MAIN" ]; then
  pass "nightly is the head of main"
else
  # After a history rewrite nightly-release.js skips publishing (it sees the
  # old nightly as newer), so a "successful" Nightly can leave this stale.
  fail "nightly is $SHA8 but main is ${MAIN:0:8}; delete the nightly release and run Nightly again"
fi

asset=$(jq -r '.assets[].name | select(test("^easytier-linux-x86_64-v.*\\.zip$"))' <<<"$release" | head -n 1)
VERSION=${asset#easytier-linux-x86_64-}
VERSION=${VERSION%.zip}
TAG="$VERSION-$SHA8"
IMAGE="ghcr.io/${GITHUB_REPOSITORY_OWNER:-${REPO%%/*}}/easytier"
IMAGE=${IMAGE,,}
out version "$VERSION"
out tag "$TAG"
out image "$IMAGE"
if [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then pass "version $VERSION, release tag $TAG"
else fail "cannot read the version from the nightly assets"; fi

if gh api "repos/$REPO/releases/tags/$TAG" >/dev/null 2>&1; then
  if [ "${PROMOTE:-false}" = true ]; then fail "release $TAG already exists"
  else warn "release $TAG already exists; Promote would refuse it"; fi
else
  pass "release $TAG does not exist yet"
fi

# ------------------------------------------------------------ builds and tests

# The Nightly builds of this commit, the same runs nightly-release.js uses.
# Every job must have succeeded. Only the PR-only "Check" jobs may be skipped:
# they are replaced by the full build jobs in a dispatched run.
check_runs() {
  local wf=$1 required=$2 run id url jobs bad
  run=$(gh api "repos/$REPO/actions/workflows/$wf.yml/runs?branch=main&event=workflow_dispatch&status=success&head_sha=$SHA&per_page=1" \
    --jq '.workflow_runs[0] // empty')
  if [ -z "$run" ]; then fail "$wf: no successful full build of $SHA8"; return; fi
  id=$(jq -r .id <<<"$run")
  url=$(jq -r .html_url <<<"$run")
  jobs=$(gh api --paginate "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100" \
    --jq '.jobs[] | [.name, (.conclusion // "none")] | @tsv')
  bad=$(awk -F'\t' '$2 != "success" && !($2 == "skipped" && $1 ~ /^Check( |$)/) {print $1 " (" $2 ")"}' <<<"$jobs")
  if [ -n "$bad" ]; then
    fail "$wf [run]($url): $(paste -sd ';' <<<"$bad")"
    return
  fi
  local name missing=""
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    grep -qF "$name" <<<"$jobs" || missing="$missing $name;"
  done <<<"$required"
  if [ -n "$missing" ]; then fail "$wf [run]($url): missing jobs:$missing"; return; fi
  pass "$wf [run]($url): $(wc -l <<<"$jobs") jobs succeeded"
}

check_runs core "build (x86_64-unknown-linux-musl
build (aarch64-unknown-linux-musl
build (x86_64-pc-windows-msvc"
check_runs gui "build-gui (x86_64-pc-windows-msvc"
check_runs mobile "build-mobile (x86_64)
build-mobile (aarch64)"
check_runs test "Run linters & check
Run tests
Test CI scripts"

# ------------------------------------------------------------ Docker image

if raw=$(docker buildx imagetools inspect --raw "$IMAGE:$TAG" 2>/dev/null); then
  DIGEST=$(docker buildx imagetools inspect "$IMAGE:$TAG" --format '{{json .Manifest}}' | jq -r .digest)
  out digest "$DIGEST"
  platforms=$(jq -r '[.manifests[]?.platform | select(.os != "unknown") | .os + "/" + .architecture] | sort | join(",")' <<<"$raw")
  if [ "$platforms" = "linux/amd64,linux/arm64" ]; then pass "image $TAG has $platforms"
  else fail "image $TAG has platforms '$platforms', expected linux/amd64,linux/arm64"; fi
  nightly_digest=$(docker buildx imagetools inspect "$IMAGE:nightly" --format '{{json .Manifest}}' 2>/dev/null | jq -r .digest)
  [ "$nightly_digest" = "$DIGEST" ] && pass ":nightly is the same image" \
    || warn ":nightly ($nightly_digest) is not $TAG; Fork Docker may still be running"
else
  fail "Fork Docker image $IMAGE:$TAG does not exist"
fi

# ------------------------------------------------------------ upstream base

git fetch -q --no-tags origin "+refs/tags/nightly:refs/tags/nightly" "+refs/heads/main:refs/remotes/origin/main"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/$UPSTREAM.git"
git fetch -q --no-tags upstream main
# The newest plain vX.Y.Z tag upstream, i.e. its latest official release.
UP_TAG=$(git ls-remote --tags --refs upstream 'refs/tags/v*' | sed 's|.*refs/tags/||' |
  grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
if [ -z "$UP_TAG" ]; then
  fail "cannot list upstream release tags"
elif git fetch -q --no-tags upstream "+refs/tags/$UP_TAG:refs/tags/upstream/$UP_TAG" &&
   git merge-base --is-ancestor "upstream/$UP_TAG" "$SHA"; then
  pass "based on upstream release $UP_TAG"
else
  fail "does not contain upstream release $UP_TAG; sync with upstream first"
fi
conf_version=v$(git show "$SHA:easytier-gui/src-tauri/tauri.conf.json" | jq -r .version)
[ "$conf_version" = "$VERSION" ] || warn "tauri.conf.json says $conf_version, assets say $VERSION"
[ "$VERSION" = "$UP_TAG" ] || warn "version $VERSION differs from upstream's latest release $UP_TAG"

BASE=$(git merge-base "$SHA" upstream/main)
fork_commits=$(git log --format='%h %s' "$BASE..$SHA")
behind=$(git rev-list --count "$SHA..upstream/main")
pass "$(wc -l <<<"$fork_commits") fork commits on upstream ${BASE:0:8}; upstream main is $behind commits ahead"
DETAILS=$(printf '<details><summary>Fork commits in this release</summary>\n\n```\n%s\n```\n</details>\n' "$fork_commits")

# A pending conflict does not make this build unsafe, but next week's sync
# will stop, so say so now.
if [ "$behind" -gt 0 ]; then
  tmp=$(mktemp -d)
  git worktree add -q --detach "$tmp" "$SHA"
  if git -C "$tmp" -c user.name=gate -c user.email=gate@localhost rebase -q --onto upstream/main "$BASE" >/dev/null 2>&1; then
    pass "fork commits still rebase cleanly onto upstream main"
  else
    files=$(git -C "$tmp" diff --name-only --diff-filter=U | paste -sd ' ')
    warn "rebasing onto current upstream main conflicts in: ${files:-?} (next Fork Sync will stop)"
    git -C "$tmp" rebase --abort >/dev/null 2>&1
  fi
  git worktree remove --force "$tmp"
fi

sync=$(gh api "repos/$REPO/actions/workflows/fork-sync.yml/runs?status=completed&per_page=1" --jq '.workflow_runs[0] // empty')
if [ -n "$sync" ] && [ "$(jq -r .conclusion <<<"$sync")" = failure ]; then
  sync_time=$(jq -r .created_at <<<"$sync")
  commit_time=$(git show -s --format=%cI "$SHA")
  if [[ "$(date -d "$sync_time" +%s)" -gt "$(date -d "$commit_time" +%s)" ]]; then
    warn "the last Fork Sync ($sync_time) failed after this commit; check for an unresolved conflict"
  fi
fi

# ------------------------------------------------------------ candidate assets

rm -rf "$ASSETS_DIR"
mkdir -p "$ASSETS_DIR"
patterns=()
for p in "${WANTED[@]}"; do patterns+=(--pattern "$p"); done
if gh release download nightly --repo "$REPO" --dir "$ASSETS_DIR" "${patterns[@]}"; then
  if (cd "$ASSETS_DIR" && sha256sum --check --ignore-missing --quiet SHA256SUMS); then
    pass "downloaded $(($(ls "$ASSETS_DIR" | wc -l) - 1)) test assets; checksums match SHA256SUMS"
  else
    fail "nightly assets do not match SHA256SUMS"
  fi
  for p in "${WANTED[@]}"; do
    compgen -G "$ASSETS_DIR/$p" >/dev/null || fail "nightly has no $p"
  done
  out sums "$(sha256sum "$ASSETS_DIR/SHA256SUMS" | cut -d' ' -f1)"
else
  fail "could not download the nightly assets"
fi
# Nightly could have moved while we looked; everything above must be one commit.
now=$(gh api "repos/$REPO/git/ref/tags/nightly" --jq .object.sha)
[ "$now" = "$SHA" ] || fail "nightly moved to ${now:0:8} during the check; run it again"

jq -n --arg sha "$SHA" --arg tag "$TAG" --arg version "$VERSION" --arg image "$IMAGE" \
  --arg digest "${DIGEST:-}" --arg sums "$(sha256sum "$ASSETS_DIR/SHA256SUMS" 2>/dev/null | cut -d' ' -f1)" \
  '{sha: $sha, tag: $tag, version: $version, image: $image, digest: $digest, sums: $sums}' > "$ASSETS_DIR/candidate.json"

out ok "$([ "$FAILED" = 0 ] && echo true || echo false)"
if [ "$FAILED" != 0 ] && [ "$STRICT" = true ]; then exit 1; fi
exit 0
