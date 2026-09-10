#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
exec python3 scripts/package_candidate.py "$@"
