#!/usr/bin/env python3
# flypy_codes.py - reference implementation: a Flypy double-pinyin code projector aligned with librime Projection semantics.
#
# Purpose:
# 1) Generate the machine-readable expected codes (26/14/9 keys) for Tests/EngineFixtures/Builtin.
# 2) Cross-check real-engine prism.dump output. This tool is not an engine.
#
# Semantics (librime master 74a7467e47e1 + upstream schemas, checked rule by rule):
# - Projection::Apply runs one pass per formula, in schema order, over the spelling string.
# An xform hit rewrites and continues with later formulas; uppercase intermediate codes keep later rules from matching again
# (the classic upstream Flypy trick, used by both clover and rime-double-pinyin).
# - Derived classes (derive/abbrev) keep the original spelling and add a new one; this experimental schema only uses
# derive/^([jqxy])u$/$1v/ (mirroring clover14), so some syllables have two
# valid input codes (original + derived). We output "canonical code (set)".
# - Flypy zero-initial mapping:
# single letters a/o/e -> aa/oo/ee; two-letter syllables (ai/an/en/er/ou...) keep both pinyin keys;
# three-letter ang/eng -> first letter + the key of the final (ah/eg).
#
# Upstream references (sources and licenses):
# - Flypy xform rule sequence and key facts: rime/rime-double-pinyin master
# 01a13287cbd2 (GPL-3.0) and forfudan/rime-clover-flypy main c69e96898b6b
# (LGPL-3.0), double_pinyin_flypy / clover_flypy_14. This projector implements rule
# execution independently; the ordered rule text of the bundled schemas is adapted from those upstream files, see their headers.
# - 14-key grouping xlit qwerty...->qqeett...: clover main c69e96898b6b (experimental mapping,
# not a user-confirmed final key layout).
# ===============================================================
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]  # repo root

# ---- 14-key grouping (experimental mapping from clover; representative letter = first letter of the group)
GROUP14 = {
    'qw': 'q', 'er': 'e', 'ty': 't', 'ui': 'u', 'op': 'o',
    'as': 'a', 'df': 'd', 'gh': 'g', 'jk': 'j', 'l': 'l',
    'zx': 'z', 'cv': 'c', 'bn': 'b', 'm': 'm',
}
def rep14(letter: str) -> str:
    for g, r in GROUP14.items():
        if letter in g:
            return r
    raise ValueError(letter)

# Mirrors the xform sequence of clover14 / rime-double-pinyin flypy (order-sensitive).
# Uppercase placeholders are used in between (upstream uses fullwidth/uppercase; we mirror clover's uppercase form).
XFORM_RULES = [
    # zero-initial a/o/e doubled (including ang/eng/ong -> aang/eeng/oong)
    ('aoe_ng', r'^([aoe])(ng)?$', r'\1\1\2'),
    ('iu',     r'iu$',            'Q'),
    ('ei',     r'(.)ei$',         r'\1W'),
    ('uan',    r'uan$',           'R'),
    ('ue',     r'[uv]e$',         'T'),
    ('un',     r'un$',            'Y'),
    ('sh',     r'^sh',            'U'),
    ('ch',     r'^ch',            'I'),
    ('zh',     r'^zh',            'V'),
    ('uo',     r'uo$',            'O'),
    ('ie',     r'ie$',            'P'),
    ('ong',    r'i?ong$',         'S'),
    ('ing_uai',r'ing$|uai$',      'K'),
    ('ai',     r'(.)ai$',         r'\1D'),
    ('en',     r'(.)en$',         r'\1F'),
    ('eng',    r'(.)eng$',        r'\1G'),
    ('iang_uang', r'[iu]ang$',    'L'),
    ('ang',    r'(.)ang$',        r'\1H'),
    ('ian',    r'ian$',           'M'),
    ('an',     r'(.)an$',         r'\1J'),
    ('ou',     r'(.)ou$',         r'\1Z'),
    ('ia_ua',  r'[iu]a$',         'X'),
    ('iao',    r'iao$',           'N'),
    ('ao',     r'(.)ao$',         r'\1C'),
    ('ui',     r'ui$',            'V'),
    ('in',     r'in$',            'B'),
]
CASE_MAP = str.maketrans('QWRTYUIOPSDFGHJKLZXCVBNM', 'qwrtyuiopsdfghjklzxcvbnm')

def flypy26_spellings(syllable: str):
    """Return the set of 26-key codes for a canonical full-pinyin syllable after clover14-style algebra.
    No derive/erase is applied (the caller handles [jqxy]u->v).
    Aligned with librime semantics: xforms apply to the whole spelling string in order; a hit rewrites and continues;
    uppercase intermediate codes keep later final rules from capturing twice; lowercased at the end."""
    syllable = syllable.lower().replace('ü', 'v')
    s = syllable
    results = set()
    # derive/^([jqxy])u$/$1v/ keeps the original spelling and adds the derived one (the only derive in clover14)
    variants = [s]
    m = re.fullmatch(r'([jqxy])u', s)
    if m:
        variants.append(m.group(1) + 'v')
    for v in variants:
        t = v
        for _name, pat, rep in XFORM_RULES:
            m = re.search(pat, t)
            if m:
                t = re.sub(pat, rep, t, count=1)
        results.add(t.lower())
    return results

def flypy26_canonical(syllable: str) -> str:
    """Canonical input code (the keys a double-pinyin user actually types), used for playback cases.
    Flypy zero-initial: single letters are doubled; two-letter syllables keep full pinyin; other syllables are initial key + final key.
    Returns a single canonical code; see flypy26_spellings for the set.
    Convention: ju/qu/yu etc. use the derived codes jv/qv/yv as users type them (the original ju/qu/yu
    are still in the prism spelling set; both are valid input)."""
    s = syllable.lower().replace('ü', 'v')
    spell = flypy26_spellings(s)
    derived = re.fullmatch(r'([jqxy])v', s)
    if derived and (derived.group(1) + 'v') in spell:
        return derived.group(1) + 'v'
    cands = sorted(spell, key=lambda x: (len(x), x))
    return cands[0]

def to14(code26: str) -> str:
    return ''.join(rep14(c) for c in code26)

def py2t9(syllable: str) -> str:
    """Canonical full pinyin -> 9-key digit string (T9 phone mapping; same table as the rime-ice t9 derive).
    Mapping only; rime-ice's additional derivations are not simulated (the 9-key layout folds letters to keypad digits)."""
    s = syllable.lower().replace('ü', 'v')
    m = {'a':'2','b':'2','c':'2','d':'3','e':'3','f':'3','g':'4','h':'4','i':'4',
         'j':'5','k':'5','l':'5','m':'6','n':'6','o':'6','p':'7','q':'7','r':'7',
         's':'7','t':'8','u':'8','v':'8','w':'9','x':'9','y':'9','z':'9'}
    return ''.join(m[c] for c in s)

def word_codes(full_pinyin_code: str):
    """Space-separated canonical full pinyin -> {layout: code} and sets. full_pinyin_code uses the dictionary readings.
    26-key takes the canonical code; 14-key merges the 26-key canonical code letter by letter; 9-key uses digits per syllable."""
    syls = full_pinyin_code.split()
    c26 = [flypy26_canonical(s) for s in syls]
    c26_sets = [flypy26_spellings(s) for s in syls]
    return {
        'pinyin_26': ' '.join(c26),
        'flypy26_26': ' '.join(c26),
        'flypy14_14': ' '.join(to14(x) for x in c26),
        't9': ''.join(py2t9(s) for s in syls),
        '_26_spelling_sets': [sorted(x) for x in c26_sets],
    }

if __name__ == '__main__':
    import sys
    demo = sys.argv[1:] or ['ni','hao','zhong','guo','xue','xi','shuang','pin',
        'nv','lv','ju','qu','yu','er','a','ai','an','ang','en','eng','ou','ao',
        'yin','yue','chang','zhang','che','shi','chi','shang','chong','liang',
        'jiang','xiong','wo','men','de','le','zai','ren','he','gong','zuo',
        'jian','pan','dian','nao','xiao','jia','kong','bai','se','nv','hai',
        'ming','sheng','huo','kang','shui','lu','dian','shou','ji','neng',
        'hui','nian','cheng','fan','xiang','tong','du','kuai','gui','fan',
        'yue','liang','xue','xi','pin','shi','yan','xing','zou','lie','chang',
        'chong','fu','yao','huan','hai','shi','gui','huan','yin','hang','ke']
    for s in demo:
        sets = flypy26_spellings(s)
        can = flypy26_canonical(s)
        print(f'{s:8} 26canon={can:5} 26set={sorted(sets)} 14={to14(can):5} t9={py2t9(s)}')
