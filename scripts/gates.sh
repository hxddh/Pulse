#!/usr/bin/env bash
# Every source gate, in one place.
#
# CI, release.yml, scripts/release.sh and PulseBar/Scripts/package.sh all
# call this; adding a gate is one line here. 23.0 cut the list to the gates
# that still guard a real fact: the four catalog gates became one, and the
# greps for long-deleted code went.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 scripts/version_check.py            # PulseVersion.semver == CHANGELOG == README
python3 scripts/catalog_check.py            # roster, processes, privacy, README matrix, hook sources
python3 scripts/make_agent_icons.py --check # every agent has its icon
python3 scripts/appearance_check.py         # no colour frozen into a constant
python3 scripts/surface_check.py            # surfaces render values, not the store
python3 scripts/scenario_map.py             # every scenario's named tests exist
python3 -m py_compile scripts/*.py

# SwiftPM's generated Bundle.module accessor fatalErrors when the bundle moves
# (the 0.21–0.23 launch crash). PulseResources resolves it and returns nil.
if grep -rnE --include='*.swift' '^[^/]*[^.a-zA-Z]Bundle\.module' PulseBar/Sources; then
  echo "::error::use PulseResources instead of Bundle.module — it fatalErrors when the bundle moves"
  exit 1
fi
echo "gates OK"
