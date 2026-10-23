// ---------------------------------------------------------------------------
// rime_bridge.c — implementation of the thin C bridge over librime's C API.
//
// Memory model:
//   * rb_engine and copied strings are malloc'd by this file;
//   * commit text retains librime's allocation and is released by free_commit;
//   * rb_snapshot* are malloc'd trees, freed by rb_snapshot_free();
//   * the only state written from another thread is `deploy_state` (atomic
//     int, written by the notification handler on the maintenance thread).
//
// See rime_bridge.h for the concurrency contract.
// ---------------------------------------------------------------------------
#include "rime_bridge.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <limits.h>
#include <sys/stat.h>

#include "rime_api.h"

#ifdef RB_WITH_LUA
void rb_require_lua(void);
#endif
#ifdef RB_WITH_T9
void rb_require_t9(void);
#define RB_T9_MODULE "t9_original",
#else
#define RB_T9_MODULE
#endif
#ifdef RB_WITH_PREDICT
void rb_require_predict(void);
#define RB_PREDICT_MODULE "predict",
#else
#define RB_PREDICT_MODULE
#endif

struct rb_engine {
  RimeApi* api;
  char* shared_data_dir;
  char* user_data_dir;
  char* app_name;
  char* distribution_version;
  char* prebuilt_dir;
  char error[512];
  atomic_int deploy_state;
  int ready;
};

/* librime owns process-global service/registry/deployer state. All calls are
 * serialized by the wrapper; only the owner may initialize/finalize it. */
static rb_engine* rb_owner;
static int rb_setup_done;

/* Keep librime's commit allocation until snapshot_free: no fallible bridge
 * allocation is allowed after get_commit consumes the pending text. */
typedef struct {
  rb_snapshot snapshot;
  RimeCommit commit;
  RimeApi* api;
} rb_owned_snapshot;

static void rb_set_error(rb_engine* engine, const char* fmt, ...) {
  if (!engine) return;
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(engine->error, sizeof(engine->error), fmt, ap);
  va_end(ap);
}

static char* rb_strdup(const char* s) {
  if (!s) return NULL;
  size_t n = strlen(s) + 1;
  char* p = (char*)malloc(n);
  if (p) memcpy(p, s, n);
  return p;
}

static char* rb_strdup_or_empty(const char* s) {
  return rb_strdup(s ? s : "");
}

void rb_grammar_diagnostics_free(char* json) { free(json); }
#ifndef RB_WITH_GRAMMAR
#ifdef RB_WITH_T9
int rb_t9_component_available(const char* name);
int rb_component_available(const char* name) { return rb_t9_component_available(name); }
#else
int rb_component_available(const char* name) { (void)name; return 0; }
#endif
int rb_grammar_session_loaded(size_t session_id, const char* model_path) {
  (void)session_id; (void)model_path; return 0;
}
void rb_grammar_diagnostics_reset(int enabled) { (void)enabled; }
char* rb_grammar_diagnostics_json(void) {
  return rb_strdup("{\"recording\":false,\"queryCount\":0,\"lookupCount\":0,\"matchCount\":0,\"loads\":[],\"samples\":[]}");
}
#endif

/* Deploy notification handler; runs on the maintenance thread. */
static void rb_notify(void* context_object, RimeSessionId session_id,
                      const char* message_type, const char* message_value) {
  (void)session_id;
  rb_engine* engine = (rb_engine*)context_object;
  if (!engine || !message_type || !message_value) return;
  if (strcmp(message_type, "deploy") == 0) {
    if (strcmp(message_value, "start") == 0) {
      engine->deploy_state = RB_DEPLOY_START;
    } else if (strcmp(message_value, "success") == 0) {
      engine->deploy_state = RB_DEPLOY_SUCCESS;
    } else if (strcmp(message_value, "failure") == 0) {
      engine->deploy_state = RB_DEPLOY_FAILURE;
    }
  }
}

static rb_engine* rb_engine_create_impl(const char* shared_data_dir,
                                        const char* user_data_dir, const char* app_name,
                                        const char* distribution_version,
                                        const char* prebuilt_dir) {
  if (!shared_data_dir || !user_data_dir || !app_name) {
    return NULL;
  }
  rb_engine* engine = (rb_engine*)calloc(1, sizeof(rb_engine));
  if (!engine) return NULL;
  atomic_init(&engine->deploy_state, RB_DEPLOY_NONE);
  if (rb_owner) {
    rb_set_error(engine, "another RimeEngine is active in this process; shut it down before starting this instance");
    return engine;
  }
  engine->api = rime_get_api();
  if (!engine->api) {
    rb_set_error(engine, "rime_get_api() returned NULL");
    free(engine);
    return NULL;
  }
  engine->shared_data_dir = rb_strdup(shared_data_dir);
  engine->user_data_dir = rb_strdup(user_data_dir);
  engine->app_name = rb_strdup(app_name);
  engine->distribution_version = rb_strdup(distribution_version);
  engine->prebuilt_dir = rb_strdup(prebuilt_dir);
  if (!engine->shared_data_dir || !engine->user_data_dir || !engine->app_name ||
      (distribution_version && !engine->distribution_version) ||
      (prebuilt_dir && !engine->prebuilt_dir)) {
    rb_set_error(engine, "out of memory");
    rb_engine_destroy(engine);
    return NULL;
  }

  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = engine->shared_data_dir;
  traits.user_data_dir = engine->user_data_dir;
  traits.distribution_name = "songyan-rime";
  traits.distribution_code_name = "songyan-rime";
  traits.distribution_version = engine->distribution_version;
  traits.app_name = engine->app_name;
  traits.min_log_level = 1; /* WARNING: keep INFO noise out of the log */
  /* "" -> stderr only. glog holds an fcntl lock on its log files for the whole
   * process lifetime; iOS kills a suspended keyboard extension holding any file
   * lock (0xdead10cc), so the engine must never create a log file. */
  traits.log_dir = "";
  if (engine->prebuilt_dir) {
    traits.prebuilt_data_dir = engine->prebuilt_dir;
    // Deployed resolver normally tries user/build before shared/build. Point
    // BOTH deployed roots at this immutable generation to avoid stale private
    // compiled files shadowing it. No maintenance may run in this mode.
    traits.staging_dir = engine->prebuilt_dir;
  }
#if defined(RB_WITH_LUA) && defined(RB_WITH_GRAMMAR)
  extern void rb_require_grammar(void);
  static const char* modules[] = {"default", "lua", "octagram", RB_T9_MODULE RB_PREDICT_MODULE NULL};
  rb_require_lua();
  rb_require_grammar();
  traits.modules = modules;
#elif defined(RB_WITH_GRAMMAR)
  extern void rb_require_grammar(void);
  static const char* modules[] = {"default", "octagram", RB_T9_MODULE RB_PREDICT_MODULE NULL};
  rb_require_grammar();
  traits.modules = modules;
#elif defined(RB_WITH_LUA)
  static const char* modules[] = {"default", "lua", RB_T9_MODULE RB_PREDICT_MODULE NULL};
  rb_require_lua();
  traits.modules = modules;
#elif defined(RB_WITH_T9)
  static const char* modules[] = {"default", RB_T9_MODULE RB_PREDICT_MODULE NULL};
  traits.modules = modules;
#endif
#ifdef RB_WITH_T9
  rb_require_t9();
#endif
#ifdef RB_WITH_PREDICT
  rb_require_predict();
#endif

  engine->deploy_state = RB_DEPLOY_NONE;
  rb_owner = engine;
  if (!rb_setup_done) {
    engine->api->setup(&traits);
    rb_setup_done = 1;
  }
  engine->api->set_notification_handler(&rb_notify, engine);
  engine->api->initialize(&traits);

  engine->deploy_state = RB_DEPLOY_NONE;
  if (engine->prebuilt_dir) {
    RimeConfig config = {0};
    char version[64] = {0};
    int valid = engine->api->config_open("default", &config) &&
        engine->api->config_get_string(&config, "__build_info/rime_version", version, sizeof(version)) &&
        strcmp(version, engine->api->get_version()) == 0;
    if (config.ptr) engine->api->config_close(&config);
    if (!valid) {
      rb_set_error(engine, "prebuilt default.yaml missing or version mismatch: compiled=%s runtime=%s; republish from the host App",
                   version[0] ? version : "missing", engine->api->get_version());
      return engine;
    }
    engine->ready = RB_TRUE;
    return engine;
  }
  int started = engine->api->start_maintenance(RB_TRUE);
  engine->api->join_maintenance_thread();
  if (!started || engine->deploy_state == RB_DEPLOY_FAILURE) {
    /* Keep the engine object alive so the caller can read the error; it must
     * call rb_engine_destroy() to release it. `ready` stays RB_FALSE. */
    rb_set_error(engine,
                 "initial deployment failed (deploy notification reported "
                 "failure); check the schema/lexicon in %s",
                 engine->shared_data_dir);
    return engine;
  }
  engine->ready = RB_TRUE;
  return engine;
}

rb_engine* rb_engine_create(const char* shared_data_dir,
                            const char* user_data_dir, const char* app_name,
                            const char* distribution_version) {
  return rb_engine_create_impl(shared_data_dir, user_data_dir, app_name,
                               distribution_version, NULL);
}

rb_engine* rb_engine_create_prebuilt(const char* shared_data_dir,
                                    const char* user_data_dir, const char* app_name,
                                    const char* distribution_version,
                                    const char* compiled_dir) {
  if (!compiled_dir || !*compiled_dir) return NULL;
  return rb_engine_create_impl(shared_data_dir, user_data_dir, app_name,
                               distribution_version, compiled_dir);
}

void rb_engine_destroy(rb_engine* engine) {
  if (!engine) return;
  rb_spelling_reset();
  if (engine == rb_owner && engine->api) {
    engine->api->join_maintenance_thread();
    engine->api->set_notification_handler(NULL, NULL);
    engine->api->finalize();
    rb_owner = NULL;
  }
  free(engine->shared_data_dir);
  free(engine->user_data_dir);
  free(engine->app_name);
  free(engine->distribution_version);
  free(engine->prebuilt_dir);
  free(engine);
}

const char* rb_engine_last_error(const rb_engine* engine) {
  return engine ? engine->error : "engine is NULL";
}

int rb_engine_ready(const rb_engine* engine) {
  return (engine && engine->ready) ? RB_TRUE : RB_FALSE;
}

const char* rb_engine_version(const rb_engine* engine) {
  if (!engine || !engine->api || !engine->api->get_version) return "-";
  const char* v = engine->api->get_version();
  return v ? v : "-";
}

uintptr_t rb_session_create(rb_engine* engine) {
  if (!engine || !engine->api || !engine->ready) return 0;
  /* Fresh sessions follow (re)deployment; drop any decoded dictionary so stale
   * table/prism paths cannot survive a rebuild. */
  rb_spelling_reset();
  return engine->api->create_session();
}

void rb_session_destroy(rb_engine* engine, uintptr_t session_id) {
  if (!engine || !engine->api || !session_id) return;
  engine->api->destroy_session(session_id);
}

int rb_process_key(rb_engine* engine, uintptr_t session_id, int keycode,
                   int mask) {
  if (!engine || !engine->api) return RB_FALSE;
  return engine->api->process_key(session_id, keycode, mask) ? RB_TRUE
                                                             : RB_FALSE;
}

int rb_commit_composition(rb_engine* engine, uintptr_t session_id) {
  if (!engine || !engine->api) return RB_FALSE;
  return engine->api->commit_composition(session_id) ? RB_TRUE : RB_FALSE;
}

int rb_select_candidate_on_current_page(rb_engine* engine,
                                        uintptr_t session_id, size_t index) {
  if (!engine || !engine->api) return RB_FALSE;
  return engine->api->select_candidate_on_current_page(session_id, index)
             ? RB_TRUE
             : RB_FALSE;
}

int rb_select_candidate(rb_engine* engine, uintptr_t session_id, size_t index) {
  if (!engine || !engine->api || index > INT_MAX) return RB_FALSE;
  return engine->api->select_candidate(session_id, index) ? RB_TRUE : RB_FALSE;
}

int rb_change_page(rb_engine* engine, uintptr_t session_id, int backward) {
  if (!engine || !engine->api) return RB_FALSE;
  return engine->api->change_page(session_id, backward ? RB_TRUE : RB_FALSE)
             ? RB_TRUE
             : RB_FALSE;
}

int rb_clear_composition(rb_engine* engine, uintptr_t session_id) {
  if (!engine || !engine->api) return RB_FALSE;
  engine->api->clear_composition(session_id);
  return RB_TRUE;
}

int rb_simulate_key_sequence(rb_engine* engine, uintptr_t session_id,
                             const char* key_sequence) {
  if (!engine || !engine->api || !key_sequence) return RB_FALSE;
  return engine->api->simulate_key_sequence(session_id, key_sequence)
             ? RB_TRUE
             : RB_FALSE;
}

int rb_set_option(rb_engine* engine, uintptr_t session_id, const char* option,
                  int value) {
  if (!engine || !engine->api || !option) return RB_FALSE;
  engine->api->set_option(session_id, option, value ? RB_TRUE : RB_FALSE);
  return RB_TRUE;
}

int rb_get_option(rb_engine* engine, uintptr_t session_id, const char* option) {
  if (!engine || !engine->api || !option) return RB_FALSE;
  return engine->api->get_option(session_id, option) ? RB_TRUE : RB_FALSE;
}

int rb_select_schema(rb_engine* engine, uintptr_t session_id,
                     const char* schema_id) {
  if (!engine || !engine->api || !schema_id) return RB_FALSE;
  if (!session_id) return RB_FALSE;
  return engine->api->select_schema(session_id, schema_id) ? RB_TRUE
                                                           : RB_FALSE;
}

int rb_get_current_schema(rb_engine* engine, uintptr_t session_id, char* buf,
                          size_t buf_size) {
  if (!engine || !engine->api || !buf || buf_size == 0) return RB_FALSE;
  return engine->api->get_current_schema(session_id, buf, buf_size) ? RB_TRUE
                                                                    : RB_FALSE;
}

rb_snapshot* rb_snapshot_get(rb_engine* engine, uintptr_t session_id) {
  if (!engine || !engine->api) return NULL;
  rb_owned_snapshot* owned = (rb_owned_snapshot*)calloc(1, sizeof(*owned));
  if (!owned) return NULL;
  rb_snapshot* snap = &owned->snapshot;
  owned->api = engine->api;
  RIME_STRUCT_INIT(RimeCommit, owned->commit);
  int failed = 0;
#define SNAP_FAIL() do { failed = 1; } while (0)

  RIME_STRUCT(RimeStatus, status);
  if (engine->api->get_status(session_id, &status)) {
    snap->schema_id = rb_strdup_or_empty(status.schema_id);
    snap->schema_name = rb_strdup_or_empty(status.schema_name);
    snap->is_composing = status.is_composing ? RB_TRUE : RB_FALSE;
    snap->is_ascii_mode = status.is_ascii_mode ? RB_TRUE : RB_FALSE;
    snap->is_full_shape = status.is_full_shape ? RB_TRUE : RB_FALSE;
    snap->is_ascii_punct = status.is_ascii_punct ? RB_TRUE : RB_FALSE;
    engine->api->free_status(&status);
  } else {
    SNAP_FAIL();
  }

  const char* input = engine->api->get_input(session_id);
  snap->input = rb_strdup_or_empty(input);

  RIME_STRUCT(RimeContext, context);
  if (engine->api->get_context(session_id, &context)) {
    RimeComposition* comp = &context.composition;
    if (comp->preedit) {
      snap->preedit = rb_strdup(comp->preedit);
      snap->preedit_cursor = comp->cursor_pos;
      snap->preedit_sel_start = comp->sel_start;
      snap->preedit_sel_end = comp->sel_end;
    }
    if (comp->preedit && !snap->preedit) SNAP_FAIL();
    RimeMenu* menu = &context.menu;
    snap->page_no = menu->page_no;
    snap->page_size = menu->page_size;
    snap->is_last_page = menu->is_last_page ? RB_TRUE : RB_FALSE;
    snap->highlighted_index = menu->highlighted_candidate_index;
    snap->num_candidates = menu->num_candidates;
    if (menu->num_candidates > 0 && menu->candidates) {
      snap->candidates =
          (rb_candidate*)calloc((size_t)menu->num_candidates,
                                sizeof(rb_candidate));
      if (!snap->candidates) SNAP_FAIL();
      for (int i = 0; snap->candidates && i < menu->num_candidates; ++i) {
        snap->candidates[i].text =
            rb_strdup_or_empty(menu->candidates[i].text);
        if (menu->candidates[i].comment) {
          snap->candidates[i].comment =
              rb_strdup(menu->candidates[i].comment);
          if (!snap->candidates[i].comment) SNAP_FAIL();
        }
        if (!snap->candidates[i].text) SNAP_FAIL();
      }
    }
    /* Page-level select metadata. Copied verbatim from the live menu/context;
     * an absent declaration stays NULL (never synthesized as 1..9). librime
     * only emits select_keys when non-empty, and emits select_labels with
     * exactly `page_size` entries (each a NUL-terminated owned string). Both
     * allocations are freed by librime's free_context below, so we must copy
     * here before releasing it. */
    if (menu->select_keys && menu->select_keys[0] != '\0') {
      snap->select_keys = rb_strdup(menu->select_keys);
      if (!snap->select_keys) SNAP_FAIL();
    }
    if (RIME_STRUCT_HAS_MEMBER(context, context.select_labels) &&
        context.select_labels && menu->page_size > 0) {
      snap->select_labels =
          (char**)calloc((size_t)menu->page_size, sizeof(char*));
      if (!snap->select_labels) SNAP_FAIL();
      snap->num_select_labels = menu->page_size;
      for (int i = 0; snap->select_labels && i < menu->page_size; ++i) {
        snap->select_labels[i] =
            rb_strdup_or_empty(context.select_labels[i]);
        if (!snap->select_labels[i]) SNAP_FAIL();
      }
    }
    engine->api->free_context(&context);
  } else {
    SNAP_FAIL();
  }
#undef SNAP_FAIL

  if (!snap->preedit) snap->preedit = rb_strdup("");
  // Candidate spelling is NOT computed here: the front end requests it (through
  // rb_copy_highlighted_spelling) only for its reduced layouts, so an ordinary
  // 26-key snapshot performs no translator/dictionary work.
  snap->commit_text = rb_strdup("");
  if (!snap->preedit || !snap->schema_id || !snap->schema_name ||
      !snap->input || !snap->commit_text) failed = 1;

  if (failed) {
    rb_snapshot_free(snap);
    return NULL;
  }
  if (engine->api->get_commit(session_id, &owned->commit)) {
    free(snap->commit_text);
    snap->commit_text = owned->commit.text;
  }
  return snap;
}

void rb_snapshot_free(rb_snapshot* snapshot) {
  if (!snapshot) return;
  free(snapshot->schema_id);
  free(snapshot->schema_name);
  free(snapshot->input);
  free(snapshot->preedit);
  rb_owned_snapshot* owned = (rb_owned_snapshot*)snapshot;
  if (owned->commit.text) owned->api->free_commit(&owned->commit);
  else free(snapshot->commit_text);
  if (snapshot->candidates) {
    for (int i = 0; i < snapshot->num_candidates; ++i) {
      free(snapshot->candidates[i].text);
      free(snapshot->candidates[i].comment);
    }
    free(snapshot->candidates);
  }
  free(snapshot->select_keys);
  if (snapshot->select_labels) {
    for (int i = 0; i < snapshot->num_select_labels; ++i) {
      free(snapshot->select_labels[i]);
    }
    free(snapshot->select_labels);
  }
  free(snapshot);
}

int rb_sync_user_data(rb_engine* engine) {
  if (!engine || !engine->api) return RB_FALSE;
  if (engine->prebuilt_dir) return RB_FALSE;
  engine->deploy_state = RB_DEPLOY_NONE;
  return engine->api->sync_user_data() ? RB_TRUE : RB_FALSE;
}

int rb_start_maintenance(rb_engine* engine, int full_check) {
  if (!engine || !engine->api) return RB_FALSE;
  if (engine->prebuilt_dir) return RB_FALSE;
  engine->deploy_state = RB_DEPLOY_NONE;
  return engine->api->start_maintenance(full_check ? RB_TRUE : RB_FALSE)
             ? RB_TRUE
             : RB_FALSE;
}

void rb_join_maintenance(rb_engine* engine) {
  if (!engine || !engine->api) return;
  engine->api->join_maintenance_thread();
}

int rb_last_deploy_state(const rb_engine* engine) {
  return engine ? engine->deploy_state : RB_DEPLOY_NONE;
}
