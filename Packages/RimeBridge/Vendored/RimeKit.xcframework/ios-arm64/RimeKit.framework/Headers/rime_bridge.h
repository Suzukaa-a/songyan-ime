// ---------------------------------------------------------------------------
// rime_bridge.h — thin C bridge over librime 1.17.0's C API for iOS.
//
// What this layer does:
//   * hides the RimeApi* function table and the RIME_STRUCT() boilerplate;
//   * copies librime-owned strings out into caller-owned snapshots so Swift
//     can hold the data safely across further key presses;
//   * collapses deployment notifications into a thread-safe state readable
//     after joining the maintenance thread.
//
// What this layer deliberately does NOT do:
//   * no threading model of its own — all rb_* calls except
//     rb_last_deploy_state must come from a single thread at a time;
//   * no policy/state machines; the Swift wrapper (RimeBridge) owns session
//     lifecycle, sync orchestration and serial access.
//
// Concurrency contract (must be honoured by the wrapper):
//   1. Serialize every rb_* call (except rb_last_deploy_state) on one queue.
//   2. rb_sync_user_data() destroys all librime sessions; the caller must
//      create a fresh session afterwards and re-select the schema.
//   3. rb_snapshot_free() releases the snapshot and every string in it.
//   4. rb_engine_destroy() must not run concurrently with other calls.
//   5. One active rb_engine per process. A second create returns a non-ready
//      error object; destroying it never finalizes the active engine.
//
// Keycode/mask semantics follow librime: printable ASCII passes through as the
// character value; named keys use X11 keysym values (XK_BackSpace 0xff08,
// XK_Tab 0xff09, XK_Return 0xff0d, XK_Escape 0xff1b, ...). Modifier bits are
// librime's RimeModifier: shift 1<<0, lock 1<<1, control 1<<2, alt(mod1) 1<<3,
// meta 1<<28.
// ---------------------------------------------------------------------------
#ifndef RIME_BRIDGE_H_
#define RIME_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RB_TRUE 1
#define RB_FALSE 0

/* Deployment state delivered by the engine's notification handler. */
enum rb_deploy_state {
  RB_DEPLOY_NONE = 0,
  RB_DEPLOY_START = 1,
  RB_DEPLOY_SUCCESS = 2,
  RB_DEPLOY_FAILURE = 3,
};

typedef struct rb_engine rb_engine;

/* Native GramDb load outcomes and optional real decoder query samples. Context text
 * is recorded only after explicit enable, bounded to 16 samples and reset per engine. */
void rb_grammar_diagnostics_reset(int enabled);
char* rb_grammar_diagnostics_json(void);
void rb_grammar_diagnostics_free(char* json);
/* Current session's live Octagram instance, not historical Load diagnostics.
 * Serialize with all engine operations, including selection/destruction. */
int rb_grammar_session_loaded(uintptr_t session_id, const char* model_path);
int rb_component_available(const char* name);

/* One candidate on the current page. Strings are owned by the snapshot. */
typedef struct {
  char* text;     /* UTF-8; never NULL inside a snapshot */
  char* comment;  /* UTF-8 or NULL */
} rb_candidate;

/*
 * A full copy of the session state visible to a keyboard UI.
 * Free with rb_snapshot_free(); never dereference after freeing.
 */
typedef struct {
  char* schema_id;      /* never NULL */
  char* schema_name;    /* never NULL */
  int is_composing;     /* RB_TRUE/RB_FALSE */
  int is_ascii_mode;    /* RB_TRUE/RB_FALSE (RimeStatus.is_ascii_mode) */
  int is_full_shape;    /* RB_TRUE/RB_FALSE (RimeStatus.is_full_shape) */
  int is_ascii_punct;   /* RB_TRUE/RB_FALSE (RimeStatus.is_ascii_punct) */
  char* input;          /* raw input ("" when idle); never NULL */
  char* preedit;        /* "" when not composing; never NULL */
  int preedit_cursor;   /* caret position reported by librime (UTF-8 bytes) */
  /* Engine-reported UTF-8 byte range of the highlighted (unconfirmed) segment
   * inside `preedit`, i.e. libime Composition sel_start/sel_end. Everything
   * outside [sel_start, sel_end) is already-converted text, punctuation or
   * trailing raw code and must be preserved verbatim when the highlighted
   * segment is re-rendered. 0/0 when not composing. */
  int preedit_sel_start;
  int preedit_sel_end;
  int page_no;          /* 0-based current page */
  int page_size;        /* candidates per page */
  int is_last_page;     /* RB_TRUE/RB_FALSE */
  int highlighted_index;/* 0-based index on the current page */
  int num_candidates;   /* number of entries in `candidates` */
  rb_candidate* candidates;
  /* Page candidate label/select-key metadata, copied verbatim from
   * RimeMenu.select_keys and RimeContext.select_labels for THIS page. These are
   * the schema's own `menu/alternative_select_keys` (a string of page-slot keys)
   * and `menu/alternative_select_labels` (a per-page-slot label list). Both are
   * NULL when the active schema declares none; the bridge never fabricates the
   * default 1..9 keys/labels and never derives a label from a candidate comment.
   *   * select_keys[i]   = the select key for page slot i (ASCII, may be empty);
   *   * select_labels[i] = the label for page slot i;
   *   * num_select_labels = the page_size the label array was built for
   *                         (0 when select_labels is NULL). librime fills exactly
   *                         page_size entries when it emits the array at all.
   * Owned by the snapshot; released by rb_snapshot_free(). */
  char* select_keys;
  char** select_labels;
  int num_select_labels;
  char* commit_text;    /* text committed by the last action; "" if none.
                           Reading it consumes librime's pending commit. */
} rb_snapshot;

/* ---- trusted candidate spelling (implemented in rime_spelling.cc) -------- */

/* Returns a newly malloc'd NUL-terminated UTF-8 string with the highlighted
 * candidate's genuine spelling, or NULL when it cannot be proven (unknown
 * translator/source, non-script candidate type, unprovable preedit span).
 * The front end calls this only for its own reduced layouts; there is no
 * alphabet/name heuristic here. The caller owns the result. Runs on the
 * caller's (serialized) engine thread; never reads the mutable comment. */
char* rb_copy_highlighted_spelling(uintptr_t session_id);

/* Same trusted provenance/type/range/dictionary gates as
 * rb_copy_highlighted_spelling, but returns the canonical syllable token array
 * plus the engine display separator as a JSON object:
 *   {"separator":"'","syllables":["zao","shang","hao"]}
 * or NULL when the highlighted candidate cannot be proven. The display policy
 * needs the per-token array to project an unambiguous source-code display. The
 * caller owns the result. */
char* rb_copy_highlighted_syllables_json(uintptr_t session_id);
/* Read-only absolute candidate pronunciations. NULL = unproven; free() JSON {paths:[[...]],complete:bool}. */
char* rb_copy_candidate_syllables_json(uintptr_t session_id, int index);

/* Runtime display context for the ACTIVE schema, as JSON:
 *   {"capability": { ...keyboard_adapter... } | null,
 *    "source": { source_schema, translator_namespace, dictionary, alphabet,
 *                algebra:[...] } | null}
 * `source` describes the schema named by capability.source_schema, so Swift can
 * reject a capability whose source schema no longer matches.
 * NULL only when there is no live session; unknown capability/source is null
 * inside the object. Caller owns the result. */
char* rb_copy_display_context_json(uintptr_t session_id);
void rb_copy_display_context_free(char* json);

/* Forward algebra projection of a source schema (primary Table syllabary +
 * unmerged speller/algebra) for GENERATION, as JSON:
 *   {"source_schema":..,"translator_namespace":..,"dictionary":..,
 *    "alphabet":..,"separator":..,"algebra":[..],
 *    "syllables":{"token":[{"text":..,"normal":bool,"correction":bool},..]}}
 * NULL when the projection cannot be proven (no session, not exactly one script
 * translator, dictionary/table unavailable, algebra load/apply failure). Used by
 * the Host App generator; the keyboard runtime does not call it. Caller owns the
 * result. */
char* rb_syllable_display_map_json(uintptr_t session_id);
void rb_syllable_display_map_free(char* json);

/* ---- read-only ambiguity spelling enumeration (rime_spelling.cc) --------- *
 *
 * The report itself is read-only: it never rewrites input, never
 * selects/locks a spelling, never changes page/highlight/commit and never reads
 * a candidate comment or enumerates front-end keycaps (rewrites go through
 * rb_apply_ambiguity_spelling / rb_restore_ambiguity_spelling). The
 * front end decides WHEN to ask (only its real 9/14-key layouts); the bridge
 * itself performs no layout heuristic.
 *
 * Scope: exactly the current `composition.back()` segment, and only when that
 * segment carries the `abc` tag. The raw span is [segment.start, segment.end)
 * inside the current raw input (`Context::input()`). The listed spellings are
 * SCHEMA-AGNOSTIC: they are derived from the active schema's own
 * Script/Prism/Syllabifier through its single `script_translator`s dictionary
 * (`Syllabifier::BuildSyllableGraph(raw)` proves the raw is a fully-interpreted
 * single spelling, and each full-span syllable id is decoded through the primary
 * Table syllabary). pinyin, double-pinyin, shape codes, Bopomofo, dialect or any
 * custom syllable inventory are handled identically — there is no alphabet/name
 * heuristic. Only `kNormalSpelling`, non-correction pronunciations are listed. A
 * multi-syllable raw segment therefore yields an empty list rather than
 * fabricated splits. *
 * Return contract:
 *   * NULL  = cannot answer. Covers: null/unknown session; no schema/config;
 *             not composing; empty composition; the back segment is not `abc`;
 *             the raw span is empty/out of range; not exactly one script
 *             translator; dictionary/prism unavailable; allocation failure.
 *   * non-NULL = a definite answer for the current back `abc` segment:
 *             `{"revision_input":"<raw input>","segment":{"start":S,"end":E},
 *               "lock_mode":"none|bounded_token_alias|direct_token|prefix_token",
 *               "spellings":["<token>",...],"lockable":["<token>",...],
 *               "complete":true|false}`
 *             `spellings` is deduplicated and lexicographically sorted; an
 *             empty/singleton list is a definite "not ambiguous", never an
 *             error. `complete:false` means the list was truncated by the cap
 *             (default 32, hard limit 64; max_items<=0 -> default), so the
 *             caller must not present it as the full choice set.
 *             In the `prefix_token` (v4) mode the object additionally carries
 *             `"prefix_options":[...]` (the bounded single-character live-prism
 *             keys that NARROW this segment; always emitted in full, never lost
 *             to the spellings cap) and `"option_semantics":{"<option>":
 *             "exact|initial|mixed"}` (a per-option label for the UI). Only
 *             entries of `lockable` may be applied.
 *   * `revision_input` is the WHOLE current raw input; segment byte offsets are
 *     raw-input coordinates, never preedit coordinates. The caller compares
 *     `revision_input` against the live input to reject stale clicks.
 *
 * Free the result with free() (same malloc/free convention as the other
 * copied-spelling helpers). Does not increment rb_spelling_decode_count().
 */
char* rb_copy_ambiguity_spellings_json(uintptr_t session_id, int max_items);

/* ---- ambiguity CAS apply / restore (rime_spelling.cc) -------------------- *
 *
 * Explicit, capability-gated input rewrite for the merged-layout lock. This is
 * NOT a general set_input: it only ever replaces the current
 * `composition.back()` `abc` segment's raw byte span inside the whole raw input,
 * and only when the ACTIVE schema carries a versioned rewrite capability whose
 * declaration matches the live producer (adapter schema == active schema,
 * Table/Prism open, declared source facts agreeing). A declaration that does
 * not match is treated as absent.
 *
 * Outcome enum (never fold failure into success):
 *   RB_AMBIG_OK          = the rewrite was applied and the resulting
 *                          composition re-validated as composing with the new
 *                          input; no candidate was selected and nothing was
 *                          committed.
 *   RB_AMBIG_STALE       = expected whole input no longer matches the live
 *                          input, or the back segment is missing/not `abc`/out
 *                          of range. Nothing was written.
 *   RB_AMBIG_UNSUPPORTED = the active schema carries no VERIFIED rewrite
 *                          capability (unbound/stale/cross-wired declaration).
 *                          Nothing written.
 *   RB_AMBIG_INVALID     = bad arguments, or the requested token/target is not
 *                          proven by a fresh prism enumeration (including a
 *                          truncated/incomplete set). In `prefix_token` mode a
 *                          requested key that is not a live-proven narrowing of
 *                          THIS segment is refused here. Nothing written.
 *   RB_AMBIG_FAILED      = the write was attempted but post-validation failed;
 *                          the ORIGINAL input was restored. No hanzi committed.
 *
 * Three versioned lock modes are recognized; none follows from display_mode:
 *   * `bounded_token_alias_rewrite_v2` (current, SCHEMA-AGNOSTIC), declared by
 *     the sibling `keyboard_rewrite` block: the rewritten span is the block's
 *     opaque `lock_map` alias for the chosen TOKEN, which must enumerate to
 *     exactly that token. The token may be any syllable the live prism proves
 *     (pinyin, double-pinyin, shape code, Bopomofo, dialect, ...). There is no
 *     pinyin shape/declaration gate anywhere in this path.
 *   * `direct_token_rewrite_v3` (table sources): the chosen source code is its
 *     own rewrite target and must be a unique live prism key.
 *   * `prefix_token_rewrite_v4` (script sources that explicitly opted into the
 *     bounded letter-class layer): the chosen option is a single-character live
 *     prism key whose interpretation set is a non-empty SUBSET of this segment's,
 *     so the rewrite can only NARROW; the token of a multi-key code may also be
 *     locked directly when it is a unique normal live key of that segment.
 * A schema carrying none is RB_AMBIG_UNSUPPORTED.
 *
 * CAS + proof order (all on the caller's serialized engine thread):
 *   1. mode exact match + mode-specific shape (a non-empty adapter-bound
 *      `lock_map` for alias);
 *   2. live `Context::input()` byte-equals `expected_input`;
 *   3. `composition.back()` is `abc` and its raw span is [segment_start,
 *      segment_end) inside that input;
 *   4. re-enumerate `spelling` from the CURRENT prism: it must be a member of
 *      the complete full-span set (a truncated set is refused);
 *   5. resolve and re-prove the rewrite target (the token itself, or the mapped
 *      alias enumerating to exactly the chosen token);
 *   6. replace only that raw span and `Context::set_input(new_input)`;
 *   7. re-validate (composing, back `abc` present); on failure restore the
 *      original input, RE-READ it, and return RB_AMBIG_FAILED only when the
 *      rollback is confirmed byte-equal — otherwise RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED.
 *
 * `rb_restore_ambiguity_spelling` is the symmetric, equally gated path used to
 * put the reduced numeric code back. It re-proves that `expected_spelling` is
 * the currently enumerated spelling of the live tail segment before replacing
 * it with `reduced_code`, and then re-enumerates `reduced_code` to confirm it
 * still contains `expected_spelling`. It is not permitted to set an arbitrary
 * string.
 *
 * Both return an `rb_ambig_result`; they never commit, never select a
 * candidate, never read a candidate comment and never expose a C++ object.
 */
enum rb_ambig_result {
  RB_AMBIG_OK = 0,
  RB_AMBIG_STALE = 1,
  RB_AMBIG_UNSUPPORTED = 2,
  RB_AMBIG_INVALID = 3,
  /* The write was attempted and post-validation failed. The ORIGINAL input was
   * re-written and the rollback was RE-READ and confirmed byte-equal. No hanzi
   * committed. */
  RB_AMBIG_FAILED = 4,
  /* The write was attempted, post-validation failed, and the rollback could NOT
   * be re-read as the original input. The caller must treat the input as
   * unknown/changed; this is reported distinctly so a rollback is never claimed
   * as guaranteed. */
  RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED = 5,
};

int rb_apply_ambiguity_spelling(uintptr_t session_id,
                                const char* expected_input,
                                int segment_start,
                                int segment_end,
                                const char* spelling);

int rb_restore_ambiguity_spelling(uintptr_t session_id,
                                  const char* expected_input,
                                  int segment_start,
                                  int segment_end,
                                  const char* expected_spelling,
                                  const char* reduced_code);

/* Read-only, candidate-free verification of the active schema's rewrite
 * capability, for the installer deploy check (see rime_spelling.cc). Verifies the
 * full source/producer binding AND that every baked alias enumerates, through the
 * live prism, to exactly its token. Never feeds a key, never reads a candidate,
 * comment or literal, and does not require any dictionary word to exist.
 * Returns malloc JSON:
 *   {"present":bool,"verified":bool,"checked":N,"lock":"...","failures":[...]}
 * The caller owns the result. */
char* rb_copy_rewrite_verification_json(uintptr_t session_id);

/* Drops the cached decoded dictionary and resets the decode counter. Call when
 * sessions are (re)created or the engine is destroyed so a re-deploy cannot
 * leave stale table/prism paths. */
void rb_spelling_reset(void);

#ifdef RB_AMBIGUITY_SELFTEST
/* Test-only (never compiled into the shipped slices): verifies the ambiguity
 * report's cap/subset invariant on a synthetic over-cap input. Returns 0 on
 * success. Compiled only with -DRB_AMBIGUITY_SELFTEST. */
int rb_ambiguity_json_selftest(void);
#endif

/* Number of candidates actually decoded since the last reset. Front ends that
 * never request spelling (e.g. ordinary 26-key layouts) must report 0. */
unsigned long long rb_spelling_decode_count(void);

/* Read-only per-page-slot select metadata for the CROSS-PAGE candidate browsing
 * path, as JSON:
 *   {"page_size":N,"select_keys":["a","s",...]|null,"select_labels":["甲",...]|null}
 * Copied from the LIVE schema's `menu/alternative_select_keys` and
 * `menu/alternative_select_labels` (the same source RimeGetContext uses for
 * RimeMenu.select_keys / RimeContext.select_labels). It never touches the
 * menu/context/commit, so — unlike rb_snapshot_get() — it does NOT consume a
 * pending commit; it changes no page/highlight/input and is page-independent
 * (slot metadata is stable across pages), allowing a read-only page reader to
 * attach the right label to any page.
 *   * select_keys is split into one entry per Unicode scalar (never byte-indexed);
 *   * select_labels is emitted only when the declared list covers the whole page
 *     (exactly page_size entries), mirroring RimeGetContext;
 *   * an UNDECLARED list is JSON null — the bridge never synthesizes 1..9.
 * NULL only when there is no live session/schema/config.
 * Free the result with free(). */
char* rb_copy_context_metadata_json(uintptr_t session_id);

/* ---- engine lifetime ---------------------------------------------------- */

/* Initializes librime and runs a full maintenance synchronously. Returns NULL
 * on allocation/argument failure, or a non-ready object on ownership/deploy
 * failure. Check rb_engine_ready(); read rb_engine_last_error() on non-NULL
 * objects, then destroy them. NULL has no detailed error object.
 * distribution_version is the host app's version, recorded by librime in
 * installation.yaml; NULL leaves librime's default.
 * String arguments are copied internally and may be freed by the caller. */
rb_engine* rb_engine_create(const char* shared_data_dir,
                            const char* user_data_dir,
                            const char* app_name,
                            const char* distribution_version);

/* Read-only deployed resources; never starts maintenance. compiled_dir must
 * contain default.yaml and deployed schemas from this exact librime version.
 * Learning still lives exclusively in user_data_dir. */
rb_engine* rb_engine_create_prebuilt(const char* shared_data_dir,
                                    const char* user_data_dir,
                                    const char* app_name,
                                    const char* distribution_version,
                                    const char* compiled_dir);

/* Destroys the engine. Call only after all other rb_* calls have finished. */
void rb_engine_destroy(rb_engine* engine);

/* Last error string (valid until the next failing rb_* call). */
const char* rb_engine_last_error(const rb_engine* engine);

/* RB_TRUE once create() succeeded and the initial deployment did not fail. */
int rb_engine_ready(const rb_engine* engine);

/* Static librime version string, e.g. "1.17.0". */
const char* rb_engine_version(const rb_engine* engine);

/* ---- sessions ------------------------------------------------------------ */

/* Creates a session. Returns 0 (never a valid id) on failure. */
uintptr_t rb_session_create(rb_engine* engine);

void rb_session_destroy(rb_engine* engine, uintptr_t session_id);

/* ---- input --------------------------------------------------------------- */

/* Feeds one key. Returns RB_TRUE if librime consumed the key (the caller must
 * not insert the text itself), RB_FALSE if the app should handle it (e.g. an
 * unbound printable key -> insert into the text field). */
int rb_process_key(rb_engine* engine, uintptr_t session_id, int keycode,
                   int mask);

/* Commits the current composition (Return key path). Returns RB_TRUE on
 * success; the committed text appears in the next snapshot's commit_text. */
int rb_commit_composition(rb_engine* engine, uintptr_t session_id);

/* Selects candidate index on the current page (0-based). */
int rb_select_candidate_on_current_page(rb_engine* engine,
                                        uintptr_t session_id, size_t index);

/* Selects a candidate by absolute index across pages (0-based). */
int rb_select_candidate(rb_engine* engine, uintptr_t session_id, size_t index);

/* Flips to next/previous page (backward=RB_TRUE -> previous). */
int rb_change_page(rb_engine* engine, uintptr_t session_id, int backward);

/* Clears the current composition without committing. */
int rb_clear_composition(rb_engine* engine, uintptr_t session_id);

/* Simulates a key sequence (letters plus {Return}/{BackSpace}/... braces),
 * same grammar as librime's simulate_key_sequence. RB_TRUE when parsed. */
int rb_simulate_key_sequence(rb_engine* engine, uintptr_t session_id,
                             const char* key_sequence);

/* Sets/reads a session option such as "ascii_mode". */
int rb_set_option(rb_engine* engine, uintptr_t session_id, const char* option,
                  int value);
int rb_get_option(rb_engine* engine, uintptr_t session_id, const char* option);

/* ---- schema -------------------------------------------------------------- */

/* Selects a schema. Returns RB_TRUE on success. */
int rb_select_schema(rb_engine* engine, uintptr_t session_id,
                     const char* schema_id);

/* Writes the current schema id into buf (NUL-terminated). RB_TRUE on success. */
int rb_get_current_schema(rb_engine* engine, uintptr_t session_id, char* buf,
                          size_t buf_size);

/* ---- state snapshot ------------------------------------------------------ */

/* Returns a snapshot copy of the session state, or NULL when the session does
 * does not exist or a bridge allocation fails. Allocation failure leaves the
 * pending commit unconsumed. Free only with rb_snapshot_free(); never free
 * individual fields. The snapshot stays valid after engine destruction. */
rb_snapshot* rb_snapshot_get(rb_engine* engine, uintptr_t session_id);

void rb_snapshot_free(rb_snapshot* snapshot);

/* ---- maintenance / native sync ------------------------------------------ */

/* Runs librime's native user-data sync asynchronously: it destroys all
 * sessions and schedules the sync tasks on the maintenance thread. Returns
 * RB_TRUE when maintenance was started; wait with rb_join_maintenance() and
 * then re-create the session. */
int rb_sync_user_data(rb_engine* engine);

/* Starts a (full or incremental) maintenance run; RB_TRUE when started. */
int rb_start_maintenance(rb_engine* engine, int full_check);

/* Blocks until the maintenance thread finishes a run. */
void rb_join_maintenance(rb_engine* engine);

/* Deployment state observed so far (thread-safe; RB_DEPLOY_*). */
int rb_last_deploy_state(const rb_engine* engine);

#ifdef __cplusplus
}
#endif

#endif  // RIME_BRIDGE_H_
