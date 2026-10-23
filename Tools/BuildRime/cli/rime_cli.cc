// ---------------------------------------------------------------------------
// rime_cli — minimal native driver for a pinned static librime build.
//
// Purpose (engine verification):
//   * point librime at an explicit shared-data dir and an isolated user dir
//   * deploy (first run builds dictionaries / prisms into the user dir)
//   * drive a session with raw key sequences, print candidates
//   * select candidates, commit (drives userdb learning)
//   * export/merge learning snapshots through librime's native sync
//
// Usage:
//   rime_cli --shared DIR --user DIR [--schema ID] [--script FILE]
//
// With no --script it reads commands from stdin. Blank lines and lines
// starting with '#' are ignored. Commands:
//   schema <schema_id>          switch session schema (verified)
//   keys   <key_sequence>       feed keys, e.g. `keys nihao`
//   select <n>                  select candidate n (1-based) on current page
//   page   next | prev          turn candidate page (numeric form removed)
//   commit                       commit the current composition (Return)
//   sync                          run native sync_user_data; wait for the
//                                 maintenance to finish, recreate the session
//                                 and restore the schema (librime's sync
//                                 destroys all sessions); then keep reading.
//   dump                         print full session state
//   version                      print librime version
//   quit                         shutdown
//
// Output contract:
//   State is printed to stdout after keys/select/page/commit/dump with stable,
//   greppable tags: `commit:`, `cand <k>:`, `preedit:`, `input:`, `schema:`,
//   `menu:`, `sync:`, `session:`, `schema-restored:`. Diagnostics go to
//   stderr. In batch mode (stdin or --script) any failed schema switch, failed
//   key/select/page command, unknown command or failed deployment makes the
//   process exit with status 1 instead of hiding the error.
//
//   `sync` semantics: librime's RimeSyncUserData() first destroys every
//   session, then starts an asynchronous maintenance run; its return value is
//   only "maintenance started", not completion. rime_cli therefore joins the
//   maintenance thread and reports the deployment result delivered by the
//   engine (`deploy success`/`deploy failure`), then creates a fresh session
//   and re-selects the previously active schema before printing `sync: ok`.
//
// Built by Tools/BuildRime/scripts/04-build-cli.sh. Dependency versions are
// pinned in Tools/BuildRime/VERSIONS.env.
// ---------------------------------------------------------------------------
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>

#include <rime_api.h>

static RimeApi* rime = nullptr;

// Last deployment result as reported by the engine's notification handler:
// 0 = no deploy message seen yet, 1 = deploy started, 2 = deploy success,
// 3 = deploy failure.
static volatile int g_deploy_state = 0;
static Bool g_had_error = False;
static std::string g_active_schema;

static void mark_error() { g_had_error = True; }

static void on_message(void* context_object,
                       RimeSessionId session_id,
                       const char* message_type,
                       const char* message_value) {
  (void)context_object;
  fprintf(stderr, "message: [%zu] [%s] %s\n", session_id, message_type,
          message_value);
  if (strcmp(message_type, "deploy") == 0) {
    if (strcmp(message_value, "start") == 0) {
      g_deploy_state = 1;
    } else if (strcmp(message_value, "success") == 0) {
      g_deploy_state = 2;
    } else if (strcmp(message_value, "failure") == 0) {
      g_deploy_state = 3;
    }
  }
}

static void print_commit(RimeSessionId session_id) {
  RIME_STRUCT(RimeCommit, commit);
  if (rime->get_commit(session_id, &commit)) {
    printf("commit: %s\n", commit.text ? commit.text : "");
    rime->free_commit(&commit);
  }
}

static void dump(RimeSessionId session_id) {
  RIME_STRUCT(RimeStatus, status);
  if (rime->get_status(session_id, &status)) {
    printf("schema: %s (%s) composing=%d ascii=%d\n",
           status.schema_id ? status.schema_id : "-",
           status.schema_name ? status.schema_name : "-",
           status.is_composing, status.is_ascii_mode);
    rime->free_status(&status);
  }

  RIME_STRUCT(RimeContext, context);
  if (rime->get_context(session_id, &context)) {
    const char* input = rime->get_input(session_id);
    if (input && *input) printf("input: %s\n", input);
    RimeComposition* comp = &context.composition;
    if (comp->preedit && *comp->preedit) {
      printf("preedit: %s  cursor=%d sel=[%d,%d)\n", comp->preedit,
             comp->cursor_pos, comp->sel_start, comp->sel_end);
    }
    RimeMenu* menu = &context.menu;
    printf("menu: page=%d num_candidates=%d highlighted=%d\n",
           menu->page_no + 1, menu->num_candidates,
           menu->highlighted_candidate_index);
    for (int i = 0; i < menu->num_candidates; ++i) {
      const RimeCandidate* c = &menu->candidates[i];
      if (c->comment)
        printf("cand %d: %s  [%s]\n", i + 1, c->text, c->comment);
      else
        printf("cand %d: %s\n", i + 1, c->text);
    }
    rime->free_context(&context);
  }
  print_commit(session_id);
  fflush(stdout);
}

// Select a schema and confirm the engine actually switched to it. The engine's
// select_schema() returns True even for unknown schema ids (it loads a
// fallback), so we first validate the id against the deployed schema list
// (schema_list in the shared dir's default.yaml).
static Bool schema_is_available(const char* schema_id) {
  RimeSchemaList list;
  if (!rime->get_schema_list(&list) || list.size == 0) {
    fprintf(stderr,
            "error: no schema list available (shared dir needs a default.yaml "
            "with schema_list)\n");
    return False;
  }
  Bool found = False;
  for (size_t i = 0; i < list.size; ++i) {
    if (list.list[i].schema_id &&
        strcmp(list.list[i].schema_id, schema_id) == 0) {
      found = True;
      break;
    }
  }
  rime->free_schema_list(&list);
  if (!found) {
    fprintf(stderr, "error: schema '%s' is not in the deployed schema list\n",
            schema_id);
    return False;
  }
  return True;
}

static Bool select_and_verify(RimeSessionId session_id,
                              const std::string& schema_id) {
  if (!schema_is_available(schema_id.c_str())) {
    return False;
  }
  if (!rime->select_schema(session_id, schema_id.c_str())) {
    fprintf(stderr, "error: cannot select schema '%s'\n", schema_id.c_str());
    return False;
  }
  char current[128] = {0};
  if (!rime->get_current_schema(session_id, current, sizeof(current)) ||
      strcmp(current, schema_id.c_str()) != 0) {
    fprintf(stderr,
            "error: schema '%s' selected but engine reports current '%s'\n",
            schema_id.c_str(), current[0] ? current : "<none>");
    return False;
  }
  return True;
}

// Run librime's native sync to completion, then recreate the session and
// restore the previously active schema so input can continue in this process.
static void do_sync(RimeSessionId* session_id) {
  std::string want_schema = g_active_schema;
  g_deploy_state = 0;
  Bool started = rime->sync_user_data();
  fprintf(stderr, "sync: maintenance started=%d\n", (int)started);
  // RimeSyncUserData() cleans up all sessions and starts an asynchronous
  // maintenance run; its return value is NOT the merge result. Wait for the
  // maintenance thread so the snapshot export/merge is complete before we
  // report success or continue typing.
  rime->join_maintenance_thread();
  int deploy = g_deploy_state;

  RimeSessionId fresh = rime->create_session();
  if (!fresh) {
    fprintf(stderr, "error: cannot recreate session after sync\n");
    printf("session: <none>\n");
    mark_error();
  } else {
    *session_id = fresh;
    printf("session: %zu\n", (size_t)fresh);
    if (!want_schema.empty()) {
      if (select_and_verify(fresh, want_schema)) {
        printf("schema-restored: %s\n", want_schema.c_str());
      } else {
        printf("schema-restored: %s FAILED\n", want_schema.c_str());
        mark_error();
      }
    }
  }

  if (deploy == 2) {
    printf("sync: ok\n");  // deployment finished without failures
  } else if (deploy == 3) {
    fprintf(stderr, "sync: deployment reported failure\n");
    printf("sync: failed\n");
    mark_error();
  } else {
    fprintf(stderr, "sync: no deployment completion reported (state=%d)\n",
            deploy);
    printf("sync: error\n");
    mark_error();
  }
  fflush(stdout);
}

int main(int argc, char* argv[]) {
  const char* shared_dir = nullptr;
  const char* user_dir = nullptr;
  const char* schema_id = nullptr;
  const char* script_path = nullptr;

  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--shared") && i + 1 < argc) shared_dir = argv[++i];
    else if (!strcmp(argv[i], "--user") && i + 1 < argc) user_dir = argv[++i];
    else if (!strcmp(argv[i], "--schema") && i + 1 < argc) schema_id = argv[++i];
    else if (!strcmp(argv[i], "--script") && i + 1 < argc) script_path = argv[++i];
    else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
      fprintf(stderr,
              "usage: rime_cli --shared DIR --user DIR [--schema ID] "
              "[--script FILE]\n");
      return 0;
    } else {
      fprintf(stderr, "unknown argument: %s\n", argv[i]);
      return 2;
    }
  }
  if (!shared_dir || !user_dir) {
    fprintf(stderr, "error: --shared and --user are required\n");
    return 2;
  }

  rime = rime_get_api();
  if (!rime) {
    fprintf(stderr, "error: rime_get_api() returned NULL\n");
    return 1;
  }

  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared_dir;
  traits.user_data_dir = user_dir;
  traits.distribution_name = "songyan-engine-cli";
  traits.distribution_code_name = "songyan-engine-cli";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.songyan.cli";
  traits.min_log_level = 1;  // WARNING: keep INFO noise out of logs
  rime->setup(&traits);
  rime->set_notification_handler(&on_message, nullptr);

  fprintf(stderr, "initializing (shared=%s user=%s)...\n", shared_dir,
          user_dir);
  rime->initialize(&traits);
  // First run on a fresh user dir performs a full deployment (compiles the
  // dictionaries/prisms referenced by the schemas in shared dir). Wait for it
  // and surface failures.
  g_deploy_state = 0;
  if (rime->start_maintenance(True)) rime->join_maintenance_thread();
  if (g_deploy_state == 3) {
    fprintf(stderr, "deploy: failed\n");
    mark_error();
  }
  fprintf(stderr, "ready.\n");

  RimeSessionId session_id = rime->create_session();
  if (!session_id) {
    fprintf(stderr, "error: cannot create session\n");
    mark_error();
  } else if (schema_id) {
    if (!select_and_verify(session_id, schema_id)) {
      mark_error();
    } else {
      g_active_schema = schema_id;
    }
  } else {
    char current[128] = {0};
    if (rime->get_current_schema(session_id, current, sizeof(current)) &&
        current[0]) {
      g_active_schema = current;
    }
  }

  FILE* in = stdin;
  if (script_path) {
    in = fopen(script_path, "r");
    if (!in) {
      fprintf(stderr, "error: cannot open script %s\n", script_path);
      if (session_id) rime->destroy_session(session_id);
      rime->finalize();
      return 1;
    }
  }

  std::string line;
  char buf[4096];
  while (fgets(buf, sizeof(buf), in)) {
    line = buf;
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
      line.pop_back();
    if (line.empty() || line[0] == '#') continue;

    if (line == "quit" || line == "exit") break;
    if (line == "dump") { dump(session_id); continue; }
    if (line == "sync") { do_sync(&session_id); continue; }
    if (line == "version") {
      printf("version: %s\n", rime->get_version() ? rime->get_version() : "-");
      continue;
    }
    if (line == "commit") {
      RIME_STRUCT(RimeStatus, status);
      Bool composing = False;
      if (rime->get_status(session_id, &status)) {
        composing = status.is_composing;
        rime->free_status(&status);
      }
      Bool ok = rime->commit_composition(session_id);
      if (!ok && composing) {
        fprintf(stderr, "commit_composition failed while composing\n");
        mark_error();
      }
      dump(session_id);
      continue;
    }
    const char* arg = nullptr;
    auto has_arg = [&](const char* prefix) -> bool {
      size_t n = strlen(prefix);
      if (strncmp(line.c_str(), prefix, n) == 0 &&
          (line.size() == n || line[n] == ' ')) {
        arg = line.c_str() + n;
        while (*arg == ' ') ++arg;
        return true;
      }
      return false;
    };
    if (has_arg("keys")) {
      if (!*arg) {
        fprintf(stderr, "keys: missing sequence\n");
        mark_error();
        continue;
      }
      if (!rime->simulate_key_sequence(session_id, arg)) {
        fprintf(stderr, "simulate_key_sequence failed: %s\n", arg);
        mark_error();
      }
      dump(session_id);
      continue;
    }
    if (has_arg("schema")) {
      if (!*arg) {
        fprintf(stderr, "schema: missing schema id\n");
        mark_error();
        dump(session_id);
        continue;
      }
      if (select_and_verify(session_id, arg)) {
        g_active_schema = arg;
      } else {
        mark_error();
      }
      dump(session_id);
      continue;
    }
    if (has_arg("select")) {
      int n = atoi(arg);
      if (n >= 1 &&
          rime->select_candidate_on_current_page(session_id, (size_t)(n - 1))) {
        dump(session_id);
      } else {
        fprintf(stderr, "cannot select candidate %d\n", n);
        mark_error();
      }
      continue;
    }
    if (has_arg("page")) {
      // Only next/prev are supported: a numeric "page N" is rejected.
      if (!strcmp(arg, "next")) {
        if (!rime->change_page(session_id, False))
          printf("page: unchanged\n");  // benign boundary condition
        dump(session_id);
      } else if (!strcmp(arg, "prev")) {
        if (!rime->change_page(session_id, True))
          printf("page: unchanged\n");  // benign boundary condition
        dump(session_id);
      } else {
        fprintf(stderr, "page: expected 'next' or 'prev', got '%s'\n", arg);
        mark_error();
      }
      continue;
    }
    fprintf(stderr, "unrecognized command: %s\n", line.c_str());
    mark_error();
  }

  if (in != stdin) fclose(in);
  if (session_id) rime->destroy_session(session_id);
  rime->finalize();
  return g_had_error ? 1 : 0;
}
