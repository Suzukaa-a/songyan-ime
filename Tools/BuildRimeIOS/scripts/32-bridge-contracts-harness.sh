#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 32-bridge-contracts-harness.sh — macOS production-path proof for the
# panel-independent Rime bridge contracts, against the REAL pinned librime.
#
# Builds the SAME bridge sources (rime_bridge.c + rime_spelling.cc +
# rime_display_map.cc), the RimeBridge wrapper, the RimeBackend mapping and the
# KeyboardCore value types, then runs bridge-contracts-main.swift over a copy of the built-in
# schema tree whose songyan_quanpin declares `menu/alternative_select_keys` and
# `menu/alternative_select_labels`.
#
# Covers:
#   * ascii_mode / full_shape / ascii_punct observation end to end;
#   * RimeMenu.select_keys + RimeContext.select_labels copied per page slot,
#     nil when undeclared (never 1..9, never a comment as a label);
#   * RimeEngine.spellingDemand as a decode gate (false/nil => zero decodes even
#     with an authorized capability block; true still obeys authorization).
#
# Nothing is deleted; all outputs go to a fresh isolated run dir. This does not
# rebuild the iOS XCFramework.
#
# Usage:
#   Tools/BuildRimeIOS/scripts/32-bridge-contracts-harness.sh
# Overrides:
#   BRIDGE_SHARED / BRIDGE_USER / BRIDGE_PREBUILT
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

SHIM_SRC_DIR="${IOS_TOOLS_DIR}/src"

[[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die "missing ${MAC_PREFIX}/lib/librime.a (run Tools/BuildRime)"

# Use the pinned macOS build configuration, optionally selected by its exact path.
GEN_INCLUDE="$(rime_generated_include)"

RUN_DIR="$(new_harness_dir bridge-contracts)"

# Build the menu fixture: a copy of the built-in package whose songyan_quanpin declares the engine's
# own alternative select keys/labels. Other schemas stay untouched so the
# "no declaration -> nil" case is still exercised.
SHARED="${BRIDGE_SHARED:-${RUN_DIR}/shared}"
if [[ -z "${BRIDGE_SHARED:-}" ]]; then
  cp -R "${PROJECT_ROOT}/Resources/BuiltinPackages/Basic" "${SHARED}"
  # songyan_quanpin declares the schema's own menu block. page_size 2 (instead of the
  # default 5) makes the tiny built-in dictionary span multiple real pages, so the
  # cross-page read-only slot consistency can be asserted.
  cat >> "${SHARED}/songyan_quanpin.schema.yaml" <<'YAML'

menu:
  page_size: 2
  alternative_select_keys: "asdfg"
  alternative_select_labels:
    - "甲"
    - "乙"
    - "丙"
    - "丁"
    - "戊"
YAML
fi
[[ -f "${SHARED}/default.yaml" ]] || die "shared data missing: ${SHARED}"
USER_DIR="${BRIDGE_USER:-$(new_isolated_dir "${RUN_DIR}/user")}"

prepare_native_bridge
# Same link set as the T9 harness: the grammar build of the bridge takes
# rb_component_available from rime_grammar_diagnostics.cc (a real registry
# lookup), so RimeBackend enables exactly the schemas this prefix can run.
# The octagram plugin itself is not linked; its requirement hook is a no-op.
compile_bridge_c -DRB_WITH_GRAMMAR=1
cat > "${RUN_DIR}/rb_grammar_noop.cc" <<'EOF'
extern "C" void rb_require_grammar(void) {}
EOF
for shim in rime_spelling rime_display_map rime_grammar_diagnostics; do
  compile_bridge_cpp "${shim}"
done
"${MAC_CXX}" -std=c++17 -O2 -c -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
  "${RUN_DIR}/rb_grammar_noop.cc" -o "${RUN_DIR}/rb_grammar_noop.o"

# Stage the production Swift sources into one module (the app compiles them as
# separate modules; here the cross-module imports are stripped and the unrelated
# App-level EngineOpQueue is stubbed, since the harness never drives it).
say "stage Swift sources"
STAGE="${RUN_DIR}/swift"
mkdir -p "${STAGE}"
PKG="${PROJECT_ROOT}/Packages"
stage() {
  local src="$1" name
  name="$(basename "$src")"
  sed -e '/^import KeyboardCore$/d' -e '/^import RimeBridge$/d' "$src" > "${STAGE}/${name}"
}
for src in "${PKG}"/KeyboardCore/Sources/KeyboardCore/**/*.swift; do stage "$src"; done
for src in "${PKG}"/RimeBridge/Sources/RimeBridge/*.swift; do stage "$src"; done
stage "${PROJECT_ROOT}/Apps/SharedKeyboard/RimeBackend.swift"
stage "${PROJECT_ROOT}/Apps/SharedKeyboard/OptionStore.swift"
cat > "${STAGE}/HarnessEngineOpQueue.swift" <<'EOF'
import Foundation
/// Harness-only stand-in for the App-level `EngineOpQueue`. `RimeBackend`
/// references it for process-wide engine serialization, which this single
/// synchronous harness never exercises.
public enum EngineOpQueue {
    public static func sync<T>(_ body: () throws -> T) throws -> T { try body() }
    public static func async<T>(_ body: @escaping () throws -> T) async throws -> T { try body() }
}
/// The standalone bridge harness never supplies an App Group receipt context.
public enum GrammarRuntimeReceiptStore {
    public struct Context {}
    public static func record(context: Context, sourceSchemaID: String,
                              runtimeSchemaID: String, loadedLanguage: String?) throws {}
}
EOF

# Learning bridge C adapter: same -fno-modules + original public header ABI the
# SPM target uses; emits module map + object into the run dir.
say "compile learning C adapter"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
python3 "${PROJECT_ROOT}/Tools/BuildRimeIOS/scripts/build-learning-support.py" \
  --sdk "${MACOS_SDK}" --target arm64-apple-macos13.0 \
  --kit-include-dir "${MAC_PREFIX}/include" \
  --output-dir "${RUN_DIR}/learning-support"

say "compile + link harness"
swiftc -O -D SONGYAN_TEST_FAILPOINTS -Xcc -fmodule-map-file="${RUN_DIR}/RimeKitModule/module.modulemap" \
  -Xcc -fmodule-map-file="${RUN_DIR}/learning-support/module/module.modulemap" \
  -I "${RUN_DIR}/RimeKitModule" -I "${MAC_PREFIX}/include" -I "${RUN_DIR}/learning-support/module" \
  "${IOS_TOOLS_DIR}/harness-mac/bridge-contracts-main.swift" \
  "${STAGE}"/*.swift \
  "${RUN_DIR}/rime_bridge.o" "${RUN_DIR}/rime_spelling.o" "${RUN_DIR}/rime_display_map.o" \
  "${RUN_DIR}/rime_grammar_diagnostics.o" "${RUN_DIR}/rb_grammar_noop.o" \
  "${RUN_DIR}/learning-support/RimeLeversSupport.o" \
  "${MAC_LINK_FLAGS[@]}" \
  -target arm64-apple-macos13.0 -o "${RUN_DIR}/harness"

say "run harness"
declare -a ARGS=(--shared "${SHARED}" --user "${USER_DIR}")
[[ -n "${BRIDGE_PREBUILT:-}" ]] && ARGS+=(--prebuilt "${BRIDGE_PREBUILT}")
"${RUN_DIR}/harness" "${ARGS[@]}"
say "harness dir: ${RUN_DIR}"
