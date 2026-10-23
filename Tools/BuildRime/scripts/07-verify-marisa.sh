#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 07-verify-marisa.sh — verify the marisa single-source contract (the license
# notices declare one marisa version): the prefix and the final rime_cli link contain EXACTLY ONE marisa — the
# pinned marisa-trie 0.3.1 — and no OpenCC-bundled marisa 0.2.6 leftovers.
#
# Background: OpenCC (commit 556ed22…, ver.1.1.9) by default builds its bundled
# deps/marisa-0.2.6 and INSTALLS its own libmarisa.a over the marisa-trie 0.3.1
# archive installed earlier into the same prefix — leaving a "declared 0.3.1 /
# actual 0.2.6" mismatch in every later link. 02-build-deps.sh configures
# OpenCC with USE_SYSTEM_MARISA=ON so it consumes the external pinned marisa.
#
# How we tell them apart: compiled marisa objects embed the source path they
# were built from (as __FILE__ strings) —
#   * marisa-trie 0.3.1 (pinned, external):  deps/marisa-trie/lib/marisa/…
#   * OpenCC bundled 0.2.6:                   deps/marisa-0.2.6/lib/marisa/…
# So we assert on the ACTUAL archive members and the linked binary, not on
# version tags.
#
# Safety: read-only. Object members are extracted with `ar -p` into a
# fresh, never-before-used directory under ${ENGINE_RUNS}; nothing is deleted.
# ---------------------------------------------------------------------------
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LIBDIR="${ENGINE_PREFIX}/lib"
RIME_CLI="${ENGINE_BIN}/rime_cli"
POSITIVE_RE='marisa-trie/lib/marisa'   # fingerprint of the pinned 0.3.1 build
NEGATIVE_RE='marisa-0\.2\.6'           # fingerprint of OpenCC's bundled marisa

for f in "${LIBDIR}/libmarisa.a" "${LIBDIR}/libopencc.a" "${LIBDIR}/librime.a"; do
  [[ -f "${f}" ]] || die "missing ${f}; run scripts/01..04 first"
done
[[ -x "${RIME_CLI}" ]] || die "rime_cli missing; run scripts/01..04 first"

echo "marisa provenance check (marisa-trie 0.3.1 pinned; OpenCC USE_SYSTEM_MARISA)"
echo "  prefix: ${ENGINE_PREFIX}"
pass=0; fail=0

# count_needle <file> <regex> — prints the number of matching lines (never dies
# on a zero count; bash 3.2 / grep -c returns rc=1 when nothing matches).
count_needle() { # $1 file, $2 regex
  local c
  c="$(strings "$1" | grep -cE "$2" || true)"
  printf '%s' "${c:-0}"
}

# verify_archive_members <label> <archive>
#   * every member carries NO bundled-0.2.6 fingerprint (per-member extraction)
#   * the archive as a whole embeds the pinned 0.3.1 fingerprint
verify_archive_members() { # $1 label, $2 archive
  local label="$1" arch="$2" bad=0 total=0 member tmp
  total=$(ar -t "${arch}" | grep -vc '^__.SYMDEF' || true)
  tmp="$(new_isolated_dir "${ENGINE_RUNS}/marisa-$(basename "${arch}" .a)")"
  for member in $(ar -t "${arch}" | grep -v '^__.SYMDEF'); do
    (cd "${tmp}" && ar -p "${arch}" "${member}" > "member.o" 2>/dev/null)
    c="$(count_needle "${tmp}/member.o" "${NEGATIVE_RE}")"
    if [[ "${c}" -gt 0 ]]; then
      echo "FAIL: ${label} member ${member} embeds bundled marisa 0.2.6 path (${c}×)"
      bad=$((bad+1))
    fi
  done
  if [[ "${bad}" -eq 0 ]]; then
    echo "PASS: ${label} — all ${total} members carry no marisa-0.2.6 path"
    pass=$((pass+1))
  else
    echo "FAIL: ${label} — ${bad}/${total} members embed marisa-0.2.6"
    fail=$((fail+1))
  fi
  positive="$(count_needle "${arch}" "${POSITIVE_RE}")"
  if [[ "${positive}" -gt 0 ]]; then
    echo "PASS: ${label} embeds pinned marisa-trie 0.3.1 paths (${positive}×)"
    pass=$((pass+1))
  else
    echo "FAIL: ${label} shows no marisa-trie 0.3.1 implementation paths"
    fail=$((fail+1))
  fi
}

# --- the marisa implementation archive + every other prefix archive ---------
verify_archive_members "libmarisa.a (marisa implementation)" "${LIBDIR}/libmarisa.a"

for arch in "${LIBDIR}"/*.a; do
  [[ -f "${arch}" ]] || continue
  name="$(basename "${arch}")"
  [[ "${name}" == "libmarisa.a" ]] && continue
  neg="$(count_needle "${arch}" "${NEGATIVE_RE}")"
  if [[ "${neg}" -eq 0 ]]; then
    echo "PASS: ${name} — no bundled marisa-0.2.6 paths"
    pass=$((pass+1))
  else
    echo "FAIL: ${name} embeds bundled marisa-0.2.6 paths (${neg}×)"
    fail=$((fail+1))
  fi
done

# --- the final linked binary -------------------------------------------------
neg="$(count_needle "${RIME_CLI}" "${NEGATIVE_RE}")"
if [[ "${neg}" -eq 0 ]]; then
  echo "PASS: rime_cli — no bundled marisa-0.2.6 object embedded"
  pass=$((pass+1))
else
  echo "FAIL: rime_cli embeds bundled marisa-0.2.6 objects (${neg}×)"
  fail=$((fail+1))
fi
pos="$(count_needle "${RIME_CLI}" "${POSITIVE_RE}")"
if [[ "${pos}" -gt 0 ]]; then
  echo "PASS: rime_cli embeds pinned marisa-trie 0.3.1 objects (${pos}×)"
  pass=$((pass+1))
else
  echo "FAIL: rime_cli shows no marisa-trie 0.3.1 object paths"
  fail=$((fail+1))
fi

echo
echo "== results: pass=${pass} fail=${fail} =="
[[ "${fail}" -eq 0 ]] || die "marisa single-source verification failed"
