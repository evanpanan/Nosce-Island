#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
nosce_test_dir=$(mktemp -d)
trap 'rm -rf "$nosce_test_dir"' EXIT
xcrun swiftc Shared/HyperliquidWire.swift Tests/WireChecks.swift -o "$nosce_test_dir/wire-checks"
"$nosce_test_dir/wire-checks" "$PWD/Tests/Fixtures"
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" Shared/IslandQuote.swift Tests/QuoteChecks.swift -o "$nosce_test_dir/quote-checks"
"$nosce_test_dir/quote-checks" "$PWD/Tests/Fixtures/server-state.json"
