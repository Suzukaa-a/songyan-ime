// ---------------------------------------------------------------------------
// ambiguity-outcome-contract-stub.c — NEGATIVE CONTROL / harness self-check.
//
// This is NOT the production proof and NEVER runs the real engine. It is a
// minimal stand-in service that reproduces the CURRENT (pre-patch) guard
// behaviour of rb_apply_ambiguity_spelling / rb_restore_ambiguity_spelling:
//
//     bad arguments / no session  ->  RB_AMBIG_FAILED
//
// Purpose: prove that ambiguity-outcome-main.c is a real, load-bearing test —
// that its assertion logic actually FAILS on the current behaviour — on hosts
// where the pinned macOS librime prefix cannot be built. It also demonstrates
// that swapping in the contract-correct returns (RB_AMBIG_INVALID) makes the
// same harness PASS, i.e. the test is satisfiable and not vacuous.
//
// Selected by the runner via AMBIG_OUTCOME_STUB=current|fixed. When the real
// pinned engine prefix is available the runner links the REAL bridge instead
// and this file is unused.
//
// Every stateful stub below is deliberately trivial; the guards under test are
// evaluated before any schema/rewrite work, so no real engine behaviour is
// needed to exercise them.
// ---------------------------------------------------------------------------
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "rime_bridge.h"

// Set by the runner: "current" reproduces the defect, "fixed" models the
// documented contract. Defaults to "current" so a mistaken direct link still
// exposes the bug rather than hiding it.
static int stub_contract_fixed(void) {
  const char* mode = getenv("AMBIG_OUTCOME_STUB_MODE");
  return mode && strcmp(mode, "fixed") == 0;
}

static int stub_early_out(void) {
  // The current implementation reports FAILED; the contract requires INVALID.
  return stub_contract_fixed() ? RB_AMBIG_INVALID : RB_AMBIG_FAILED;
}

// ---- minimal service/session stand-ins ------------------------------------

struct rb_engine {
  int ready;
  char error[128];
};

// A session id the harness treats as live. The harness only compares it with 0
// and passes it back; it never dereferences it.
#define STUB_LIVE_SESSION ((uintptr_t)0xA11FE01D)

static rb_engine g_engine;

rb_engine* rb_engine_create(const char* shared_data_dir, const char* user_data_dir,
                            const char* app_name, const char* distribution_version) {
  (void)shared_data_dir; (void)user_data_dir; (void)app_name; (void)distribution_version;
  g_engine.ready = 1;
  g_engine.error[0] = '\0';
  return &g_engine;
}

rb_engine* rb_engine_create_prebuilt(const char* shared_data_dir,
                                     const char* user_data_dir,
                                     const char* app_name,
                                     const char* distribution_version,
                                     const char* compiled_dir) {
  (void)compiled_dir;
  return rb_engine_create(shared_data_dir, user_data_dir, app_name, distribution_version);
}

void rb_engine_destroy(rb_engine* engine) { (void)engine; }

const char* rb_engine_last_error(const rb_engine* engine) {
  return engine ? engine->error : "stub";
}

int rb_engine_ready(const rb_engine* engine) { return engine && engine->ready; }

const char* rb_engine_version(const rb_engine* engine) {
  (void)engine;
  return "1.17.0";
}

uintptr_t rb_session_create(rb_engine* engine) {
  (void)engine;
  return STUB_LIVE_SESSION;
}

void rb_session_destroy(rb_engine* engine, uintptr_t session_id) {
  (void)engine; (void)session_id;
}

int rb_select_schema(rb_engine* engine, uintptr_t session_id, const char* schema_id) {
  (void)engine; (void)session_id; (void)schema_id;
  return RB_TRUE;
}

// Feeds "ni" so the harness sees the composing live session it requires.
int rb_simulate_key_sequence(rb_engine* engine, uintptr_t session_id,
                             const char* key_sequence) {
  (void)engine; (void)session_id; (void)key_sequence;
  return RB_TRUE;
}

rb_snapshot* rb_snapshot_get(rb_engine* engine, uintptr_t session_id) {
  (void)engine; (void)session_id;
  rb_snapshot* snapshot = (rb_snapshot*)calloc(1, sizeof(rb_snapshot));
  if (!snapshot) return NULL;
  snapshot->schema_id = strdup("engine_test_pinyin26");
  snapshot->schema_name = strdup("stub");
  snapshot->input = strdup("ni");
  snapshot->preedit = strdup("ni");
  snapshot->commit_text = strdup("");
  snapshot->is_composing = RB_TRUE;
  snapshot->num_candidates = 0;
  snapshot->candidates = NULL;
  if (!snapshot->schema_id || !snapshot->schema_name || !snapshot->input ||
      !snapshot->preedit || !snapshot->commit_text) {
    return NULL;
  }
  return snapshot;
}

void rb_snapshot_free(rb_snapshot* snapshot) {
  if (!snapshot) return;
  free(snapshot->schema_id);
  free(snapshot->schema_name);
  free(snapshot->input);
  free(snapshot->preedit);
  free(snapshot->commit_text);
  free(snapshot);
}

// ---- the two exported entry points under contract test --------------------

int rb_apply_ambiguity_spelling(uintptr_t session_id, const char* expected_input,
                                int segment_start, int segment_end,
                                const char* spelling) {
  (void)segment_start; (void)segment_end;
  if (session_id == 0 || !expected_input || !spelling) return stub_early_out();
  if (session_id != STUB_LIVE_SESSION) return stub_early_out();
  return RB_AMBIG_UNSUPPORTED;
}

int rb_restore_ambiguity_spelling(uintptr_t session_id, const char* expected_input,
                                  int segment_start, int segment_end,
                                  const char* expected_spelling,
                                  const char* reduced_code) {
  (void)segment_start; (void)segment_end;
  if (session_id == 0 || !expected_input || !expected_spelling || !reduced_code)
    return stub_early_out();
  if (session_id != STUB_LIVE_SESSION) return stub_early_out();
  return RB_AMBIG_UNSUPPORTED;
}
