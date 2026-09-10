#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p evidence
swift test --enable-code-coverage > evidence/swift-tests.log 2>&1
swift test -c release > evidence/release-tests.log 2>&1
python3 scripts/process_acceptance.py
python3 scripts/process_acceptance.py --binary .build/release/switcherctl --output evidence/process-acceptance-release.json
if [[ "${1:-}" == "--local-integration" ]]; then
  .build/release/switcherctl protocol-smoke > evidence/protocol-smoke.log
  .build/release/switcherctl keychain-smoke > evidence/keychain-smoke.log
  .build/release/switcherctl host-check > evidence/host-check.log
fi
printf 'PASS: Swift tests and synthetic subprocess acceptance. See evidence/.\n'
