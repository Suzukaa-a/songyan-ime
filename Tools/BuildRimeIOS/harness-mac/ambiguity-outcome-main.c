// ---------------------------------------------------------------------------
// ambiguity-outcome-main.c — runnable native proof for the C bridge ambiguity
// outcome contract (`rb_ambig_result`), against the REAL pinned librime.
//
// Contract under test (Tools/BuildRimeIOS/src/rime_bridge.h):
//
//   RB_AMBIG_FAILED = 4
//     "The write was attempted and post-validation failed. The ORIGINAL input
//      was re-written and the rollback was RE-READ and confirmed byte-equal.
//      No hanzi committed."
//   RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED = 5
//     the write was attempted, post-validation failed, and the rollback could
//     not be re-read as the original input.
//
// Both are POST-WRITE outcomes: they promise that a write happened and that its
// rollback state is known. An early-out that refuses the call *before* touching
// input — bad arguments, no live session, no context/schema/config — cannot
// return either, because no rollback was ever attempted or verified.
// The documented home for bad arguments is:
//
//   RB_AMBIG_INVALID = 3
//     "bad arguments, or the requested token/target is not proven by a fresh
//      prism enumeration"
//
// This harness drives the exported C API directly (no Swift wrapper) and
// asserts:
//   1. bad-argument early-outs return RB_AMBIG_INVALID, never FAILED;
//   2. a non-existent session id returns neither FAILED/ROLLBACK_UNVERIFIED nor
//      OK (no rollback claim, no false success);
//   3. on a LIVE composing session, every refused call leaves the raw input
//      byte-identical — so "nothing was written" is independently OBSERVED
//      rather than inferred from the return code alone.
//
// It needs no rewrite capability, no lock declaration and no dictionary word.
// The in-repo engine self-test tree (Tools/BuildRime/testdata/shared) is used
// only to boot a real librime service and obtain one live session; the guards
// under test fire before any schema/rewrite work.
//
// Explicitly NOT asserted here: that RB_AMBIG_FAILED is unreachable. A genuine
// post-write validation failure must still be able to report it. Forcing that
// state is out of scope for a contract harness (see the UNVERIFIED BOUNDARY
// note printed by main()).
//
// Exit codes: 0 = every contract assertion holds. 1 = at least one violation,
// or the engine could not be started (fail closed — never a silent skip and
// never a fabricated pass).
//
// Usage:
//   ambiguity-outcome-main --shared <engine-shared-dir> --user <writable-dir>
// ---------------------------------------------------------------------------
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rime_bridge.h"

// The wire enum is the contract. If a future edit renumbers it, this harness
// must fail at BUILD time rather than silently re-target the assertions.
_Static_assert(RB_AMBIG_OK == 0, "RB_AMBIG_OK must stay 0");
_Static_assert(RB_AMBIG_STALE == 1, "RB_AMBIG_STALE must stay 1");
_Static_assert(RB_AMBIG_UNSUPPORTED == 2, "RB_AMBIG_UNSUPPORTED must stay 2");
_Static_assert(RB_AMBIG_INVALID == 3, "RB_AMBIG_INVALID must stay 3");
_Static_assert(RB_AMBIG_FAILED == 4, "RB_AMBIG_FAILED must stay 4");
_Static_assert(RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED == 5,
               "RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED must stay 5");

static int g_checks;
static int g_failures;

static const char* outcome_name(int result) {
  switch (result) {
    case RB_AMBIG_OK: return "RB_AMBIG_OK";
    case RB_AMBIG_STALE: return "RB_AMBIG_STALE";
    case RB_AMBIG_UNSUPPORTED: return "RB_AMBIG_UNSUPPORTED";
    case RB_AMBIG_INVALID: return "RB_AMBIG_INVALID";
    case RB_AMBIG_FAILED: return "RB_AMBIG_FAILED";
    case RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED:
      return "RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED";
    default: return "RB_AMBIG_<unknown>";
  }
}

static int is_post_write_outcome(int result) {
  return result == RB_AMBIG_FAILED ||
         result == RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED;
}

// Bad arguments are documented as RB_AMBIG_INVALID. FAILED is the specific
// regression this harness exists to catch: it would promise a verified
// rollback for a call that never wrote.
static void check_bad_argument(const char* label, int got) {
  ++g_checks;
  if (got == RB_AMBIG_INVALID) {
    printf("PASS: %s -> RB_AMBIG_INVALID\n", label);
    return;
  }
  ++g_failures;
  printf("FAIL: %s -> %s (%d)\n", label, outcome_name(got), got);
  if (is_post_write_outcome(got)) {
    printf("      %s promises \"the write was attempted ... the rollback was\n"
           "      RE-READ and confirmed byte-equal\". This call was refused before\n"
           "      any write, so that promise is false. Bad arguments must report\n"
           "      RB_AMBIG_INVALID (%d).\n",
           outcome_name(got), RB_AMBIG_INVALID);
  } else {
    printf("      documented home for bad arguments is RB_AMBIG_INVALID (%d).\n",
           RB_AMBIG_INVALID);
  }
}

// No live session: there is nothing to write and nothing to roll back. The
// contract only forbids FAILED/ROLLBACK_UNVERIFIED and false success; INVALID
// or UNSUPPORTED are both defensible and the production patch chooses.
static void check_no_session(const char* label, int got) {
  ++g_checks;
  if (!is_post_write_outcome(got) && got != RB_AMBIG_OK) {
    printf("PASS: %s -> %s (no rollback claim, no false success)\n", label,
           outcome_name(got));
    return;
  }
  ++g_failures;
  if (got == RB_AMBIG_OK) {
    printf("FAIL: %s -> RB_AMBIG_OK: a non-existent session claimed success\n",
           label);
    return;
  }
  printf("FAIL: %s -> %s (%d)\n", label, outcome_name(got), got);
  printf("      No session exists and nothing was written, yet the result promises\n"
         "      a write plus a verified rollback. Expect RB_AMBIG_INVALID (%d) or\n"
         "      RB_AMBIG_UNSUPPORTED (%d).\n",
         RB_AMBIG_INVALID, RB_AMBIG_UNSUPPORTED);
}

// Copies the live raw input so it can be compared after a refused call.
static char* copy_live_input(rb_engine* engine, uintptr_t session_id,
                             int* composing_out) {
  rb_snapshot* snapshot = rb_snapshot_get(engine, session_id);
  if (!snapshot) return NULL;
  const char* input = snapshot->input ? snapshot->input : "";
  size_t length = strlen(input);
  char* copy = (char*)malloc(length + 1);
  if (copy) memcpy(copy, input, length + 1);
  if (composing_out) *composing_out = snapshot->is_composing;
  rb_snapshot_free(snapshot);
  return copy;
}

static void check_input_unchanged(const char* label, const char* before,
                                  const char* after, int composing) {
  ++g_checks;
  if (before && after && strcmp(before, after) == 0) {
    printf("PASS: %s left the live input untouched (\"%s\", composing=%d)\n",
           label, after, composing);
    return;
  }
  ++g_failures;
  printf("FAIL: %s changed the live input: before=\"%s\" after=\"%s\"\n", label,
         before ? before : "<null>", after ? after : "<null>");
}

int main(int argc, char** argv) {
  const char* shared = NULL;
  const char* user = NULL;
  const char* positional[2] = {NULL, NULL};
  int positional_count = 0;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--shared") == 0 && i + 1 < argc) {
      shared = argv[++i];
    } else if (strcmp(argv[i], "--user") == 0 && i + 1 < argc) {
      user = argv[++i];
    } else if (positional_count < 2) {
      positional[positional_count++] = argv[i];
    } else {
      fprintf(stderr, "unknown argument: %s\n", argv[i]);
      return 2;
    }
  }
  if (!shared && positional_count > 0) shared = positional[0];
  if (!user && positional_count > 1) user = positional[1];
  if (!shared || !user) {
    fprintf(stderr,
            "usage: ambiguity-outcome-main --shared <dir> --user <dir>\n");
    return 2;
  }

  printf("== C bridge ambiguity outcome contract ==\n");
  printf("RB_AMBIG_FAILED (%d) promises: a write was attempted and the rollback\n",
         RB_AMBIG_FAILED);
  printf("was RE-READ byte-equal. Early-outs must never report it.\n\n");

  // ---- Phase 1: engine-free early-outs --------------------------------
  // The argument guards are evaluated before the session lookup, so these
  // fire with no librime service booted. A non-zero bogus id is used where the
  // NULL check is what must trip; session id 0 exercises the id guard itself.
  const uintptr_t kBogus = (uintptr_t)0x5eed5eed;

  printf("-- phase 1: argument early-outs (no engine needed) --\n");
  check_bad_argument(
      "apply(session=0, input=\"x\", [0,1), spelling=\"a\")",
      rb_apply_ambiguity_spelling(0, "x", 0, 1, "a"));
  check_bad_argument(
      "apply(session=bogus, input=NULL, [0,1), spelling=\"a\")",
      rb_apply_ambiguity_spelling(kBogus, NULL, 0, 1, "a"));
  check_bad_argument(
      "apply(session=bogus, input=\"x\", [0,1), spelling=NULL)",
      rb_apply_ambiguity_spelling(kBogus, "x", 0, 1, NULL));

  check_bad_argument(
      "restore(session=0, input=\"x\", [0,1), expected=\"a\", reduced=\"1\")",
      rb_restore_ambiguity_spelling(0, "x", 0, 1, "a", "1"));
  check_bad_argument(
      "restore(session=bogus, input=NULL, [0,1), expected=\"a\", reduced=\"1\")",
      rb_restore_ambiguity_spelling(kBogus, NULL, 0, 1, "a", "1"));
  check_bad_argument(
      "restore(session=bogus, input=\"x\", [0,1), expected=NULL, reduced=\"1\")",
      rb_restore_ambiguity_spelling(kBogus, "x", 0, 1, NULL, "1"));
  check_bad_argument(
      "restore(session=bogus, input=\"x\", [0,1), expected=\"a\", reduced=NULL)",
      rb_restore_ambiguity_spelling(kBogus, "x", 0, 1, "a", NULL));

  // ---- Phase 2: boot a real engine (fail closed) ----------------------
  printf("\n-- phase 2: live service / session early-outs --\n");
  rb_engine* engine = rb_engine_create(shared, user, "rime.songyan.ambiguity.outcome", NULL);
  if (!engine) {
    fprintf(stderr,
            "FAIL(closed): rb_engine_create returned NULL for shared=%s user=%s; "
            "the no-session contract cannot be verified\n",
            shared, user);
    return 1;
  }
  if (!rb_engine_ready(engine)) {
    fprintf(stderr,
            "FAIL(closed): engine not ready for shared=%s user=%s: %s\n", shared,
            user, rb_engine_last_error(engine));
    rb_engine_destroy(engine);
    return 1;
  }

  uintptr_t session_id = rb_session_create(engine);
  if (!session_id) {
    fprintf(stderr, "FAIL(closed): rb_session_create returned 0: %s\n",
            rb_engine_last_error(engine));
    rb_engine_destroy(engine);
    return 1;
  }

  // A booted service with no such session id: GetSession() yields nothing, so
  // this is the no-session early-out the contract names explicitly.
  check_no_session(
      "apply(session=0x5eed5eed on live service, input=\"x\", [0,1), spelling=\"a\")",
      rb_apply_ambiguity_spelling(kBogus, "x", 0, 1, "a"));
  check_no_session(
      "restore(session=0x5eed5eed on live service, input=\"x\", [0,1), "
      "expected=\"a\", reduced=\"1\")",
      rb_restore_ambiguity_spelling(kBogus, "x", 0, 1, "a", "1"));

  // A REAL session, composing, so the "nothing was written" claim can be
  // observed instead of assumed.
  if (!rb_select_schema(engine, session_id, "engine_test_pinyin26")) {
    fprintf(stderr, "FAIL(closed): cannot select engine_test_pinyin26: %s\n",
            rb_engine_last_error(engine));
    rb_session_destroy(engine, session_id);
    rb_engine_destroy(engine);
    return 1;
  }
  if (!rb_simulate_key_sequence(engine, session_id, "ni")) {
    fprintf(stderr, "FAIL(closed): cannot feed \"ni\": %s\n",
            rb_engine_last_error(engine));
    rb_session_destroy(engine, session_id);
    rb_engine_destroy(engine);
    return 1;
  }

  char* before = copy_live_input(engine, session_id, NULL);
  if (!before || strcmp(before, "ni") != 0) {
    fprintf(stderr,
            "FAIL(closed): expected a composing \"ni\" live session, observed "
            "\"%s\"\n",
            before ? before : "<null>");
    free(before);
    rb_session_destroy(engine, session_id);
    rb_engine_destroy(engine);
    return 1;
  }
  printf("live session: input=\"%s\" (composing)\n", before);

  int composing = 0;
  check_bad_argument(
      "apply(live session, input=\"ni\", [0,2), spelling=NULL)",
      rb_apply_ambiguity_spelling(session_id, "ni", 0, 2, NULL));
  char* after = copy_live_input(engine, session_id, &composing);
  check_input_unchanged("apply(..., spelling=NULL)", before, after, composing);
  free(after);

  check_bad_argument(
      "apply(live session, input=NULL, [0,2), spelling=\"ni\")",
      rb_apply_ambiguity_spelling(session_id, NULL, 0, 2, "ni"));
  after = copy_live_input(engine, session_id, &composing);
  check_input_unchanged("apply(..., input=NULL)", before, after, composing);
  free(after);

  check_bad_argument(
      "restore(live session, input=NULL, [0,2), expected=\"ni\", reduced=\"ni\")",
      rb_restore_ambiguity_spelling(session_id, NULL, 0, 2, "ni", "ni"));
  after = copy_live_input(engine, session_id, &composing);
  check_input_unchanged("restore(..., input=NULL)", before, after, composing);
  free(after);

  check_bad_argument(
      "restore(live session, input=\"ni\", [0,2), expected=\"ni\", reduced=NULL)",
      rb_restore_ambiguity_spelling(session_id, "ni", 0, 2, "ni", NULL));
  after = copy_live_input(engine, session_id, &composing);
  check_input_unchanged("restore(..., reduced=NULL)", before, after, composing);
  free(after);

  check_bad_argument(
      "restore(live session, input=\"ni\", [0,2), expected=NULL, reduced=\"ni\")",
      rb_restore_ambiguity_spelling(session_id, "ni", 0, 2, NULL, "ni"));
  after = copy_live_input(engine, session_id, &composing);
  check_input_unchanged("restore(..., expected=NULL)", before, after, composing);
  free(after);

  free(before);
  rb_session_destroy(engine, session_id);
  rb_engine_destroy(engine);

  printf("\nUNVERIFIED BOUNDARY: this harness does not assert that "
         "RB_AMBIG_FAILED is\n");
  printf("unreachable. A genuine post-write validation failure must still be "
         "able to\n");
  printf("report it (with the rollback re-read), or "
         "RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED\n");
  printf("when the re-read does not match. Forcing that state needs a live "
         "rewrite\n");
  printf("capability and is out of scope here.\n");

  printf("\n%d contract check(s), %d failure(s)\n", g_checks, g_failures);
  if (g_failures != 0) {
    printf("RESULT: FAIL — the invalid/no-session early-outs claim a verified "
           "rollback\n");
    return 1;
  }
  printf("RESULT: PASS\n");
  return 0;
}
