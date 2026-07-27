#!/usr/bin/env bash
# Cut a Pulse release.
#
#   ./scripts/release.sh 0.23.0          # dry run: bump, run gates, show the diff
#   ./scripts/release.sh 0.23.0 --tag    # commit + annotated tag (still local)
#
# Then `git push && git push --tags` — pushing the tag triggers
# .github/workflows/release.yml, which builds the DMG on macOS and publishes
# the GitHub Release using this version's CHANGELOG section as the body.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
MODE="${2:-}"

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <MAJOR.MINOR.PATCH> [--tag]" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: '$VERSION' is not MAJOR.MINOR.PATCH" >&2
  exit 2
fi

MODELS="PulseBar/Sources/PulseBar/Models.swift"
CURRENT="$(sed -n 's/.*static let semver = "\([^"]*\)".*/\1/p' "$MODELS")"
echo "current: $CURRENT"
echo "release: $VERSION"

if [[ "$MODE" == "--tag" ]]; then
  # A tag must describe a known tree, so refuse to cut one from a dirty repo.
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty — commit or stash first" >&2
    git status --short >&2
    exit 1
  fi
  if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "error: tag v$VERSION already exists" >&2
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
p = pathlib.Path("PulseBar/Sources/PulseBar/Models.swift")
text = p.read_text()
new = re.sub(r'static let semver = "[^"]*"', f'static let semver = "{version}"', text, count=1)
if new != text:
    p.write_text(new)
PY

python3 scripts/version_check.py --fix
python3 scripts/version_check.py
python3 scripts/coverage_check.py
python3 scripts/matrix_check.py
python3 -m py_compile src/*.py scripts/*.py

for py in activity_scan.py pulse_hook.py install_hooks.py; do
  cmp -s "src/$py" "PulseBar/Sources/PulseBar/Resources/$py" \
    || { echo "error: PulseBar/Sources/PulseBar/Resources/$py is stale — run package.sh" >&2; exit 1; }
done

if [[ "$MODE" != "--tag" ]]; then
  echo
  echo "--- dry run: nothing committed ---"
  git --no-pager diff --stat
  echo
  echo "next: $0 $VERSION --tag"
  exit 0
fi

git add -A
if git diff --cached --quiet; then
  # The version was already committed (e.g. tagging a green CI commit after
  # the fact). Nothing to record — just tag what is already there.
  echo "nothing to commit; tagging the current commit"
else
  git commit -m "Release $VERSION"
fi
git tag -a "v$VERSION" -m "Pulse $VERSION"

echo
echo "tagged v$VERSION (local)"
echo "next:  git push && git push --tags"
