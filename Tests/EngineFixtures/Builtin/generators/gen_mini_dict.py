#!/usr/bin/env python3
# Generate Resources/BuiltinPackages/Basic/songyan_basic.dict.yaml deterministically.
# Kept in the repo under Tests/EngineFixtures/Builtin/generators/ so fixture docs can
# cite it. Pure-python, no deps.
import re

# (text, code_or_None_for_char_entries, weight)
# char table: rows of (char, pinyin, weight)
chars = [
    # high freq core
    ("你","ni",1000),("好","hao",1000),("我","wo",1000),("是","shi",1000),
    ("的","de",3000),("的","di",60),
    ("一","yi",3000),("不","bu",2800),("了","le",2600),("了","liao",60),
    ("在","zai",2600),("人","ren",2500),("和","he",2000),
    ("中","zhong",2000),("国","guo",1900),("这","zhe",1800),
    ("为","wei",1600),("上","shang",1500),("个","ge",1500),
    ("大","da",1500),("到","dao",1400),("说","shuo",1300),
    ("要","yao",1300),("就","jiu",1300),("去","qu",1200),
    ("能","neng",1200),("会","hui",1100),("年","nian",1100),
    ("学","xue",1000),("工","gong",1000),("开","kai",1000),
    ("小","xiao",1000),("成","cheng",900),("家","jia",900),
    ("电","dian",900),("手","shou",900),("机","ji",900),
    ("车","che",900),("路","lu",900),("天","tian",900),
    ("妈","ma",700),("爸","ba",700),("饭","fan",700),("吃","chi",700),
    ("想","xiang",800),("见","jian",800),("同","tong",800),
    ("盘","pan",600),("键","jian",600),("双","shuang",700),
    ("拼","pin",700),("音","yin",700),("验","yan",600),
    ("实","shi",1600),("试","shi",500),("空","kong",600),
    ("白","bai",600),("典","dian",500),("移","yi",500),
    ("动","dong",500),("鸟","niao",400),("鱼","yu",400),
    ("月","yue",500),("日","ri",500),("云","yun",500),
    ("雨","yu",500),("风","feng",500),("河","he",400),
    ("湖","hu",400),("海","hai",400),("山","shan",400),
    ("林","lin",400),("水","shui",500),("火","huo",400),
    ("王","wang",600),("力","li",500),("立","li",400),
    ("绿","lv",400),("女","nv",400),
    ("长","chang",500),("长","zhang",300),
    ("行","xing",500),("行","hang",200),
    ("乐","le",2700),("乐","yue",300),
    ("重","zhong",400),("重","chong",200),
    ("还","hai",500),("还","huan",200),
    ("只","zhi",400),
    ("记","ji",300),("计","ji",300),("及","ji",300),("级","ji",300),
    ("帮","bang",300),("忙","mang",300),("成","cheng",500),
    ("声","sheng",400),("冷","leng",300),("等","deng",300),
    ("半","ban",300),("看","kan",400),("分","fen",400),("很","hen",400),
    ("书","shu",500),
    # zero-initial syllables
    ("爱","ai",700),("安","an",500),("昂","ang",200),("恩","en",400),
    ("二","er",500),("啊","a",500),("哦","o",300),("鹅","e",300),
    # jue/que/xue/yue/lve/nve group (v-final written as ue in full pinyin
    # except nve/lve, per project convention identical to rime-ice)
    ("觉","jue",400),("确","que",400),("雪","xue",400),("约","yue",300),
    ("略","lve",200),("决","jue",300),("缺","que",300),("写","xie",300),
    ("血","xue",300),
    ("长","chang",500),("长","zhang",300),
    # more useful chars for phrase building
    ("们","men",1000),("呀","ya",700),("行","xing",400),("走","zou",500),
    ("度","du",500),("亮","liang",600),("快","kuai",600),("绿","lv",400),
    ("色","se",500),("孩","hai",500),("归","gui",400),("还","hai",400),
    ("银","yin",400),("雄","xiong",300),("乐","le",300),("反","fan",300),
    ("复","fu",400),("重","chong",300),("要","yao",900),
    ("声","sheng",400),("明","ming",600),("天","tian",600),("生","sheng",600),
    ("活","huo",500),("康","kang",400),("长","chang",500),("江","jiang",400),
    ("成","cheng",400),("程","cheng",950),("水","shui",400),("兴","xing",300),
    # extra single characters needed by the word list (e.g. the characters of learned phrases such as "工程车")
    ("公","gong",500),("交","jiao",500),("城","cheng",500),("程","cheng",400),
    ("平","ping",500),("西","xi",600),("健","jian",500),("乐","le",300),
    # generalized composition-display acceptance (14-key Flypy zcuggc -> 早上好)
    ("早","zao",700),
]

words = [
    ("你好","ni hao",1200),
    ("我们","wo men",1500),
    ("中国","zhong guo",2000),
    ("中国人","zhong guo ren",1500),
    ("大家","da jia",900),
    ("同学","tong xue",800),
    ("学习","xue xi",900),
    ("工作","gong zuo",900),
    ("手机","shou ji",900),
    ("电脑","dian nao",800),
    ("键盘","jian pan",700),
    ("公交车","gong jiao che",600),
    ("音乐","yin yue",800),
    ("月亮","yue liang",700),
    ("学习拼音","xue xi pin yin",500),
    ("双拼实验","shuang pin shi yan",400),
    ("白键盘","bai jian pan",300),
    # multi-pronunciation-in-word
    ("银行","yin hang",600),
    ("长大","zhang da",500),
    ("长度","chang du",500),
    ("快乐","kuai le",600),
    ("行走","xing zou",500),
    ("行列","hang lie",400),
    ("重要","zhong yao",800),
    ("重复","chong fu",500),
    ("还是","hai shi",700),
    ("归还","gui huan",300),
    # v-final / zero-initial
    ("绿色","lv se",500),
    ("女孩","nv hai",600),
    ("二月","er yue",500),
    ("爱好","ai hao",500),
    ("平安","ping an",500),
    ("西安","xi an",400),
    # ang / eng separation
    ("帮忙","bang mang",400),
    ("声音","sheng yin",500),
    ("明天","ming tian",700),
    ("生活","sheng huo",800),
    ("健康","jian kang",700),
    # zh/ch/sh + ang
    ("长城","chang cheng",700),
    ("长江","chang jiang",600),
    ("成长","cheng zhang",600),
    ("山水","shan shui",400),
    ("上车","shang che",400),
    ("早上","zao shang",650),
    ("早上好","zao shang hao",600),
]

def valid_syllable(s):
    return bool(re.fullmatch(r"[a-z]+", s)) and len(s) <= 6

# sanity checks
seen = set()
char_codes = {}
for item in chars:
    text = item[0]
    code = item[1]
    if not code.strip():
        raise SystemExit(f"empty code for {text}")
    for syl in code.split():
        if not valid_syllable(syl):
            raise SystemExit(f"bad syllable {syl!r} in {text!r} {code!r}")
    char_codes.setdefault(text, set()).add(code)

# Make sure every word's component characters have single-character entries (polyphonic readings are not used; one character maps to one syllable)
extra_chars = []
for text, code, _w in words:
    if len(text) != len(code.split()):
        raise SystemExit(f"word char/syllable mismatch: {text!r} {code!r}")
    for ch, syl in zip(text, code.split()):
        if ch not in char_codes:
            char_codes.setdefault(ch, set()).add(syl)
            extra_chars.append((ch, syl, 100))
for text, code, w in extra_chars:
    chars.append((text, code, w))

out = []
out.append("# Rime dictionary")
out.append("# encoding: utf-8")
out.append("# ---------------------------------------------------------------")
out.append("# songyan_basic - small original pinyin dictionary of the built-in schemes")
out.append("#")
out.append("# Purpose: full pinyin and Flypy double pinyin, on every layout, share one syllable dictionary")
out.append("#          and one user_dict. It is a small offline fallback, not a full lexicon.")
out.append("#")
out.append("# Notes:")
out.append("#   - Entries are a minimal, hand-written original set. None are copied or adapted from")
out.append("#     upstream data such as rime-ice, clover, rime-double-pinyin or 8105/frequency tables")
out.append("#     (their format rules were used only as a syntax reference).")
out.append("#   - u-umlaut is always written v (as in rime-ice/Flypy): nv/lv = nü/lü; ju/qu/xu/yu are")
out.append("#     written as-is (equivalent to jv/qv/xv/yv, derived by the speller).")
out.append("#   - Dictionary readings use full standard pinyin; layout-specific codes are produced by each prism's algebra.")
out.append("#   - The dictionary contains no learning or frequency-adjustment data.")
out.append("# Generator: Tests/EngineFixtures/Builtin/generators/gen_mini_dict.py")
out.append("# ---------------------------------------------------------------")
out.append("name: songyan_basic")
out.append('version: "0.1.0"')
out.append("sort: by_weight")
out.append("use_preset_vocabulary: false")
out.append("...")
out.append("")
out.append("# Single characters: <char>\\t<pinyin>\\t<weight>")
seen_texts = set()
for text, code, w in chars:
    if (text, code) in seen_texts:
        continue
    seen_texts.add((text, code))
    out.append(f"{text}\t{code}\t{w}")
out.append("")
out.append("# Words: <word>\\t<space-separated pinyin>\\t<weight>")
for text, code, w in words:
    out.append(f"{text}\t{code}\t{w}")

open("Resources/BuiltinPackages/Basic/songyan_basic.dict.yaml", "w", encoding="utf-8").write("\n".join(out) + "\n")
print("wrote dict; chars=%d words=%d total-lines=%d" % (len(set((t,c) for t,c,_ in chars)), len(words), len(out)))
