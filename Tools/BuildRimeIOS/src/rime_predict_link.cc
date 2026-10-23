// Static link anchor for the pinned upstream librime-predict module.
// rb_require_predict pulls predict_module.cc.o (RIME_REGISTER_MODULE(predict))
// into the final binary; the probe reports the live registry, never a constant.
#include <rime/component.h>
#include <rime/registry.h>

void rime_require_module_predict();

extern "C" void rb_require_predict(void) { rime_require_module_predict(); }

extern "C" int rb_predict_components_registered(void) {
  auto& registry = rime::Registry::instance();
  return registry.Find("predictor") != nullptr &&
         registry.Find("predict_translator") != nullptr;
}
