#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: Tools/CI/ci.sh <fast|extended|release|lint|format>

  fast      Clean-checkout tests without RimeKit or a simulator runtime.
  extended  fast + serialized native harnesses + unsigned Debug app builds.
  release   extended + installed RimeKit check + unsigned Release builds.
  lint      swift-format (strict), shellcheck and ruff on tracked sources.
  format    Rewrite tracked Swift sources with swift-format; apply ruff fixes.

Build output:
  CI_OUTPUT_ROOT Root for logs, DerivedData and products of every mode
                 (default: .local/ci). Release products land in
                 $CI_OUTPUT_ROOT/app-builds/Release-<simulator|device>.

Environment for extended/release:
  DEVELOPER_DIR  Full Xcode developer directory (required if xcode-select is CLT).
  XCODE_DEV_DIR  Same Xcode directory for Tools/BuildRimeIOS native harnesses.
  Native harnesses require the pinned macOS librime sources, static prefix and
  generated build_config.h from Tools/BuildRime. NATIVE_ENGINE_ROOT may select
  an existing read-only engine root; LIBRIME_BUILD_CONFIG may select its header.
  These ignored inputs are not needed for fast, grammar-window or app builds.
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 64; }

fast() {
  python3 -m unittest discover -s "${ROOT}/Tests/ProjectStructure" -p 'test_*.py' -v
  # Keep the selected full Xcode in this shell for both package tests and the
  # subsequent production-source probes (which may compile SwiftUI macros).
  source "${SCRIPT_DIR}/scripts/lib/xcode.sh"
  require_xcode
  "${SCRIPT_DIR}/scripts/test-swift-packages.sh"
  # Offline production-source probes; no RimeKit prefix or Simulator runtime needed.
  python3 -m unittest discover -s "${ROOT}/Tests/IOS" -p 'test_*.py' -v
}

extended() {
  fast
  # Compile and exercise the production quick-symbol model and the shared
  # cross-process store. These probes need Xcode/Combine, not a Simulator.
  python3 -m unittest discover -s "${ROOT}/Tests/IOS" -p 'extended_*.py' -v
  "${SCRIPT_DIR}/scripts/run-native-harnesses.sh"
  "${SCRIPT_DIR}/scripts/build-app.sh" Debug simulator
  "${SCRIPT_DIR}/scripts/build-app.sh" Debug device
}

# Tracked sources only, so package build directories and vendored engine
# artifacts are never linted.
tracked() {
  git -C "${ROOT}" ls-files -z -- "$@" ':!:Packages/*/Vendored/**'
}

# FuzzyPinyinState.swift is a template with production code spliced in by its
# test, so it does not parse on its own.
swift_sources() {
  tracked 'Apps/*.swift' 'Packages/*.swift' 'Tools/*.swift' 'Tests/*.swift' \
    ':!:Tests/IOS/Fixtures/FuzzyPinyinState.swift'
}

# Prefer an installed ruff; otherwise run it through uv or pipx.
run_ruff() {
  if command -v ruff >/dev/null 2>&1; then
    ruff "$@"
  elif command -v uvx >/dev/null 2>&1; then
    uvx ruff "$@"
  elif command -v pipx >/dev/null 2>&1; then
    pipx run ruff "$@"
  else
    missing_tool ruff
  fi
}

# A missing optional linter is skipped locally but fails on CI.
missing_tool() {
  printf 'warning: %s is not installed; skipping it.\n' "$1" >&2
  [[ -z "${CI:-}" ]]
}

lint() {
  cd "${ROOT}"
  swift_sources | xargs -0 xcrun swift-format lint --strict --configuration .swift-format
  if command -v shellcheck >/dev/null 2>&1; then
    tracked '*.sh' | xargs -0 shellcheck
  else
    missing_tool shellcheck
  fi
  run_ruff check .
}

format() {
  cd "${ROOT}"
  swift_sources | xargs -0 xcrun swift-format format --in-place --configuration .swift-format
  run_ruff check --fix .
}

case "$1" in
  lint)
    lint
    ;;
  format)
    format
    ;;
  fast)
    fast
    ;;
  extended)
    extended
    ;;
  release)
    extended
    python3 "${ROOT}/Tools/BuildRimeIOS/scripts/export-rimekit.py" --check
    "${SCRIPT_DIR}/scripts/build-app.sh" Release simulator
    "${SCRIPT_DIR}/scripts/build-app.sh" Release device
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
