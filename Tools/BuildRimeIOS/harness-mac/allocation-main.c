/* Real librime, fault-injected bridge allocations, compiled with ASan/UBSan.
 * Include the production C bridge so only its malloc/calloc calls fail. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int allocation_count;
static int fail_at = -1;
static void* test_malloc(size_t size) {
  if (allocation_count++ == fail_at) return NULL;
  return malloc(size);
}
static void* test_calloc(size_t count, size_t size) {
  if (allocation_count++ == fail_at) return NULL;
  return calloc(count, size);
}
#define malloc test_malloc
#define calloc test_calloc
#include "../src/rime_bridge.c"
#undef malloc
#undef calloc

/* rime_spelling.cc is not linked: this test never asks for a spelling, so
 * there is no decoded dictionary for the bridge to drop. */
void rb_spelling_reset(void) {}

static void fault(int index) { allocation_count = 0; fail_at = index; }

int main(int argc, char** argv) {
  assert(argc == 3);
  // Fail each allocation in engine creation before setup. Cleanup must never
  // finalize a service this object does not own.
  for (int i = 0; i < 4; ++i) {
    fault(i);
    assert(rb_engine_create(argv[1], argv[2], "rime.allocation", NULL) == NULL);
  }
  fault(-1);
  rb_engine* e = rb_engine_create(argv[1], argv[2], "rime.allocation", NULL);
  assert(e && rb_engine_ready(e));
  uintptr_t sid = rb_session_create(e);
  assert(sid);
  assert(rb_select_schema(e, sid, "engine_test_pinyin26"));
  assert(rb_simulate_key_sequence(e, sid, "ni"));
  rb_snapshot* baseline = rb_snapshot_get(e, sid);
  assert(baseline && baseline->num_candidates > 0);
  fault(-1);
  rb_snapshot* counted = rb_snapshot_get(e, sid);
  int total = allocation_count;
  rb_snapshot_free(counted);
  for (int i = 0; i < total; ++i) {
    fault(i);
    rb_snapshot* failed = rb_snapshot_get(e, sid);
    assert(!failed);
    fault(-1);
    rb_snapshot* retry = rb_snapshot_get(e, sid);
    assert(retry && !strcmp(retry->input, "ni"));
    assert(!strcmp(retry->candidates[0].text, baseline->candidates[0].text));
    rb_snapshot_free(retry);
  }
  rb_snapshot_free(baseline);
  printf("PASS: %d candidate-snapshot allocation failures recover without invalid access\n", total);
  rb_clear_composition(e, sid);
  assert(rb_simulate_key_sequence(e, sid, "nihao "));
  fault(-1);
  baseline = rb_snapshot_get(e, sid);
  assert(baseline && !strcmp(baseline->commit_text, "你好"));
  total = allocation_count;
  rb_snapshot_free(baseline);
  for (int i = 0; i < total; ++i) {
    assert(rb_simulate_key_sequence(e, sid, "nihao "));
    fault(i);
    assert(rb_snapshot_get(e, sid) == NULL);
    fault(-1);
    rb_snapshot* retry = rb_snapshot_get(e, sid);
    assert(retry && !strcmp(retry->commit_text, "你好"));
    rb_snapshot_free(retry);
    retry = rb_snapshot_get(e, sid);
    assert(retry && !strcmp(retry->commit_text, ""));
    rb_snapshot_free(retry);
  }
  printf("PASS: %d commit-snapshot allocation failures preserve pending commit exactly once\n", total);
  rb_engine_destroy(e);
  puts("ALL PASS");
  return 0;
}
