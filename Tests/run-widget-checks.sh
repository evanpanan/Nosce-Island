#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
nosce_widget_test_dir=$(mktemp -d)
trap 'rm -rf "$nosce_widget_test_dir"' EXIT
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  Shared/IslandQuote.swift Shared/HyperliquidWire.swift Shared/WidgetSnapshot.swift \
  LiveActivity/WidgetQuoteFetcher.swift Tests/WidgetChecks.swift \
  -o "$nosce_widget_test_dir/widget-checks"
"$nosce_widget_test_dir/widget-checks" "$PWD/Tests/Fixtures/snapshot-native.json"
