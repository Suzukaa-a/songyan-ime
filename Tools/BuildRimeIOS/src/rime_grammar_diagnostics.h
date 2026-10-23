#ifndef RB_GRAMMAR_DIAGNOSTICS_H
#define RB_GRAMMAR_DIAGNOSTICS_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void rb_grammar_load_event(const char* path, int success, size_t entries, const char* error);
void rb_grammar_lookup_event(int matches);
int rb_grammar_diagnostics_enabled(void);
void rb_grammar_instance_attach(const void* instance, const void* config, const char* path);
void rb_grammar_instance_detach(const void* instance);
int rb_grammar_session_loaded(size_t session, const char* path);
void rb_grammar_query_event(const char* path, const char* context, const char* word, double score, int rear);
void rb_grammar_diagnostics_reset(int enabled);
char* rb_grammar_diagnostics_json(void);
#ifdef __cplusplus
}
#endif
#endif
