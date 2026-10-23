# Engine self-test fixture — shared data directory (BSD-style test data).
#
# This directory is the `shared_data_dir` handed to librime by rime_cli.
# It is deliberately tiny and synthetic: it exists to verify the *engine
# mechanism* (deploy → input → candidates → commit/learning → sync) with a
# real pinned librime, not to be a usable input method.
#
#  Files
#    default.yaml                  schema list for fresh user dirs
#    engine_test_dict.dict.yaml    one small pinyin dictionary, shared by both
#                                  test schemas below
#    engine_test_pinyin26.schema.yaml   schema A: 26-key full pinyin
#    engine_test_mirror.schema.yaml     schema B: same dictionary & user_dict,
#                                  different speller/prism (mirrored keys)
#
#  Cross-prism claim exercised here (mirrors STARTUP §6.1):
#    A and B use the SAME dictionary (`dictionary: engine_test_dict`) and the
#    SAME user dictionary (`user_dict: engine_test_dict`), but different
#    prisms (`prism: engine_test_pinyin26` vs `engine_test_mirror`). Keys are
#    transformed by B's speller algebra into the same pinyin syllables as A
#    types directly, so both layouts must read/write the same userdb codes.
#
# The built-in schemes and their 14/18/9-key companions live under
# Resources/BuiltinPackages/Basic/ and are driven the same way by pointing
# `rime_cli --shared` at that package's shared dir.
