#include "RimeLeversSupport.h"
// This translation unit disables Clang modules: include only the original int-Bool API.
#include <RimeKit/rime_api.h>
#include <RimeKit/rime_levers_api.h>
#include <stdlib.h>

_Static_assert(sizeof(Bool) == sizeof(int), "Original int-Bool public API required");
#define PROVIDED(p, T, f) ((p) && (p)->data_size >= 0 && \
  (size_t)(p)->data_size + sizeof((p)->data_size) >= \
  offsetof(T, f) + sizeof((p)->f) && RIME_PROVIDED(p, f))

static RimeModule* module_api(RimeApi* api) {
  return PROVIDED(api, RimeApi, find_module) ? api->find_module("levers") : NULL;
}

static RimeLeversApi* levers_api(void) {
  RimeModule* module = module_api(rime_get_api());
  if (!PROVIDED(module, RimeModule, get_api)) return NULL;
  return (RimeLeversApi*)module->get_api();
}

int rls_available(void) {
  RimeLeversApi* api = levers_api();
  RimeApi* core = rime_get_api();
  RimeModule* module = module_api(core);
  return PROVIDED(module, RimeModule, initialize) &&
    PROVIDED(core, RimeApi, run_task) &&
    PROVIDED(api, RimeLeversApi, user_dict_iterator_init) &&
    PROVIDED(api, RimeLeversApi, user_dict_iterator_destroy) &&
    PROVIDED(api, RimeLeversApi, next_user_dict) &&
    PROVIDED(api, RimeLeversApi, backup_user_dict) &&
    PROVIDED(api, RimeLeversApi, restore_user_dict);
}

int rls_prepare_installation(void) {
  RimeApi* api = rime_get_api();
  RimeModule* module = module_api(api);
  if (!PROVIDED(module, RimeModule, initialize) || !PROVIDED(api, RimeApi, run_task)) return 0;
  module->initialize();
  // On first creation only user_id is set; reloading initializes sync_dir too.
  return api->run_task("installation_update") && api->run_task("installation_update");
}

typedef struct {
  RimeUserDictIterator iterator;
  int initialized;
} RLSUserDictList;

int rls_user_dict_list_create(void** result) {
  RimeLeversApi* api = levers_api();
  if (!result || !PROVIDED(api, RimeLeversApi, user_dict_iterator_init)) return 0;
  *result = NULL;
  RLSUserDictList* list = (RLSUserDictList*)calloc(1, sizeof(RLSUserDictList));
  if (!list) return 0;
  list->initialized = api->user_dict_iterator_init(&list->iterator);
  *result = list;
  return 1;
}

const char* rls_user_dict_list_next(void* handle) {
  RimeLeversApi* api = levers_api();
  RLSUserDictList* list = (RLSUserDictList*)handle;
  if (!list || !list->initialized || !PROVIDED(api, RimeLeversApi, next_user_dict)) return NULL;
  return api->next_user_dict(&list->iterator);
}

void rls_user_dict_list_destroy(void* handle) {
  RimeLeversApi* api = levers_api();
  RLSUserDictList* list = (RLSUserDictList*)handle;
  if (!list) return;
  if (list->initialized && PROVIDED(api, RimeLeversApi, user_dict_iterator_destroy))
    api->user_dict_iterator_destroy(&list->iterator);
  free(list);
}

int rls_backup_user_dict(const char* name) {
  RimeLeversApi* api = levers_api();
  return name && PROVIDED(api, RimeLeversApi, backup_user_dict) ? api->backup_user_dict(name) : 0;
}

int rls_restore_user_dict(const char* file) {
  RimeLeversApi* api = levers_api();
  return file && PROVIDED(api, RimeLeversApi, restore_user_dict) ? api->restore_user_dict(file) : 0;
}
