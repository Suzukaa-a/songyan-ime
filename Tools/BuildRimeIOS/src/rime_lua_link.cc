// Strong reference pulls the plugin's registration constructor from the static
// archive, without requiring clients to add -all_load/-force_load flags.
void rime_require_module_lua();
extern "C" void rb_require_lua(void) { rime_require_module_lua(); }
