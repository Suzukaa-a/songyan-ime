// Original Songyan implementation; GPL-3.0-only (see repository LICENSE).
// The schema's speller/prism owns the ambiguous phone-key spelling space.
#include <rime_api.h>
#include <rime/component.h>
#include <rime/context.h>
#include <rime/engine.h>
#include <rime/key_event.h>
#include <rime/key_table.h>
#include <rime/processor.h>
#include <rime/registry.h>
#include <rime/schema.h>
#include <rime/config.h>
#include <rime/gear/speller.h>
#include "rime_t9_keys.h"

static_assert(XK_KP_2 == songyan::kKeypad2 && XK_KP_9 == songyan::kKeypad9,
              "keypad keysyms must match the tested T9 mapping");

namespace rime {

class T9Processor : public Processor {
 public:
  explicit T9Processor(const Ticket& ticket) : Processor(ticket), speller_(ticket) {
    string alphabet;
    if (ticket.schema && ticket.schema->config() &&
        ticket.schema->config()->GetString("speller/alphabet", &alphabet)) {
      enabled_ = alphabet.find_first_of("23456789") != string::npos;
    }
  }

  ProcessResult ProcessKeyEvent(const KeyEvent& event) override {
    const int digit = songyan::PhoneDigit(
        event.keycode(), event.release() || event.ctrl() || event.alt() ||
        event.super() || event.shift(), engine_->context()->get_option("ascii_mode"));
    if (!enabled_ || !digit) return kNoop;
    return speller_.ProcessKeyEvent(KeyEvent(digit, 0));
  }

 private:
  Speller speller_;
  bool enabled_ = false;
};

}  // namespace rime

static void rime_t9_original_initialize() {
  rime::Registry::instance().Register(
      "t9_processor", new rime::Component<rime::T9Processor>);
}

static void rime_t9_original_finalize() {
  rime::Registry::instance().Unregister("t9_processor");
}

RIME_REGISTER_MODULE(t9_original)

extern "C" void rb_require_t9(void) { rime_require_module_t9_original(); }

extern "C" int rb_t9_processor_registered(void) {
  return rime::Processor::Require("t9_processor") != nullptr;
}

extern "C" int rb_t9_component_available(const char* name) {
  return name && rime::Registry::instance().Find(name) != nullptr;
}
