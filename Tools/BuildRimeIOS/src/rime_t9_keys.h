// Original Songyan T9 key normalization; GPL-3.0-only.
#ifndef SONGYAN_T9_KEYS_H_
#define SONGYAN_T9_KEYS_H_

namespace songyan {

// X11 KeySym keypad 2..9 values; verified against librime's key_table.h at build.
constexpr int kKeypad2 = 0xffb2;
constexpr int kKeypad9 = 0xffb9;

inline int PhoneDigit(int keycode, bool modified, bool ascii_mode) {
  if (modified || ascii_mode) return 0;
  if (keycode >= '2' && keycode <= '9') return keycode;
  if (keycode >= kKeypad2 && keycode <= kKeypad9)
    return '2' + keycode - kKeypad2;
  return 0;
}

}  // namespace songyan
#endif
