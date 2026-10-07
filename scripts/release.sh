#!/usr/bin/env bash
# Cut a Pulse release.
#
#   ./scripts/release.sh 0.23.0            # dry run: bump, run gates, show the diff
#   ./scripts/release.sh 0.23.0 --commit   # commit carrying the [release] marker
#   ./scripts/release.sh 0.23.0 --tag      # commit + local annotated tag
#   ./scripts/release.sh 0.23.0 --commit --prerelease
#                                          # marker `[release] [prerelease]`:
#                                          # a GitHub prerelease, not Latest
#
# Then `git push` (or `git push --tags` for --tag). Either lands in
# .github/workflows/release.yml, which builds the DMG on macOS and publishes the
# GitHub Release using this version's CHANGELOG section as the body.
#
# --commit is the default path: CI creates the tag with its own contents:write
# token, so publishing does not need tag-write rights on your account.
#
# --prerelease (with --commit) publishes the version as a GitHub prerelease:
# GitHub Latest does not show it until the owner
# promotes it on GitHub after a real-Mac smoke run. A tag push is always a
# full release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
MODE=""
PRERELEASE=""
if [[ $# -gt 0 ]]; then shift; fi
for arg in "$@"; do
  case "$arg" in
    --commit|--tag)
      if [[ -n "$MODE" ]]; then
        echo "error: pick one of --commit or --tag" >&2
        exit 2
      fi
      MODE="$arg"
      ;;
    --prerelease) PRERELEASE=" [prerelease]" ;;
    *)
      echo "error: unknown option '$arg' (expected --commit, --tag or --prerelease)" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <MAJOR.MINOR.PATCH> [--commit|--tag] [--prerelease]" >&2
  exit 2
fi
if [[ -n "$PRERELEASE" && "$MODE" == "--tag" ]]; then
  echo "error: --prerelease rides on the commit marker; use --commit --prerelease" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: '$VERSION' is not MAJOR.MINOR.PATCH" >&2
  exit 2
fi

MODELS="PulseBar/Sources/PulseApp/Models.swift"
CURRENT="$(sed -n 's/.*static let semver = "\([^"]*\)".*/\1/p' "$MODELS")"
echo "current: $CURRENT"
echo "release: $VERSION"

if [[ "$MODE" == "--tag" ]]; then
  if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "error: tag v$VERSION already exists" >&2
    exit 1
  fi
fi

if [[ -n "$MODE" ]]; then
  # A release must describe a known tree, so refuse to cut one from a dirty repo
  # beyond the version bump this script is about to make.
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty — commit or stash first" >&2
    git status --short >&2
    exit 1
  fi
fi

# Release notes are not optional.
if ! python3 scripts/changelog_section.py "$VERSION" >/dev/null 2>&1; then
  echo "error: CHANGELOG.md has no '## $VERSION' section — write the notes first" >&2
  exit 1
fi

# Bump the single source of truth, then let the gate pull the followers along.
python3 - "$VERSION" <<'PY'
import pathlib, re, sys
version = sys.argv[1]
p = pathlib.Path("PulseBar/Sources/PulseApp/Models.swift")
text = p.read_text()
new = re.sub(r'static let semver = "[^"]*"', f'static let semver = "{version}"', text, count=1)
if new != text:
    p.write_text(new)
PY

python3 scripts/version_check.py --fix
bash scripts/gates.sh

if [[ -z "$MODE" ]]; then
  echo
  echo "--- dry run: nothing committed ---"
  git --no-pager diff --stat
  echo
  echo "next: $0 $VERSION --commit${PRERELEASE:+ --prerelease}"
  exit 0
fi

# `[release]` in the subject is what .github/workflows/release.yml watches for;
# `[prerelease]` beside it publishes a GitHub prerelease.
SUBJECT="Release $VERSION [release]$PRERELEASE"
git add -A
if git diff --cached --quiet; then
  echo "nothing to commit — the version is already recorded at HEAD"
  if [[ "$MODE" == "--commit" ]]; then
    echo "to publish it, push an empty marker commit:"
    echo "  git commit --allow-empty -m \"$SUBJECT\" && git push"
    exit 1
  fi
else
  git commit -m "$SUBJECT"
fi

if [[ "$MODE" == "--tag" ]]; then
  git tag -a "v$VERSION" -m "Pulse $VERSION"
  echo
  echo "committed and tagged v$VERSION (local)"
  echo "next:  git push && git push --tags"
else
  echo
  echo "committed $SUBJECT"
  echo "next:  git push   — CI will build, tag and publish"
fi
