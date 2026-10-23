// ---------------------------------------------------------------------------
// rime_display_map.h — native projection extraction for source-code display.
//
// The keyboard adapter's `keyboard_adapter` capability block is generated from
// the *effective* source schema: its translator namespace, primary Table
// syllabary and (unmerged) speller/algebra. This primitive performs the forward
// librime `Projection`/`Script` projection and returns every final spelling per
// source token, with each spelling tagged normal/fuzzy/abbrev/correction as
// computed by librime. The Swift generator only reduces that evidence to the
// unique-normal map; it never re-implements the algebra.
//
// It deliberately does NOT decide capability: ambiguous / missing / erased /
// non-alphabetic tokens are reported and rejected downstream.
// ---------------------------------------------------------------------------
#ifndef RIME_DISPLAY_MAP_H_
#define RIME_DISPLAY_MAP_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns a newly malloc'd NUL-terminated JSON object for the session's active
 * schema, or NULL when the projection cannot be proven (no session, not exactly
 * one script translator, dictionary/table unavailable, algebra load/apply
 * failure, or a Table/Prism that did not open). Caller owns the result. JSON shape:
 * {
 *   "source_schema": "songyan_flypy",
 *   "translator_namespace": "translator",
 *   "dictionary": "songyan_basic",
 *   "alphabet": "...",
 *   "algebra": ["..."],
 *   "separator": " ",
 *   "declaration": "canonical_pinyin" | "",
 *   "syllables": { "zao": [ {"text":"zc","normal":true,"correction":false}, ... ] }
 * }
 * An empty algebra is a legal identity projection. A *non-empty* algebra whose
 * Projection::Apply returns false is refused: librime cannot distinguish a
 * no-op from a runtime error there, and a false success must never be reported
 * as identity. */
char* rb_syllable_display_map_json(uintptr_t session_id);

void rb_syllable_display_map_free(char* json);

/* Runtime display context for the active schema:
 *   {"capability": { ...keyboard_adapter... } | null,
 *    "capability_present": <bool raw key presence, any type>,
 *    "producer": {"schema_id","translator_namespace","dictionary","prism",
 *                 "producer_loaded"},
 *    "source": {"source_schema","translator_namespace","dictionary","alphabet",
 *               "declaration","algebra"} | null}
 * `producer_loaded` is false when the active producer's table or prism is
 * missing/unloadable. NULL only when there is no live session. Caller owns the
 * result. */
char* rb_copy_display_context_json(uintptr_t session_id);

void rb_copy_display_context_free(char* json);

#ifdef __cplusplus
}
#endif

#endif  // RIME_DISPLAY_MAP_H_
