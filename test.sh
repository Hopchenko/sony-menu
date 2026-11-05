#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
test_sources=(Sources/SonyMenu/*.swift)
test_sources=(${test_sources:#Sources/SonyMenu/App.swift})
swiftc -swift-version 5 -g -profile-generate -profile-coverage-mapping -module-cache-path /private/tmp/sony-menu-module-cache \
  $test_sources Sources/SonyMenu/Protocol/*.swift Tests/*.swift \
  -o build/SonyMenuChecks -framework AppKit -framework SwiftUI -framework IOBluetooth -framework ServiceManagement -framework CoreAudio
LLVM_PROFILE_FILE="$PWD/build/tests.profraw" build/SonyMenuChecks
xcrun llvm-profdata merge -sparse build/tests.profraw -o build/tests.profdata
xcrun llvm-cov report build/SonyMenuChecks -instr-profile=build/tests.profdata -ignore-filename-regex='Tests/' > build/coverage.txt
cat build/coverage.txt
