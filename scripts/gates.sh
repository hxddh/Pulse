#!/usr/bin/env bash
# Every source gate, in one place.
#
# CI, release.yml, scripts/release.sh and PulseBar/Scripts/package.sh each
# used to carry their own copy of this list, and by 11.0 the copies had
# drifted (the release job skipped the Respond hook contract and the lint
# greps). Everything calls this now; adding a gate is one line here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 scripts/version_check.py
python3 scripts/agent_catalog_check.py
python3 scripts/coverage_check.py
python3 scripts/matrix_check.py
python3 scripts/make_agent_icons.py --check
python3 scripts/appearance_check.py
python3 -m py_compile src/*.py scripts/*.py
python3 scripts/respond_hook_check.py

# The legacy Python collector was deleted in 0.99. Nothing in the product may
# fork an interpreter to observe a session again.
if grep -rn "activity_scan" --include='*.swift' PulseBar/Sources; then
  echo "::error::the harvest path must not reference the deleted Python collector"
  exit 1
fi
# SwiftPM's generated Bundle.module accessor fatalErrors when the bundle moves
# (the 0.21–0.23 launch crash). PulseResources resolves it and returns nil.
if grep -rnE --include='*.swift' '^[^/]*[^.a-zA-Z]Bundle\.module' PulseBar/Sources; then
  echo "::error::use PulseResources instead of Bundle.module — it fatalErrors when the bundle moves"
  exit 1
fi
for py in pulse_hook.py install_hooks.py; do
  diff -u "src/$py" "PulseBar/Sources/PulseBar/Resources/$py" \
    || { echo "::error::PulseBar/Sources/PulseBar/Resources/$py is stale — re-run package.sh"; exit 1; }
done
echo "gates OK"
