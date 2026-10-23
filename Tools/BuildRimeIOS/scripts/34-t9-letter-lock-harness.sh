#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 34-t9-letter-lock-harness.sh — REAL-engine evidence for the schema-agnostic
# 9-key letter-class PREFIX lock (long-press ABC → A/B/C).
#
# Compiles the REAL `CompactAdapterDeployment.prepare` (Apps/HostApp) and the
# RimeBridge Swift wrapper against the pinned macOS librime, links the built
# `PackageManager`/`KeyboardCore` modules, and runs `t9-letter-lock-main` over
# two deployments of the SAME real grammar:
#
#   * PROFILE A — a digit-coded 9-key source `t9_digits` (the built-in full
#     pinyin plus the eight telephone derives) with ONE added line
#     (`keyboard_rewrite_prefix: letter_class_v1`). The generator must add the
#     bounded letter-class abbreviation layer to the GENERATED 9-key companion,
#     declare `prefix_token_rewrite_v4` with a bounded `prefix_keys` sample, pass
#     the native candidate-free deploy verification, and make the live report for
#     `2` offer the actual a/b/c classes — each one lockable, restorable,
#     continuable and refusal-checked. The source files must stay byte-identical.
#   * PROFILE C — the same source without the opt-in: the generator keeps the
#     bounded alias lock and adds no letter-class grammar.
#
# Everything is machine-parsable (`INFO`/`PASS`/`FAIL`/`RESULT` JSON lines). The
# script fails only on contract violations (`FAIL:` lines).
#
# Usage: Tools/BuildRimeIOS/scripts/34-t9-letter-lock-harness.sh
#
# Overrides:
#   TLL_SOURCES (built-in package dir, read-only)
#
# Safety: nothing is deleted; outputs go to a fresh isolated run dir.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

SHIM_SRC_DIR="${IOS_TOOLS_DIR}/src"
[[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die "missing ${MAC_PREFIX}/lib/librime.a (run Tools/BuildRime)"

say "build PackageManager module"
( cd "${PROJECT_ROOT}/Packages/PackageManager" && swift build >/dev/null )
PM_DEBUG="${PROJECT_ROOT}/Packages/PackageManager/.build/out/Products/Debug"
for f in PackageManager.o KeyboardCore.o Yams.o CYaml.o ZIPFoundation.o; do
  [[ -f "${PM_DEBUG}/${f}" ]] || die "missing ${PM_DEBUG}/${f}"
done
PM_CHECKOUTS="${PROJECT_ROOT}/Packages/PackageManager/.build/checkouts"

GEN_INCLUDE="$(rime_generated_include)"

RUN_DIR="$(new_harness_dir t9-letter-lock)"
prepare_native_bridge
compile_bridge_c -DRB_WITH_GRAMMAR=1
cat > "${RUN_DIR}/rb_grammar_noop.cc" <<'EOF'
void rime_require_module_octagram();
extern "C" void rb_require_grammar(void) {}
EOF
for shim in rime_spelling rime_display_map rime_grammar_diagnostics; do
  compile_bridge_cpp "${shim}"
done
"${MAC_CXX:-clang++}" -std=c++17 -O2 -c -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
  "${RUN_DIR}/rb_grammar_noop.cc" -o "${RUN_DIR}/rb_grammar_noop.o"

# `CompactAdapterDeployment` references `HostLog.append` (logging only),
# and is compiled flat so it resolves against the macOS librime shims.
cat > "${RUN_DIR}/HostLogShim.swift" <<'EOF'
import Foundation
enum HostLog {
    static func append(_ message: String) {}
}
EOF
mkdir -p "${RUN_DIR}/flat"
PKG="${PROJECT_ROOT}/Packages"
for f in "${PKG}"/RimeBridge/Sources/RimeBridge/*.swift; do
  base="$(basename "$f")"
  sed -e 's/^import KeyboardCore$//' -e 's/^import RimeBridge$//' "$f" > "${RUN_DIR}/flat/${base}"
done
sed -e 's/^import RimeBridge$//' \
  "${PROJECT_ROOT}/Apps/HostApp/CompactAdapterDeployment.swift" > "${RUN_DIR}/flat/CompactAdapterDeployment.swift"

# Learning bridge C adapter: same -fno-modules + original public header ABI the
# SPM target uses; emits module map + object into the run dir.
say "compile learning C adapter"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
python3 "${PROJECT_ROOT}/Tools/BuildRimeIOS/scripts/build-learning-support.py" \
  --sdk "${MACOS_SDK}" --target arm64-apple-macos13.0 \
  --kit-include-dir "${MAC_PREFIX}/include" \
  --output-dir "${RUN_DIR}/learning-support"

swiftc -O -parse-as-library \
  -Xcc -fmodule-map-file="${RUN_DIR}/RimeKitModule/module.modulemap" \
  -Xcc -fmodule-map-file="${PM_CHECKOUTS}/Yams/Sources/CYaml/include/module.modulemap" \
  -Xcc -fmodule-map-file="${PM_CHECKOUTS}/ZIPFoundation/Sources/CZLib/module.modulemap" \
  -Xcc -fmodule-map-file="${RUN_DIR}/learning-support/module/module.modulemap" \
  -I "${RUN_DIR}/RimeKitModule" -I "${MAC_PREFIX}/include" -I "${PM_DEBUG}" \
  -I "${RUN_DIR}/learning-support/module" \
  "${IOS_TOOLS_DIR}/harness-mac/t9-letter-lock-main.swift" \
  "${RUN_DIR}/flat"/*.swift \
  "${RUN_DIR}/HostLogShim.swift" \
  "${PM_DEBUG}/PackageManager.o" "${PM_DEBUG}/KeyboardCore.o" "${PM_DEBUG}/Yams.o" \
  "${PM_DEBUG}/CYaml.o" "${PM_DEBUG}/ZIPFoundation.o" \
  "${RUN_DIR}/rime_bridge.o" "${RUN_DIR}/rime_spelling.o" "${RUN_DIR}/rime_display_map.o" \
  "${RUN_DIR}/rime_grammar_diagnostics.o" "${RUN_DIR}/rb_grammar_noop.o" \
  "${RUN_DIR}/learning-support/RimeLeversSupport.o" \
  "${MAC_LINK_FLAGS[@]}" \
  -target arm64-apple-macos13.0 -o "${RUN_DIR}/harness"

SOURCES="${TLL_SOURCES:-${PROJECT_ROOT}/Resources/BuiltinPackages/Basic}"
[[ -f "${SOURCES}/default.yaml" ]] || die "source testdata missing: ${SOURCES}"

# PROFILE A/C: an isolated scratch package holding the built-in full pinyin and a
# digit-coded `t9_digits` derived from it; for A only, ONE opt-in line is added.
# The real package is never touched.
derive_profile() { # $1 = destination, $2 = opt-in (yes/no)
  local dest="$1" optin="$2"
  mkdir -p "${dest}"
  cp "${SOURCES}/songyan_quanpin.schema.yaml" "${SOURCES}/songyan_basic.dict.yaml" "${dest}/"
  python3 - "${dest}" "${optin}" <<'PY'
import re, sys
dest, optin = sys.argv[1], sys.argv[2]
text = open(dest + "/songyan_quanpin.schema.yaml", encoding="utf-8").read()
text = text.replace("schema_id: songyan_quanpin", "schema_id: t9_digits", 1)
text = text.replace("prism: songyan_quanpin", "prism: t9_digits", 1)
text = re.sub(r"(?m)^  alphabet: .*$", "  alphabet: 23456789abcdefghijklmnopqrstuvwxyz", text, count=1)
digits = "".join("\n    - derive/[%s]/%s/" % pair for pair in
                 [("abc", 2), ("def", 3), ("hgi", 4), ("jkl", 5), ("omn", 6), ("pqrs", 7), ("tuv", 8), ("wxyz", 9)])
assert "  algebra: []" in text, "songyan_quanpin source layout changed"
text = text.replace("  algebra: []", "  algebra:" + digits, 1)
if optin == "yes":
    needle = "translator:\n"
    assert needle in text, "songyan_quanpin source layout changed"
    text = text.replace(needle, "keyboard_rewrite_prefix: letter_class_v1\n\n" + needle, 1)
open(dest + "/t9_digits.schema.yaml", "w", encoding="utf-8").write(text)
open(dest + "/default.yaml", "w", encoding="utf-8").write(
    "config_version: \"1\"\nschema_list:\n  - schema: songyan_quanpin\n  - schema: t9_digits\n")
PY
}
derive_profile "${RUN_DIR}/opted-shared" yes
derive_profile "${RUN_DIR}/plain-adapted-shared" no
say "run 9-key profiles (A opted-in, C adapted but un-opted)"
"${RUN_DIR}/harness" --opted "${RUN_DIR}/opted-shared" \
  --adapted "${RUN_DIR}/plain-adapted-shared" \
  --user "$(new_isolated_dir "${RUN_DIR}/user")" | tee "${RUN_DIR}/t9.log"

FAILS="$( (grep -h '^FAIL:' "${RUN_DIR}"/*.log 2>/dev/null || true) | wc -l | tr -d ' ' )"
say "contract failures: ${FAILS}"
if [[ "${FAILS}" != "0" ]]; then
  grep -h '^FAIL:' "${RUN_DIR}"/*.log || true
  die "t9 letter-lock harness reported ${FAILS} contract failure(s)"
fi
say "harness dir: ${RUN_DIR}"
