# Frontend shared Rime configuration

Source: https://github.com/rime/rime-prelude
Pin: 082425ea0684bca36474415d4a0e8db9b016487e (2026-05-09)
License: GNU LGPL version 3, upstream LICENSE and AUTHORS included; GPL v3 in COPYING.
Vendored 2026-09-09. The four YAML files in this bundle are unmodified upstream bytes.

SHA-256:
- default.yaml: 0628ada16651d56c4cdfcb8e45ddba23d4d585cc8be0580a62c4e077c0bcc141
- key_bindings.yaml: ee2476598b4cae89068b823868196eb07b5f72007a600814fe5804b39008b3ed
- punctuation.yaml: d6f89592149098f0a2d0ed3e5c83f49adb6226cdf1d967b0bc0d293f4e5c496a
- symbols.yaml: 6d08969525bd66c67abf1791c99928079356bd0e673386c49c1959d2a52fdbba

The frontend supplies these small standard configurations, not optional schema packages,
dictionaries, OpenCC data or models. Squirrel similarly ships plum output as shared data:
https://github.com/rime/squirrel/blob/master/Makefile (PLUM_DATA / copy-plum-data).

Installation adaptation: when default.yaml is absent, only its schema_list is replaced
with the installed root schemas. All other sections retain upstream semantics. Existing
files always win; *.custom.yaml is left for librime to apply. Users may replace these
readable YAML sources in their imported package. No preset bytes enter sourceFiles or
the recipe install_files matching pool. Effective resources, including added presets,
are budgeted, hashed and deployed in the existing installation transaction.
