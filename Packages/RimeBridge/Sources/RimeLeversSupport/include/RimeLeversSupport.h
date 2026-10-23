#ifndef RIME_LEVERS_SUPPORT_H
#define RIME_LEVERS_SUPPORT_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

// All booleans crossing this boundary are explicit int, never flavored Bool.
int rls_available(void);
int rls_prepare_installation(void);
int rls_user_dict_list_create(void** list);
const char* rls_user_dict_list_next(void* list);
void rls_user_dict_list_destroy(void* list);
int rls_backup_user_dict(const char* name);
int rls_restore_user_dict(const char* snapshot_file);

#ifdef __cplusplus
}
#endif
#endif
