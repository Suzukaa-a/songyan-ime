#!/usr/bin/env python3
"""validate_fixtures.py - static self-check of the built-in package and its cross-layout fixtures (not engine validation).

Covers layouts, the dictionary and the playback fixtures. When the engine is not ready, a pass here only means
"the resources are self-consistent", not that engine behavior has been measured. Usage:
    python3 Tests/EngineFixtures/Builtin/validate_fixtures.py
Exit code: 0 all passed; 1 some failed.
Without pyyaml, the deep YAML parse falls back to structural checks and is explicitly marked SKIP;
run once under an interpreter with pyyaml for full YAML parse coverage.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASIC = ROOT / "Resources/BuiltinPackages/Basic"
FIX = ROOT / "Tests/EngineFixtures/Builtin"
GEN = FIX / "generators"
sys.path.insert(0, str(GEN))
from flypy_codes import flypy26_canonical, py2t9, to14  # noqa: E402

failures = []
skips = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (("  | " + detail) if detail and not cond else ""))
    if not cond:
        failures.append(name)


def note(name, detail=""):
    print("SKIP  " + name + (("  | " + detail) if detail else ""))
    skips.append(name)


try:
    import yaml  # noqa: F401

    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False


def load_yaml(path):
    if not HAVE_YAML:
        return None, "no pyyaml"
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8")), None
    except Exception as e:  # noqa: BLE001
        return None, str(e)


# ---------------- schemas ----------------
schemas = {}
schema_text = {}
for sf in sorted(BASIC.glob("*.schema.yaml")):
    schema_text[sf.name] = sf.read_text(encoding="utf-8")
    data, err = load_yaml(sf)
    if err:
        note(f"yaml deep parse {sf.name}", err)
        continue
    schemas[sf.name] = data

if not HAVE_YAML:
    note("yaml deep parse (all schemas)", "pyyaml missing, using structural checks instead")

QUANPIN, FLYPY = "songyan_quanpin", "songyan_flypy"
# Generated 14-, 18- and 9-key companions, in default.yaml order (BuiltinTemplateSchemas.adapters).
COMPANIONS = {
    (QUANPIN, "merged14"): "keyboard_47246213a538cb99d374_14",
    (QUANPIN, "merged18"): "keyboard_47246213a538cb99d374_18",
    (QUANPIN, "phone9"): "keyboard_47246213a538cb99d374_9",
    (FLYPY, "merged14"): "keyboard_3d7821f984693864ae91_14",
    (FLYPY, "merged18"): "keyboard_3d7821f984693864ae91_18",
    (FLYPY, "phone9"): "keyboard_3d7821f984693864ae91_9",
}
ENGINE_SCHEMAS = {(QUANPIN, "qwerty26"): QUANPIN, (FLYPY, "qwerty26"): FLYPY, **COMPANIONS}
EXPECTED = {sid + ".schema.yaml": (sid,) for sid in ENGINE_SCHEMAS.values()}
check("package holds exactly the two schemes and their companions",
      sorted(schema_text) == sorted(EXPECTED), str(sorted(schema_text)))
# Every key a fixture code may contain, per encodings.tsv column.
COLUMN_ALPHABETS = {
    "pinyin_26": set("abcdefghijklmnopqrstuvwxyz"),
    "flypy26": set("abcdefghijklmnopqrstuvwxyz"),
    "flypy14": set("qetuoadgjlzcbm"),
    "t9": set("23456789"),
}


def structural_get(text, key):
    """Without pyyaml, read the first uncommented key: value line."""
    pat = re.compile(r"^[ \t]*" + re.escape(key) + r":\s*(.*)$", re.M)
    m = pat.search(text)
    return m.group(1).strip() if m else None


def structural_engine(text):
    block = re.search(r"(?ms)^engine:\n(.*?)(?=^[^\s#][^:]*:|\Z)", text)
    return block.group(1) if block else ""


for fname, text in schema_text.items():
    if fname not in EXPECTED:
        continue
    exp_prism = EXPECTED[fname][0]
    if fname in schemas:
        tr = schemas[fname].get("translator", {})
        sp = schemas[fname].get("speller", {})
        sc = schemas[fname].get("schema", {})
        check(f"schema_id {fname}", sc.get("schema_id", "").endswith(fname[: -len(".schema.yaml")]), "")
        check(f"translator.dictionary songyan_basic {fname}", tr.get("dictionary") == "songyan_basic", str(tr.get("dictionary")))
        check(f"translator.prism {fname}", tr.get("prism") == exp_prism, str(tr.get("prism")))
        check(f"translator.user_dict songyan_shared {fname}", tr.get("user_dict") == "songyan_shared", str(tr.get("user_dict")))
        check(f"translator.db_class userdb {fname}", tr.get("db_class") == "userdb", str(tr.get("db_class")))
        eng = str(schemas[fname].get("engine", {}))
        check(f"no t9_processor/lua/opencc {fname}", not re.search(r"t9_processor|lua|opencc", eng, re.I), "")
    else:
        # structural fallback
        check(f"translator.dictionary songyan_basic {fname} (struct)",
              structural_get(text, "dictionary") == "songyan_basic", "")
        check(f"translator.prism {fname} (struct)", structural_get(text, "prism") == exp_prism, "")
        check(f"translator.user_dict songyan_shared {fname} (struct)",
              structural_get(text, "user_dict") == "songyan_shared", "")
        check(f"no t9_processor/lua/opencc {fname}",
              not re.search(r"t9_processor|lua|opencc", structural_engine(text), re.I), "")

prisms_ok = True
for fname in EXPECTED:
    if fname in schemas:
        got = schemas[fname]["translator"].get("prism")
    else:
        got = structural_get(schema_text.get(fname, ""), "prism")
    prisms_ok &= got == EXPECTED[fname][0]
check("one distinct explicit prism per schema", prisms_ok, "")

# ---------------- default.yaml (deployment config; a cold deploy fails without it) ----------------
EXPECTED_SCHEMAS = [QUANPIN, FLYPY] + list(COMPANIONS.values())
default_path = BASIC / "default.yaml"
check("default.yaml present", default_path.exists(), str(default_path))
if default_path.exists():
    default_text = default_path.read_text(encoding="utf-8")
    ddef, derr = load_yaml(default_path)
    if derr:
        note("default.yaml yaml deep parse", derr)
    if ddef is not None:
        sl = ddef.get("schema_list") or []
        got_sl = [s.get("schema") if isinstance(s, dict) else None for s in sl]
        check("default schema_list ids in order", got_sl == EXPECTED_SCHEMAS, str(got_sl))
        mpage = (ddef.get("menu") or {}).get("page_size")
        check("default menu.page_size >= 1", isinstance(mpage, int) and mpage >= 1, str(mpage))
        check("default config_version present", bool(ddef.get("config_version")), str(ddef.get("config_version")))
    else:
        ids = re.findall(r"^\s*-\s*schema:\s*(\S+)\s*$", default_text, re.M)
        check("default schema_list ids in order (struct)", ids == EXPECTED_SCHEMAS, str(ids))
        cv = structural_get(default_text, "config_version")
        check("default config_version present (struct)", bool(cv), str(cv))
        mpage = structural_get(default_text, "page_size")
        check("default menu.page_size >= 1 (struct)", mpage is not None and mpage.isdigit() and int(mpage) >= 1, str(mpage))
    manifest_text = (BASIC / "manifest.yaml").read_text(encoding="utf-8")
    mdata, merr = load_yaml(BASIC / "manifest.yaml")
    if mdata is not None:
        entry = (mdata.get("entrypoints") or {}).get("schemas") or []
        check("manifest entrypoints == the two schemes", entry == [QUANPIN, FLYPY], str(entry))
    else:
        note("manifest entrypoints == schema_list", merr or "no pyyaml")

# script_translator does not read enable_sentence (1.17.0: only table_translator reads it);
# the schema should not carry that key, which would mislead nine-key sentence composition.
for fname, text in schema_text.items():
    check(f"no enable_sentence key {fname}", not re.search(r"(?m)^\s*enable_sentence\s*:", text),
          "script_translator ignores this key; only table_translator reads it")

# ---------------- dictionary ----------------
raw_dict = (BASIC / "songyan_basic.dict.yaml").read_text(encoding="utf-8")
dict_rows = []
cur = None
for line in raw_dict.splitlines():
    if line.startswith("# Single characters"):
        cur = "char"
        continue
    if line.startswith("# Words"):
        cur = "word"
        continue
    if line.startswith("#") or line.startswith("---") or line.startswith("...") or not line.strip() or "\t" not in line:
        continue
    parts = line.split("\t")
    if len(parts) != 3:
        check("dict row cols==3", False, repr(line))
        continue
    dict_rows.append((cur, parts[0], parts[1]))
check("dict char+word sections", any(c == "char" for c, _, _ in dict_rows) and any(c == "word" for c, _, _ in dict_rows), "")
sylpat = re.compile(r"^[a-z]+( [a-z]+)*$")
bad = [(t, p) for c, t, p in dict_rows if not sylpat.match(p)]
check("dict codes all valid pinyin", not bad, str(bad[:3]))
dups = [(t, p) for c, t, p in dict_rows]
check("no duplicate (text,code)", len(dups) == len(set(dups)), "")
check("no literal ü in codes", all("ü" not in p for _, _, p in dict_rows), "")
n_char = sum(1 for c, _, _ in dict_rows if c == "char")
n_word = sum(1 for c, _, _ in dict_rows if c == "word")
check("dict stats: 152 single-char reading entries", n_char == 152, str(n_char))
check("dict stats: 45 word entries", n_word == 45, str(n_word))
check("dict stats: 197 rows total", len(dict_rows) == 197, str(len(dict_rows)))

# every char of every word must be present as a single-char entry
word_texts = [t for c, t, _p in dict_rows if c == "word"]
char_texts = set(t for c, t, _p in dict_rows if c == "char")
missing_chars = {}
for w in word_texts:
    for ch in w:
        if ch not in char_texts:
            missing_chars.setdefault(w, []).append(ch)
check("all word chars exist as single-char entries", not missing_chars, str(list(missing_chars.items())[:4]))

# ---------------- encodings.tsv ----------------
enc_text = (FIX / "encodings.tsv").read_text(encoding="utf-8")
lines = enc_text.splitlines()
check("encodings header", lines[0] == "text\tfull_pinyin\tflypy26\tflypy14\tt9\tflypy26_sets", "")
rows = []
for line in lines[1:]:
    parts = line.split("\t")
    if len(parts) == 6:
        rows.append(parts)
check("encodings rows == dict rows", len(rows) == len(dict_rows), f"{len(rows)} vs {len(dict_rows)}")

enc_map = {(r[0], r[1]): r for r in rows}
dict_map = {(t, p): 1 for _, t, p in dict_rows}
missing = [k for k in dict_map if k not in enc_map]
extra = [k for k in enc_map if k not in dict_map]
check("encodings ↔ dict coverage", not missing and not extra, f"missing {missing[:3]} extra {extra[:3]}")

# recompute full pinyin -> 26/14/t9 for every entry
mism = []
for (text, py), row in enc_map.items():
    syls = py.split()
    expect26 = " ".join(flypy26_canonical(s) for s in syls)
    expect14 = " ".join(to14(x) for x in expect26.split())
    expect_t9 = "".join(py2t9(s) for s in syls)
    if row[2] != expect26 or row[3] != expect14 or row[4] != expect_t9:
        mism.append((text, row[1], row[2], expect26, row[3], expect14, row[4], expect_t9))
check("encodings recompute equals flypy_codes", not mism, str(mism[:2]))

for column, alphabet in COLUMN_ALPHABETS.items():
    col = {"pinyin_26": 1, "flypy26": 2, "flypy14": 3, "t9": 4}[column]
    badchars = set()
    for row in rows:
        badchars |= set(row[col].replace(" ", "")) - alphabet
    check(f"charset ok {column}", not badchars, str(sorted(badchars)[:10]))


def speller_alphabet(schema_id):
    text = schema_text.get(schema_id + ".schema.yaml", "")
    value = structural_get(text, "alphabet") or ""
    return set(value.strip("'\""))


# ---------------- JSON fixtures ----------------
learning = json.loads((FIX / "learning_cases.json").read_text(encoding="utf-8"))
check("learning 4 cases", len(learning) == 4, "")
char_texts_l = set(t for c, t, _p in dict_rows if c == "char")
for case in learning:
    for lay in ("flypy26", "flypy14", "pinyin_26", "t9"):
        check(f"learning {case['word']} has {lay}", lay in case.get("layouts", {}), "")
    # layout codes must equal recompute from pinyin
    py = case["pinyin"]
    syls = py.split()
    exp26 = " ".join(flypy26_canonical(s) for s in syls)
    exp14 = " ".join(to14(x) for x in exp26.split())
    exp_t9 = "".join(py2t9(s) for s in syls)
    lc = case["layouts"]
    check(f"learning {case['word']} codes recompute",
          lc.get("flypy26") == exp26 and lc.get("flypy14") == exp14
          and lc.get("pinyin_26") == py and lc.get("t9") == exp_t9,
          f"{lc} vs {exp26!r} {exp14!r} {exp_t9!r}")
    missch = [ch for ch in case["word"] if ch not in char_texts_l]
    check(f"learning {case['word']} chars in dict", not missch, str(missch))
play = json.loads((FIX / "playback_cases.json").read_text(encoding="utf-8"))
check("playback == 4 layouts x rows", len(play) == 4 * len(rows), f"{len(play)}")
check("playback stats: 788 cases", len(play) == 788, str(len(play)))
play_bad = []
for case in play:
    code = case["keys"]
    key = (case.get("schema"), case.get("layout"))
    if key not in ENGINE_SCHEMAS:
        play_bad.append((key, "unknown scheme and layout"))
    elif not code or set(code) - speller_alphabet(ENGINE_SCHEMAS[key]):
        play_bad.append((key, code))
check("playback keys within alphabet", not play_bad, str(play_bad[:3]))

# ---------------- generators deterministic ----------------
before = (FIX / "encodings.tsv").read_text(encoding="utf-8")
before_l = (FIX / "learning_cases.json").read_text(encoding="utf-8")
subprocess.run([sys.executable, str(GEN / "gen_fixtures.py")], cwd=str(ROOT), check=True)
check("generator idempotent (encodings)", before == (FIX / "encodings.tsv").read_text(encoding="utf-8"), "")
check("generator idempotent (learning)", before_l == (FIX / "learning_cases.json").read_text(encoding="utf-8"), "")

print()
if skips:
    print(f"NOTE: {len(skips)} check(s) skipped due to missing pyyaml.")
if failures:
    print(f"RESULT: {len(failures)} FAILURE(S)")
    sys.exit(1)
print("RESULT: all run static checks passed (not an engine verification)")
