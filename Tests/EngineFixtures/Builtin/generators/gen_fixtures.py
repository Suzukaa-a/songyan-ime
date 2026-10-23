#!/usr/bin/env python3
# gen_fixtures.py - generate cross-layout encoding / playback / learning acceptance fixtures from songyan_basic.dict.yaml.
#
# Outputs:
# Tests/EngineFixtures/Builtin/encodings.tsv   machine-readable codes of every (word, canonical pinyin) in the four layouts
# Tests/EngineFixtures/Builtin/playback_cases.json   playback cases (key sequence + expected text)
# Tests/EngineFixtures/Builtin/learning_cases.json   cross-layout word-creation / shared-learning acceptance cases
#
# Code projection implementation: Tests/EngineFixtures/Builtin/generators/flypy_codes.py.
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from flypy_codes import flypy26_canonical, flypy26_spellings, py2t9, to14

ROOT = Path(__file__).resolve().parents[4]  # repo root
DICT = ROOT / "Resources/BuiltinPackages/Basic/songyan_basic.dict.yaml"
OUT = ROOT / "Tests/EngineFixtures/Builtin"

def parse_dict():
    chars, words = [], []
    cur = None
    for line in DICT.read_text(encoding="utf-8").splitlines():
        if line.startswith("# Single characters"):
            cur = "char"
            continue
        if line.startswith("# Words"):
            cur = "word"
            continue
        if line.startswith("#") or line.startswith("---") or line.startswith("...") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        text, code = parts[0], parts[1]
        if cur == "char":
            chars.append((text, code))
        elif cur == "word":
            words.append((text, code))
    return chars, words

def norm_py(code):
    # canonical pinyin code string -> layout codes
    return code

def layout_codes(code):
    syls = code.split()
    c26 = [flypy26_canonical(s) for s in syls]
    c14 = [to14(x) for x in c26]
    return {
        "text_syllables": code,
        "pinyin_26": " ".join(syls),
        "flypy26": " ".join(c26),
        "flypy14": " ".join(c14),
        "t9": "".join(py2t9(s) for s in syls),
        "flypy26_sets": [sorted(flypy26_spellings(s)) for s in syls],
    }

def main():
    chars, words = parse_dict()
    rows = []
    for text, code in words + chars:
        rows.append({"text": text, **layout_codes(code)})
    (OUT / "encodings.tsv").write_text(
        "text\tfull_pinyin\tflypy26\tflypy14\tt9\tflypy26_sets\n" +
        "\n".join(f"{r['text']}\t{r['text_syllables']}\t{r['flypy26']}\t"
                  f"{r['flypy14']}\t{r['t9']}\t"
                  f"{json.dumps(r['flypy26_sets'], ensure_ascii=False)}"
                  for r in rows) + "\n", encoding="utf-8")
    # playback cases: key sequence and committable text for every (layout, dictionary word).
    # The engine looks up the candidate holding `text` in the real menu and commits it, paging if it is not on the first screen; across words, use the delimiter.
    # The assertion's minimum bar is "the target text can be found and committed under this layout"; candidate position is left for the engine to record.
    playback = []
    for r in rows:
        for schema, layout, keycol in [("songyan_quanpin", "qwerty26", "pinyin_26"),
                                       ("songyan_flypy", "qwerty26", "flypy26"),
                                       ("songyan_flypy", "merged14", "flypy14"),
                                       ("songyan_quanpin", "phone9", "t9")]:
            code = r[keycol]
            if not code:
                continue
            playback.append({
                "schema": schema, "layout": layout, "text": r["text"],
                "keys": code.replace(" ", ""),   # continuous input without delimiters (ambiguity is left to the engine)
                "keys_with_delim": code.replace(" ", "'"),  # optional: use ' to split syllables explicitly
                "expect_text": r["text"],
            })
    (OUT / "playback_cases.json").write_text(
        json.dumps(playback, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    # playback cases: per-character/word key sequences; the choice is decided by the engine from the layout's real candidate pages
    playback = []
    # learning cases use self-made words with specified readings; the dictionary carries their
    # characters but never the full forms, so only user learning can produce them
    learning = [
        {"word": "工程车", "pinyin": "gong cheng che",
         "layouts": {"flypy26": "gs ig ie", "flypy14": "ga ug ue", "pinyin_26": "gong cheng che", "t9": "466424364243"},
         "expect": {"first_in_baseline": False}},
        {"word": "键盘拼音实验", "pinyin": "jian pan pin yin shi yan",
         "layouts": {"flypy26": "jm pj pb yb ui yj", "flypy14": "jm oj ob tb uu tj", "pinyin_26": "jian pan pin yin shi yan", "t9": "5426726746946744926"},
         "expect": {"first_in_baseline": False}},
        {"word": "学拼音车", "pinyin": "xue pin yin che",
         "layouts": {"flypy26": "xt pb yb ie", "flypy14": "zt ob tb ue", "pinyin_26": "xue pin yin che", "t9": "983746946243"},
         "expect": {"first_in_baseline": False}},
        {"word": "乐行车", "pinyin": "le xing che",
         "layouts": {"flypy26": "le xk ie", "flypy14": "le zj ue", "pinyin_26": "le xing che", "t9": "539464243"},
         "expect": {"first_in_baseline": False}},
    ]
    (OUT / "learning_cases.json").write_text(
        json.dumps(learning, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("wrote encodings.tsv (%d rows) and learning_cases.json (%d cases)" % (len(rows), len(learning)))

if __name__ == "__main__":
    main()
