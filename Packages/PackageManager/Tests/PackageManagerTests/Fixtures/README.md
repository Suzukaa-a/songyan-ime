# Real-librime fixtures

Captured from a real librime run over the built-in dictionary (`songyan_basic`, which contains 早/早上/早上好); no probe-added words. mspy is an added fixture schema.

`songyan_quanpin.projection.json` and `songyan_flypy.projection.json` are the source projections of the two built-in schemes. `BuiltinCompanionTests` generates the bundled 14-, 18- and 9-key companions from them, so they must match the schemes' algebra and the dictionary's syllables (the test checks both).

- input `songyan_flypy` 14-key companion `zcuggc`: `preedit="zc ug gc" raw="zcuggc" highlighted="早上好" canonical="zao shang hao"`
- input `songyan_flypy` `zcuhhc`: `preedit="zc uh hc" raw="zcuhhc" highlighted="早上好" canonical="zao shang hao"`
- input `songyan_quanpin` `zaoshanghao`: `preedit="zao shang hao" raw="zaoshanghao" highlighted="早上好" canonical="zao shang hao"`
