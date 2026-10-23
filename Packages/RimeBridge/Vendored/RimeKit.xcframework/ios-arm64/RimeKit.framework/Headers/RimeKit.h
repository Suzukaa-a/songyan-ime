#ifndef RIMEKIT_H_
#define RIMEKIT_H_

// Public umbrella for the static librime API and the reviewed iOS bridge.
// List every shipped public header so Clang does not infer accidental private
// submodules or warn differently between Debug and whole-module Release builds.
#include "rime_api.h"
#include "rime_api_deprecated.h"
#include "rime_api_stdbool.h"
#include "rime_levers_api.h"
#include "rime_bridge.h"

#endif
