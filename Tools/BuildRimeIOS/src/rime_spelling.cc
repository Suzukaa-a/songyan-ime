// ---------------------------------------------------------------------------
// rime_spelling.cc — trusted candidate spelling for reduced layouts.
//
// The keyboard front end shows the highlighted candidate's *own* spelling
// (e.g. 你 → "ni") instead of a merged/numeric raw code ("bu", "64"). The value
// must be trustworthy, so this bridge derives it from the engine and refuses to
// guess. The front end decides *when* to ask (its actual 14/9 layout), so this
// unit contains no alphabet heuristic.
//
// Provenance. The only spelling the engine guarantees is ScriptTranslator's:
// it decodes a candidate's syllable code through its own primary Table/Prism
// (Dictionary::Decode). To decode safely we must be sure the candidate was
// produced by that script translator — otherwise a foreign translator's integer
// codes would be silently reinterpreted. Native librime emits disjoint candidate
// types:
//   * script_translator: phrase | user_phrase | completion | sentence
//   * table_translator : table  | user_table  | completion | sentence
//     (table_translator.cc:83-86 and the Sentence branch)
// So `phrase` and `user_phrase` are produced **only** by script_translator.
// This bridge therefore accepts only those two types and rejects completion /
// sentence / table / user_table (which would be the path for a table Sentence,
// an English table, a custom phrase, a reverse lookup or any other translator).
// It additionally requires exactly one script translator, that translator's
// Language (user_dict name, else dictionary language component — exactly the
// rule in Memory), and that for a static `phrase` the candidate's **full** code
// and text exist in that translator's own dictionary bucket (strict full-code
// comparison, so >3-syllable tail buckets cannot be mistaken).
//
// Range. The engine's highlighted preedit span must provably contain exactly the
// candidate's display: non-empty candidate preedit, tab/prompt reconstructed as
// Composition::GetPreedit does, and preedit[sel_start, sel_end) byte-equal to it.
// Empty/partial candidate preedit, prompts/cursor inside the span, or a
// text/range-changing Shadow fall back. The front end then replaces exactly that
// span, preserving confirmed text, punctuation, trailing code and the caret.
//
// Anything unproven returns NULL; the front end keeps the raw engine preedit.
// ---------------------------------------------------------------------------
#include "rime_bridge.h"
#include "rime_source_identity.h"

#include <atomic>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include <functional>
#include <set>
#include <mutex>
#include <sys/stat.h>

#include <rime/candidate.h>
#include <rime/component.h>
#include <rime/config.h>
#include <rime/context.h>
#include <rime/algo/syllabifier.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/table.h>
#include <rime/gear/translator_commons.h>
#include <rime/language.h>
#include <rime/schema.h>
#include <rime/service.h>
#include <rime/ticket.h>

namespace {

std::atomic<unsigned long long> g_decode_count{0};

// Bounded to a single (schema, translator-namespace) dictionary. Replaced on the
// next qualifying request or on reset; never grows with the number of schemas
// selected. The pooled Prism/Table objects are shared with the live translator.
struct DictionaryCache {
  std::string schema_id;
  std::string name_space;
  rime::Dictionary* dictionary = nullptr;
};
DictionaryCache& dictionary_cache() {
  static DictionaryCache* cache = new DictionaryCache();
  return *cache;
}

void drop_cached_dictionary() {
  auto& cache = dictionary_cache();
  delete cache.dictionary;
  cache.dictionary = nullptr;
  cache.schema_id.clear();
  cache.name_space.clear();
}

// single_producer / delimiter_for are shared verbatim with the
// display primitive through rime_source_identity.h (one algorithm, no drift).
using rime_identity::delimiter_for;
using rime_identity::single_producer_namespaces;

// The Language script_translator/Memory assigns for `name_space`.
std::string translator_language(rime::Config* config,
                                const std::string& name_space) {
  bool enable_user_dict = true;
  config->GetBool(name_space + "/enable_user_dict", &enable_user_dict);
  std::string name;
  if (enable_user_dict && config->GetString(name_space + "/user_dict", &name) &&
      !name.empty())
    return name;
  if (config->GetString(name_space + "/dictionary", &name) && !name.empty())
    return rime::Language::get_language_component(name);
  return "";
}

rime::Dictionary* dictionary_for(rime::Schema* schema,
                                 const std::string& name_space) {
  auto& cache = dictionary_cache();
  if (cache.dictionary && cache.schema_id == schema->schema_id() &&
      cache.name_space == name_space)
    return cache.dictionary;
  drop_cached_dictionary();
  auto* component = rime::Dictionary::Require("dictionary");
  if (!component) return nullptr;
  rime::Dictionary* dictionary =
      component->Create(rime::Ticket(schema, name_space));
  cache.schema_id = schema->schema_id();
  cache.name_space = name_space;
  cache.dictionary = dictionary;
  return dictionary;
}

// True when `text` exists in `dictionary` under exactly `code` (full code, so a
// >3-syllable tail bucket cannot be mistaken for a shorter spelling).
bool table_has_exact_entry(rime::Dictionary* dictionary, const rime::Code& code,
                           const std::string& text) {
  if (code.empty()) return false;
  for (const auto& table : dictionary->tables()) {
    if (!table || !table->IsOpen()) continue;
    rime::TableAccessor accessor = table->QueryPhrases(code);
    while (!accessor.exhausted()) {
      const rime::table::Entry* entry = accessor.entry();
      if (entry && accessor.code() == code && table->GetEntryText(*entry) == text)
        return true;
      accessor.Next();
    }
  }
  return false;
}

// The bytes Composition::GetPreedit displays inside the highlighted span for a
// present, non-empty candidate preedit. With a '\t' the engine puts everything
// before the tab inside the selection (sel_end = sel_start + tab) and any text
// after it stays outside as a prompt.
std::string selected_display_bytes(const std::string& candidate_preedit) {
  const size_t tab = candidate_preedit.find('\t');
  if (tab == std::string::npos) return candidate_preedit;
  return candidate_preedit.substr(0, tab);
}

std::string json_escape(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 2);
  for (unsigned char c : value) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          out += buffer;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out;
}

// Every existing gate in one place, so the joined spelling and the per-token
// syllable array can never disagree about provenance/range/dictionary. Runs on
// the caller's serialized engine thread. On success `syllables` holds the
// canonical decoded tokens and `delimiter` the display separator the engine
// would use (source delimiter first character).
bool decode_highlighted_syllables(rime::Session* session,
                                  std::vector<std::string>* syllables,
                                  std::string* delimiter,
                                  int candidate_index = -1,
                                  rime::an<rime::Candidate> supplied = nullptr) {
  if (!session || !syllables || !delimiter) return false;
  rime::Context* context = session->context();
  rime::Schema* schema = session->schema();
  if (!context || !schema || !context->IsComposing()) return false;
  rime::Config* config = schema->config();
  if (!config) return false;

  // Provenance: exactly one script translator, otherwise the source is unknown.
  const std::vector<std::string> namespaces =
      single_producer_namespaces(config);
  if (namespaces.size() != 1) return false;
  const std::string name_space = namespaces.front();

  const auto& composition = context->composition();
  if (composition.empty()) return false;
  const rime::Segment& segment = composition.back();
  auto selected = supplied ? supplied : (candidate_index < 0 ? segment.GetSelectedCandidate()
                                     : segment.GetCandidateAt(candidate_index));
  if (!selected) return false;
  auto phrase = rime::As<rime::Phrase>(
      rime::Candidate::GetGenuineCandidate(selected));
  if (!phrase) return false;

  // Only script-exclusive candidate types: `phrase`/`user_phrase`. Everything a
  // table translator can emit (table/user_table/completion/sentence) is refused,
  // so a foreign translator's integer codes can never be decoded as this one's.
  const std::string type = phrase->type();
  const bool is_static_phrase = type == "phrase";
  const bool is_user_phrase = type == "user_phrase";
  if (!is_static_phrase && !is_user_phrase) return false;

  // A Shadow/filter that changed text, preedit or the covered range is no longer
  // provably this Phrase.
  if (selected->text() != phrase->text()) return false;
  if (selected->preedit() != phrase->preedit()) return false;
  if (selected->start() != phrase->start() || selected->end() != phrase->end())
    return false;

  // Browsing decodes the candidate's own code, not the highlighted display span.
  // It must still belong to the active segment and must not change input/highlight.
  if (candidate_index >= 0 && (selected->start() != segment.start ||
      selected->end() > segment.end || selected->end() <= selected->start()))
    return false;
  // Range proof is additionally required when replacing highlighted display text.
  if (candidate_index < 0) {
  const std::string candidate_preedit = selected->preedit();
  if (candidate_preedit.empty()) return false;
  const std::string displayed = selected_display_bytes(candidate_preedit);
  if (displayed.empty()) return false;
  const rime::Preedit preedit = context->GetPreedit();
  if (preedit.sel_end < preedit.sel_start ||
      preedit.sel_end > preedit.text.length())
    return false;
  if (preedit.text.substr(preedit.sel_start,
                          preedit.sel_end - preedit.sel_start) != displayed)
    return false;
  }

  const std::string language = translator_language(config, name_space);
  if (language.empty() || !phrase->language() ||
      phrase->language()->name() != language)
    return false;

  rime::Dictionary* dictionary = dictionary_for(schema, name_space);
  if (!dictionary || !dictionary->loaded()) return false;
  const rime::Code code = phrase->code();
  if (code.empty()) return false;
  // A static phrase must exist in this translator's own dictionary under this
  // exact full code (rejects foreign codes and >3-code bucket confusion).
  if (is_static_phrase &&
      !table_has_exact_entry(dictionary, code, phrase->text()))
    return false;

  if (!dictionary->Decode(code, syllables) || syllables->empty()) return false;
  g_decode_count.fetch_add(1, std::memory_order_relaxed);
  *delimiter = delimiter_for(config, name_space);
  return true;
}

// ---- ambiguity enumeration + versioned rewrite capabilities -----------------
//
// The enumeration is SCHEMA-AGNOSTIC. It reports exactly what the active
// schema's own principal-producer Prism/Syllabifier prove for the current `abc`
// segment: pinyin, double-pinyin, shape codes (Wubi/Cangjie table sources),
// Bopomofo, dialect or any custom principal producer are handled identically.
// There is no alphabet/name heuristic and no "looks like pinyin" test anywhere.

// Enumerates the full-span spellings of `raw` through the active schema's own
// PRINCIPAL producer (a unique default script_translator or table_translator,
// mirroring `rime_identity::single_producer`) and its Prism/Syllabifier. This is
// deliberately NOT the script-exclusive provenance/type gate that
// decode_highlighted_syllables applies to *display* decoding.
//
// The typed form keeps, per interpreted token, the BEST (least ambiguous) live
// spelling type that proved it (`kNormalSpelling` beats `kAbbreviation`). Fuzzy
// and completion edges are not "interpretations of what the user typed" in the
// sense this contract needs, so they are excluded; `is_correction` edges are
// excluded as before. Returns false when the primary producer cannot be proven
// (no schema/config, no unique primary, dictionary or prism unavailable); true
// with a possibly-empty `out` otherwise.
bool enumerate_segment_interpretations(rime::Session* session,
                                       const std::string& raw,
                                       std::map<std::string, rime::SpellingType>* out) {
  if (!session || !out || raw.empty()) return false;
  rime::Schema* schema = session->schema();
  if (!schema) return false;
  rime::Config* config = schema->config();
  if (!config) return false;
  const std::vector<std::string> namespaces =
      single_producer_namespaces(config);
  if (namespaces.size() != 1) return false;
  const std::string name_space = namespaces.front();
  rime::Dictionary* dictionary = dictionary_for(schema, name_space);
  if (!dictionary || !dictionary->loaded()) return false;
  rime::Prism* prism = dictionary->prism().get();
  if (!prism) return false;

  rime::Syllabifier syllabifier(delimiter_for(config, name_space), false, false);
  rime::SyllableGraph graph;
  syllabifier.BuildSyllableGraph(raw, *prism, &graph);

  out->clear();
  const auto edges_start = graph.edges.find(0);
  if (edges_start != graph.edges.end()) {
    const auto edges_end = edges_start->second.find(raw.size());
    if (edges_end != edges_start->second.end()) {
      for (const auto& item : edges_end->second) {
        const rime::EdgeProperties& props = item.second;
        if (props.is_correction) continue;
        if (props.type != rime::kNormalSpelling &&
            props.type != rime::kAbbreviation)
          continue;
        std::vector<std::string> decoded;
        rime::Code code;
        code.push_back(item.first);
        if (!dictionary->Decode(code, &decoded) || decoded.empty()) continue;
        auto found = out->find(decoded.front());
        if (found == out->end()) {
          out->insert({decoded.front(), props.type});
        } else if (props.type < found->second) {
          found->second = props.type;  // keep the best (smallest) type
        }
      }
    }
  }
  return true;
}

// The legacy/report view: only plain (normal) interpretations, as a set. It is
// defined in terms of the typed enumeration so the two can never drift.
bool enumerate_segment_spellings(rime::Session* session,
                                 const std::string& raw,
                                 std::set<std::string>* out) {
  if (!out) return false;
  std::map<std::string, rime::SpellingType> interpreted;
  if (!enumerate_segment_interpretations(session, raw, &interpreted))
    return false;
  out->clear();
  for (const auto& entry : interpreted) {
    if (entry.second == rime::kNormalSpelling) out->insert(entry.first);
  }
  return true;
}

// ---- bounded letter-class PREFIX options (v4) ------------------------------
//
// The T9 / compact-keypad question: the digit `2` physically means a/b/c, so a
// long press should be able to say "the first letter is b" and have that choice
// actually constrain the encoding. Everything here is derived from the LIVE
// prism and the live segment graph; nothing is read from a keycap label, a fixed
// "abc" constant, a candidate comment or a dictionary word.
//
// WHY THIS USES THE PRISM'S OWN KEY SEMANTICS, NOT THE SYLLABLE GRAPH: the
// production syllable graph deliberately DISQUALIFIES abbreviation edges as soon
// as a normal path reaches the same vertex (syllabifier.cc "remove disqualified
// syllables"), so for the digit `2` the graph exposes only the normal token `a`
// and hides the b/c-initial abbreviations that the same prism key does prove.
// The narrowing relation below is therefore defined over what an EXACT code names
// in the live prism (`Prism::GetValue` + `QuerySpelling`, the same relation
// `Dictionary::LookupWords(predictive=false)` uses): the set of tokens that code
// can stand for, with the best (least ambiguous) spelling type per token.
//
// A candidate key is one of the DECLARED single-character keys of the verified
// capability (`prefix_keys`; already structurally bounded and ASCII-only). It
// becomes an option only when, recomputed live at this moment:
//   * every character is in the schema's own `speller/alphabet` (so the rewritten
//     code re-syllabifies);
//   * it is not the segment's own raw code (a no-op, never offered);
//   * its interpretation set (normal + abbreviation) is non-empty; and
//   * EVERY interpretation of the key is also an interpretation of the raw
//     segment, so replacing the segment with the key can only NARROW the live
//     reading — never introduce an interpretation the keypad could not mean.
//
// The last rule is what makes an abbreviation edge safe to include: with the
// companion's own `abbrev/^([a-z]).+$/$1/` layer, key `b` names the b-initial
// syllables, exactly a subset of the `2` class. The label distinguishes an exact
// single-token key (`exact`) from an abbreviation class (`initial`), so a front
// end never has to guess the semantics.

enum class PrefixSemantics { kExact, kInitial, kMixed };

const char* prefix_semantics_name(PrefixSemantics semantics) {
  switch (semantics) {
    case PrefixSemantics::kExact: return "exact";
    case PrefixSemantics::kInitial: return "initial";
    case PrefixSemantics::kMixed: return "mixed";
  }
  return "mixed";
}

struct PrefixOption {
  std::string key;
  PrefixSemantics semantics = PrefixSemantics::kExact;
};

// The tokens an EXACT code names in the live prism, with the best (least
// ambiguous) spelling type per token. Correction entries are excluded. Returns
// false when the primary producer / prism cannot be proven.
bool prism_key_interpretations(rime::Session* session, const std::string& code,
                               std::map<std::string, rime::SpellingType>* out) {
  if (!session || !out || code.empty()) return false;
  rime::Schema* schema = session->schema();
  if (!schema) return false;
  rime::Config* config = schema->config();
  if (!config) return false;
  const std::vector<std::string> namespaces = single_producer_namespaces(config);
  if (namespaces.size() != 1) return false;
  rime::Dictionary* dictionary = dictionary_for(schema, namespaces.front());
  if (!dictionary || !dictionary->loaded()) return false;
  rime::Prism* prism = dictionary->prism().get();
  if (!prism) return false;

  out->clear();
  int spelling_id = 0;
  if (!prism->GetValue(code, &spelling_id)) return true;  // no such key -> empty
  rime::SpellingAccessor accessor = prism->QuerySpelling(spelling_id);
  while (!accessor.exhausted()) {
    const rime::SpellingProperties props = accessor.properties();
    const rime::SyllableId syllable_id = accessor.syllable_id();
    accessor.Next();
    if (props.is_correction) continue;
    if (props.type != rime::kNormalSpelling && props.type != rime::kAbbreviation)
      continue;
    std::vector<std::string> decoded;
    rime::Code code_ids;
    code_ids.push_back(syllable_id);
    if (!dictionary->Decode(code_ids, &decoded) || decoded.empty()) continue;
    auto found = out->find(decoded.front());
    if (found == out->end()) {
      out->insert({decoded.front(), props.type});
    } else if (props.type < found->second) {
      found->second = props.type;
    }
  }
  return true;
}

// The bounded, live-proven narrowing options for `raw` (see the block comment).
// `out` is sorted by key. Returns false when the enumeration itself cannot be
// proven (no primary producer / prism); true with a possibly-empty `out`.
bool enumerate_prefix_options(rime::Session* session,
                              const std::vector<std::string>& declared_keys,
                              const std::string& raw,
                              std::vector<PrefixOption>* out) {
  if (!session || !out || raw.empty()) return false;
  rime::Schema* schema = session->schema();
  if (!schema) return false;
  rime::Config* config = schema->config();
  if (!config) return false;

  std::string alphabet;
  if (!config->GetString("speller/alphabet", &alphabet)) return false;

  std::map<std::string, rime::SpellingType> raw_interpretations;
  if (!prism_key_interpretations(session, raw, &raw_interpretations))
    return false;

  out->clear();
  for (const std::string& key : declared_keys) {
    if (!rime_identity::is_prefix_key_token(key)) continue;
    if (key == raw) continue;  // no-op, never an option
    bool typeable = true;
    for (char c : key) {
      if (alphabet.find(c) == std::string::npos) { typeable = false; break; }
    }
    if (!typeable) continue;
    std::map<std::string, rime::SpellingType> key_interpretations;
    if (!prism_key_interpretations(session, key, &key_interpretations)) continue;
    if (key_interpretations.empty()) continue;
    // Subset proof: everything this key can mean must already be reachable from
    // the live segment, otherwise it is not a narrowing of what was typed.
    bool subset = true;
    bool any_abbreviation = false;
    bool any_normal = false;
    for (const auto& entry : key_interpretations) {
      if (raw_interpretations.find(entry.first) == raw_interpretations.end()) {
        subset = false;
        break;
      }
      if (entry.second == rime::kAbbreviation) any_abbreviation = true;
      if (entry.second == rime::kNormalSpelling) any_normal = true;
    }
    if (!subset) continue;
    PrefixSemantics semantics = PrefixSemantics::kMixed;
    if (key_interpretations.size() == 1 && key_interpretations.begin()->first == key &&
        !any_abbreviation) {
      semantics = PrefixSemantics::kExact;
    } else if (any_abbreviation && !any_normal) {
      semantics = PrefixSemantics::kInitial;
    }
    out->push_back({key, semantics});
  }
  std::sort(out->begin(), out->end(),
            [](const PrefixOption& a, const PrefixOption& b) { return a.key < b.key; });
  return true;
}

// The live tail `abc` segment plus its raw byte span inside `input`.
bool live_tail_abc_span(rime::Context* context, const std::string& input,
                        int segment_start, int segment_end,
                        std::string* raw) {
  if (!context || segment_start < 0 || segment_end <= segment_start) return false;
  const auto& composition = context->composition();
  if (composition.empty()) return false;
  const rime::Segment& segment = composition.back();
  if (!segment.HasTag("abc")) return false;
  if (static_cast<int>(segment.start) != segment_start ||
      static_cast<int>(segment.end) != segment_end)
    return false;
  if (segment_end > static_cast<int>(input.size())) return false;
  *raw = input.substr(static_cast<size_t>(segment_start),
                      static_cast<size_t>(segment_end - segment_start));
  return !raw->empty();
}

// Serializes the ambiguity report. `spellings` and `lockable` are both already
// deduplicated + sorted (std::set). The cap is applied to `spellings` first, and
// `lockable` is emitted ONLY from the spellings actually written out, so the wire
// invariant `lockable ⊆ spellings` holds even when the list is truncated. A
// truncated list sets *complete_out = false; the original total is never guessed.
std::string build_ambiguity_json(const std::string& input, size_t start, size_t end,
                                 const std::string& mode_name,
                                 const std::set<std::string>& spellings,
                                 const std::set<std::string>& lockable, int cap,
                                 bool* complete_out) {
  bool complete = true;
  std::set<std::string> emitted;
  size_t emitted_count = 0;
  std::string json = "{\"revision_input\":\"" + json_escape(input) +
                     "\",\"segment\":{\"start\":" +
                     std::to_string(static_cast<unsigned long long>(start)) +
                     ",\"end\":" +
                     std::to_string(static_cast<unsigned long long>(end)) +
                     "},\"lock_mode\":\"" + json_escape(mode_name) +
                     "\",\"spellings\":[";
  for (const auto& spelling : spellings) {
    if (emitted_count >= static_cast<size_t>(cap)) {
      complete = false;
      break;
    }
    if (emitted_count) json += ",";
    json += "\"" + json_escape(spelling) + "\"";
    emitted.insert(spelling);
    ++emitted_count;
  }
  json += "],\"lockable\":[";
  size_t lockable_count = 0;
  for (const auto& spelling : lockable) {
    if (emitted.find(spelling) == emitted.end()) continue;  // never beyond emitted
    if (lockable_count) json += ",";
    json += "\"" + json_escape(spelling) + "\"";
    ++lockable_count;
  }
  json += "],\"complete\":";
  json += complete ? "true" : "false";
  json += "}";
  if (complete_out) *complete_out = complete;
  return json;
}

std::string replace_span(const std::string& input, int start, int end,
                         const std::string& replacement) {
  return input.substr(0, static_cast<size_t>(start)) + replacement +
         input.substr(static_cast<size_t>(end));
}

// The exact-token options of `raw`: an interpretation token that is ALSO a live
// prism key interpreting to exactly itself. This keeps the v3-style direct lock
// for multi-key codes under the prefix mode (e.g. `22` -> `ba`), where no
// single-character narrowing exists. Only tokens that were actually emitted are
// probed, so the work stays bounded by the report's own cap; each probe is one
// live enumeration of a token-length code.
bool enumerate_exact_token_options(rime::Session* session,
                                   const std::vector<std::string>& spellings,
                                   std::set<std::string>* out) {
  if (!session || !out) return false;
  out->clear();
  for (const std::string& token : spellings) {
    if (token.empty() || token.size() > 64) continue;
    std::map<std::string, rime::SpellingType> interpretations;
    if (!prism_key_interpretations(session, token, &interpretations))
      return false;
    if (interpretations.size() != 1) continue;
    const auto& only = *interpretations.begin();
    if (only.first == token && only.second == rime::kNormalSpelling)
      out->insert(token);
  }
  return true;
}

// The v4 wire object. `spellings` are the segment's plain interpretations (the
// same meaning as the legacy field, already capped by the caller), `lockable`
// the options the engine will accept, `prefix_options` the bounded narrowing keys
// (always emitted in full — they are the front end's letter-class choices and
// must never be lost to the spellings cap), and `option_semantics` the per-lock
// semantic label. Invariant: lockable ⊆ spellings ∪ prefix_options.
std::string build_prefix_ambiguity_json(
    const std::string& input, size_t start, size_t end,
    const std::vector<std::string>& spellings,
    const std::vector<std::string>& lockable,
    const std::vector<std::string>& prefix_options,
    const std::vector<std::pair<std::string, std::string>>& semantics,
    bool complete) {
  std::string json = "{\"revision_input\":\"" + json_escape(input) +
                     "\",\"segment\":{\"start\":" +
                     std::to_string(static_cast<unsigned long long>(start)) +
                     ",\"end\":" +
                     std::to_string(static_cast<unsigned long long>(end)) +
                     "},\"lock_mode\":\"prefix_token\",\"spellings\":[";
  for (size_t i = 0; i < spellings.size(); ++i) {
    if (i) json += ",";
    json += "\"" + json_escape(spellings[i]) + "\"";
  }
  json += "],\"prefix_options\":[";
  for (size_t i = 0; i < prefix_options.size(); ++i) {
    if (i) json += ",";
    json += "\"" + json_escape(prefix_options[i]) + "\"";
  }
  json += "],\"lockable\":[";
  for (size_t i = 0; i < lockable.size(); ++i) {
    if (i) json += ",";
    json += "\"" + json_escape(lockable[i]) + "\"";
  }
  json += "],\"option_semantics\":{";
  for (size_t i = 0; i < semantics.size(); ++i) {
    if (i) json += ",";
    json += "\"" + json_escape(semantics[i].first) + "\":\"" +
            json_escape(semantics[i].second) + "\"";
  }
  json += "},\"complete\":";
  json += complete ? "true" : "false";
  json += "}";
  return json;
}

// Rolls the input back to `original` and RE-READS it. Returns true only when the
// re-read input byte-equals `original`; callers must never report a successful
// rollback without this confirmation.
bool restore_input_and_verify(rime::Context* context,
                              const std::string& original) {
  context->set_input(original);
  return context->input() == original;
}

int rollback_result(rime::Context* context, const std::string& original) {
  return restore_input_and_verify(context, original)
             ? RB_AMBIG_FAILED
             : RB_AMBIG_FAILED_ROLLBACK_UNVERIFIED;
}

// ---- versioned rewrite capabilities ----------------------------------------
//
// The bridge does NOT decide the lock mode from a bare declaration: it reads the
// active schema's declared capability and then checks it against the live
// producer and its source schema through the shared identity module
// (`rime_identity::verify_rewrite_capability`). A declaration whose
// namespace/adapter/source do not match is treated as absent: lockMode "none", no lockable option,
// and apply/restore refused. There is no pinyin shape/declaration gate anywhere.
//
// Recognized locks:
//   * `bounded_token_alias_rewrite_v2` (current, SCHEMA-AGNOSTIC): declared by the
//     `keyboard_rewrite` block. The segment is rewritten to the opaque `lock_map`
//     alias for the chosen token; any syllable the live prism proves (pinyin,
//     double-pinyin, shape code, Bopomofo, dialect, ...) is handled identically.
//
// `lock_map` is ALWAYS re-proven against the live prism: an alias is accepted
// only when its full-span enumeration is exactly the chosen token.

using RewriteCapability = rime_identity::RewriteCapability;

// Stat identity of a deployed (build/) schema file; `exists == false` when absent.
struct FileStamp {
  bool exists = false;
  uint64_t inode = 0;
  int64_t size = 0;
  int64_t mtime_sec = 0;
  int64_t mtime_nsec = 0;
  bool operator==(const FileStamp& o) const {
    return exists == o.exists && inode == o.inode && size == o.size &&
           mtime_sec == o.mtime_sec && mtime_nsec == o.mtime_nsec;
  }
};

FileStamp deployed_schema_stamp(const std::string& schema_id) {
  FileStamp stamp;
  if (schema_id.empty()) return stamp;
  rime::the<rime::ResourceResolver> resolver(
      rime::Service::instance().CreateDeployedResourceResolver(
          {"compiled_schema", "", ".schema.yaml"}));
  if (!resolver) return stamp;
  const rime::path path = resolver->ResolvePath(schema_id);
  struct stat info;
  if (path.empty() || ::stat(path.c_str(), &info) != 0) return stamp;
  stamp.exists = true;
  stamp.inode = static_cast<uint64_t>(info.st_ino);
  stamp.size = static_cast<int64_t>(info.st_size);
  stamp.mtime_sec = static_cast<int64_t>(info.st_mtimespec.tv_sec);
  stamp.mtime_nsec = static_cast<int64_t>(info.st_mtimespec.tv_nsec);
  return stamp;
}

// Everything the verification reads. The in-memory part (schema/config/
// dictionary objects and the open table/prism checksums) changes on any
// redeploy or schema switch; the two file stamps cover the only disk inputs:
// the compiled schema, and the declared source
// schema that is re-parsed for its facts. A changed stamp re-verifies.
struct CapabilityKey {
  const void* schema = nullptr;
  const void* config = nullptr;
  const void* dictionary = nullptr;
  std::string schema_id;
  std::string source_schema;
  uint32_t table_checksum = 0;
  uint32_t prism_checksum = 0;
  uint32_t prism_schema_checksum = 0;
  FileStamp compiled;
  FileStamp source;
  bool operator==(const CapabilityKey& o) const {
    return schema == o.schema && config == o.config && dictionary == o.dictionary &&
           schema_id == o.schema_id && source_schema == o.source_schema &&
           table_checksum == o.table_checksum && prism_checksum == o.prism_checksum &&
           prism_schema_checksum == o.prism_schema_checksum &&
           compiled == o.compiled && source == o.source;
  }
};

std::mutex capability_memo_mutex;
bool capability_memo_valid = false;
CapabilityKey capability_memo_key;
RewriteCapability capability_memo_value;

// The verified rewrite capability of the active schema, or a `verified == false`
// value when the schema declares none / the binding does not recompute.
//
// The full verification re-reads and CRCs the compiled schema and re-parses the
// source schema (~7.6 ms per call on a phone-class core with rime-ice), and the
// 9-key display path asks for it on every key. It is still computed by the one
// shared algorithm; the result is reused only while every input it reads is
// provably unchanged (`CapabilityKey`).
RewriteCapability verified_rewrite_capability(rime::Session* session) {
  RewriteCapability result;
  if (!session) return result;
  rime::Schema* schema = session->schema();
  if (!schema) return result;
  rime::Config* config = schema->config();
  if (!config) return result;
  const std::vector<std::string> namespaces =
      single_producer_namespaces(config);
  rime::Dictionary* dictionary =
      namespaces.size() == 1 ? dictionary_for(schema, namespaces.front())
                             : nullptr;

  CapabilityKey key;
  key.schema = schema;
  key.config = config;
  key.dictionary = dictionary;
  key.schema_id = schema->schema_id();
  config->GetString("keyboard_rewrite/source_schema", &key.source_schema);
  // Unopened tables leave the checksums 0; the verification then fails closed
  // and the zero key re-verifies once they open.
  if (dictionary && dictionary->loaded()) {
    const auto& table = dictionary->primary_table();
    const auto& prism = dictionary->prism();
    if (table && table->IsOpen()) key.table_checksum = table->dict_file_checksum();
    if (prism && prism->IsOpen()) {
      key.prism_checksum = prism->dict_file_checksum();
      key.prism_schema_checksum = prism->schema_file_checksum();
    }
  }
  key.compiled = deployed_schema_stamp(key.schema_id);
  key.source = deployed_schema_stamp(key.source_schema);

  {
    std::lock_guard<std::mutex> lock(capability_memo_mutex);
    if (capability_memo_valid && capability_memo_key == key)
      return capability_memo_value;
  }
  result = rime_identity::verify_rewrite_capability(session, schema, config,
                                                    dictionary);
  // Only a fully loaded producer is memoized: a verification that ran while
  // the tables were still opening must not stand in for the opened state.
  if (key.table_checksum != 0 && key.prism_checksum != 0) {
    std::lock_guard<std::mutex> lock(capability_memo_mutex);
    capability_memo_key = key;
    capability_memo_value = result;
    capability_memo_valid = true;
  }
  return result;
}

// Map a VERIFIED capability to the concrete rewrite mode. An unverified
// capability (absent, wrong adapter, cross-wired source,
// unloaded producer) is always `kNone`: no lock, no rewrite.
enum class LockMode { kNone, kTokenAlias, kDirect, kPrefix };

LockMode lock_mode_of(const RewriteCapability& capability) {
  if (!capability.verified) return LockMode::kNone;
  if (capability.lock == rime_identity::kTokenAliasLockValue())
    return LockMode::kTokenAlias;
  if (capability.lock == rime_identity::kDirectTokenLockValue())
    return LockMode::kDirect;
  if (capability.lock == rime_identity::kPrefixTokenLockValue())
    return LockMode::kPrefix;
  return LockMode::kNone;
}

// The opaque alias for `token` from a VERIFIED capability. Absent -> false (a
// missing/rejected token must never be locked).
bool capability_lock_alias(const RewriteCapability& capability,
                           const std::string& token, std::string* alias) {
  auto it = capability.lock_map.find(token);
  if (it == capability.lock_map.end() || it->second.empty()) return false;
  *alias = it->second;
  return true;
}

}  // namespace

extern "C" char* rb_copy_highlighted_spelling(uintptr_t session_id) {
  if (session_id == 0) return nullptr;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return nullptr;
  std::vector<std::string> syllables;
  std::string delimiter;
  if (!decode_highlighted_syllables(session.get(), &syllables, &delimiter))
    return nullptr;

  std::string joined;
  for (size_t i = 0; i < syllables.size(); ++i) {
    if (i) joined += delimiter;
    joined += syllables[i];
  }
  if (joined.empty()) return nullptr;

  char* result = static_cast<char*>(malloc(joined.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, joined.c_str(), joined.size() + 1);
  return result;
}

// The same trusted decode as rb_copy_highlighted_spelling, but returned as the
// canonical syllable token array plus the engine display separator. The display
// policy maps each token through the schema's declared capability; handing it
// the array (not a pre-joined string) is what lets source-code projection stay
// per-syllable and unambiguous.
extern "C" char* rb_copy_highlighted_syllables_json(uintptr_t session_id) {
  if (session_id == 0) return nullptr;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return nullptr;
  std::vector<std::string> syllables;
  std::string delimiter;
  if (!decode_highlighted_syllables(session.get(), &syllables, &delimiter))
    return nullptr;

  std::string json = "{\"separator\":\"" + json_escape(delimiter) +
                     "\",\"syllables\":[";
  for (size_t i = 0; i < syllables.size(); ++i) {
    if (i) json += ",";
    json += "\"" + json_escape(syllables[i]) + "\"";
  }
  json += "]}";
  char* result = static_cast<char*>(malloc(json.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, json.c_str(), json.size() + 1);
  return result;
}

extern "C" unsigned long long rb_spelling_decode_count(void) {
  return g_decode_count.load(std::memory_order_relaxed);
}

// ---- read-only page select metadata -----------------------------------------
//
// `RimeMenu.select_keys` / `RimeContext.select_labels` are per-page-slot
// metadata derived from the schema's `menu/alternative_select_keys` and
// `menu/alternative_select_labels`. The cross-page read-only candidate iterator
// has no channel for them, and the full-snapshot path (`rb_snapshot_get`)
// consumes a pending commit, so this dedicated helper reads them straight from
// the LIVE schema config. It never touches the menu/context/commit, changes no
// page/highlight/input, and is page-independent (slot metadata is stable across
// pages), so the caller can map page-local slot -> key/label on any page.
//
// Slot arrays are returned per Unicode scalar (never byte-indexed), so a
// multi-byte key stays exactly one slot and the caller does not have to split
// UTF-8 itself.
//   {"page_size":5,"select_keys":["a","s",...]|null,
//    "select_labels":["甲",...]|null}
// NULL only when there is no live session/schema/config. An UNDECLARED list is
// JSON null, never a synthesized default 1..9.
extern "C" char* rb_copy_context_metadata_json(uintptr_t session_id) {
  if (session_id == 0) return nullptr;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return nullptr;
  rime::Schema* schema = session->schema();
  if (!schema) return nullptr;
  rime::Config* config = schema->config();
  if (!config) return nullptr;

  const int page_size = schema->page_size();

  // Per-slot select keys. Split the schema's select-key string into Unicode
  // scalars; never index by byte.
  bool keys_present = false;
  std::vector<std::string> keys;
  {
    const std::string& raw = schema->select_keys();
    if (!raw.empty()) {
      keys_present = true;
      for (size_t i = 0; i < raw.size();) {
        const unsigned char c = static_cast<unsigned char>(raw[i]);
        size_t len = 1;
        if ((c & 0x80) == 0x00) {
          len = 1;
        } else if ((c & 0xE0) == 0xC0) {
          len = 2;
        } else if ((c & 0xF0) == 0xE0) {
          len = 3;
        } else if ((c & 0xF8) == 0xF0) {
          len = 4;
        }
        if (i + len > raw.size()) len = 1;  // malformed tail: keep one byte
        keys.push_back(raw.substr(i, len));
        i += len;
      }
    }
  }

  // Per-slot labels. librime only emits them when the declared list covers the
  // whole page; mirror that rule exactly (never a partial label set).
  bool labels_present = false;
  std::vector<std::string> labels;
  if (page_size > 0) {
    rime::an<rime::ConfigList> list =
        config->GetList("menu/alternative_select_labels");
    if (list && static_cast<size_t>(page_size) <= list->size()) {
      labels_present = true;
      for (int i = 0; i < page_size; ++i) {
        rime::an<rime::ConfigValue> value =
            list->GetValueAt(static_cast<size_t>(i));
        labels.push_back(value ? value->str() : std::string());
      }
    }
  }

  std::string json = "{\"page_size\":" + std::to_string(page_size);
  json += ",\"select_keys\":";
  if (keys_present) {
    json += "[";
    for (size_t i = 0; i < keys.size(); ++i) {
      if (i) json += ",";
      json += "\"" + json_escape(keys[i]) + "\"";
    }
    json += "]";
  } else {
    json += "null";
  }
  json += ",\"select_labels\":";
  if (labels_present) {
    json += "[";
    for (size_t i = 0; i < labels.size(); ++i) {
      if (i) json += ",";
      json += "\"" + json_escape(labels[i]) + "\"";
    }
    json += "]";
  } else {
    json += "null";
  }
  json += "}";

  char* result = static_cast<char*>(malloc(json.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, json.c_str(), json.size() + 1);
  return result;
}

// Read-only pronunciation metadata for one absolute candidate. NULL means
// unproven provenance (including sentence/completion/foreign translators), never
// a guessed reading. The caller retains such candidates in the unfiltered list.
extern "C" char* rb_copy_candidate_syllables_json(uintptr_t session_id, int index) {
  if (!session_id || index < 0) return nullptr;
  auto session = rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return nullptr;
  auto* context = session->context();
  if (!context || context->composition().empty()) return nullptr;
  auto root = context->composition().back().GetCandidateAt(index);
  if (!root) return nullptr;
  std::vector<std::vector<std::string>> paths;
  std::set<std::vector<std::string>> seen;
  bool complete = true;
  std::function<void(rime::an<rime::Candidate>)> visit = [&](auto item) {
    if (!item || item->text() != root->text() || item->start() != root->start() || item->end() != root->end()) {
      complete = false; return;
    }
    if (auto shadow = rime::As<rime::ShadowCandidate>(item)) {
      auto child = shadow->item();
      if (!child || item->text() != child->text() || item->preedit() != child->preedit() ||
          item->start() != child->start() || item->end() != child->end()) { complete = false; return; }
      visit(child); return;
    }
    if (auto unique = rime::As<rime::UniquifiedCandidate>(item)) {
      // Group preedit belongs to its first item. It is NOT a valid equality
      // requirement for other legitimate pronunciations of the same word.
      if (unique->items().empty()) complete = false;
      for (const auto& child : unique->items()) visit(child);
      return;
    }
    std::vector<std::string> syllables;
    std::string delimiter;
    if (!decode_highlighted_syllables(session.get(), &syllables, &delimiter, index, item)) {
      complete = false; return;
    }
    if (seen.insert(syllables).second) paths.push_back(syllables);
  };
  visit(root);
  if (paths.empty()) return nullptr;
  std::string json = std::string("{\"complete\":") + (complete ? "true" : "false") + ",\"paths\":[";
  for (size_t p = 0; p < paths.size(); ++p) {
    if (p) json += ",";
    json += "[";
    for (size_t i = 0; i < paths[p].size(); ++i) {
      if (i) json += ",";
      json += "\"" + json_escape(paths[p][i]) + "\"";
    }
    json += "]";
  }
  json += "]}";
  char* result = static_cast<char*>(malloc(json.size() + 1));
  if (result) std::memcpy(result, json.c_str(), json.size() + 1);
  return result;
}

// ---- read-only ambiguity spelling enumeration ------------------------------
//
// See rime_bridge.h for the full contract. REPORT ONLY: reads the current
// composition's back `abc` segment and the schema's own Script/Prism/
// Syllabifier. It never rewrites input, never touches candidates, and never
// reads the mutable comment. The provenance/dictionary lookup is the same
// unique-primary-producer rule used by enumerate_segment_spellings (a principal
// script_translator OR table_translator), NOT the script-exclusive display gate.
extern "C" char* rb_copy_ambiguity_spellings_json(uintptr_t session_id,
                                                 int max_items) {
  if (session_id == 0) return nullptr;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return nullptr;
  rime::Context* context = session->context();
  rime::Schema* schema = session->schema();
  if (!context || !schema || !context->IsComposing()) return nullptr;

  const auto& composition = context->composition();
  if (composition.empty()) return nullptr;
  const rime::Segment& segment = composition.back();
  // Only an `abc` (spelling-alphabet) segment is a reduced-code unit. Any other
  // tag (raw/punct/matcher/calculator/...) is not a spelling input.
  if (!segment.HasTag("abc")) return nullptr;
  if (segment.end <= segment.start) return nullptr;

  const std::string input = context->input();
  if (segment.end > input.size()) return nullptr;
  const std::string raw = input.substr(segment.start, segment.end - segment.start);
  if (raw.empty()) return nullptr;

  // Provenance + enumeration: the unique primary producer (script or table), its
  // own dictionary/prism, and the production syllable graph proving the raw is
  // fully interpreted as one spelling. Multi-syllable splits are deliberately
  // not listed (they are segmentations, not spellings of this unit).
  std::set<std::string> spellings;
  if (!enumerate_segment_spellings(session.get(), raw, &spellings))
    return nullptr;

  int cap = max_items;
  if (cap <= 0) cap = 32;
  if (cap > 64) cap = 64;

  // The rewrite capability is verified FRESH here (report time), independent of
  // the display path. An unverified declaration yields lockMode "none" and no
  // lockable option, while `spellings` still reports the live prism truth.
  const RewriteCapability capability = verified_rewrite_capability(session.get());
  const LockMode mode = lock_mode_of(capability);

  // The emitted spelling list is capped exactly as before (dedup/sorted order
  // preserved). Every mode builds its options from what is actually emitted, so
  // the wire invariant `lockable ⊆ spellings` can never be broken by truncation.
  std::vector<std::string> emitted_spellings;
  bool complete = true;
  for (const auto& spelling : spellings) {
    if (emitted_spellings.size() >= static_cast<size_t>(cap)) {
      complete = false;
      break;
    }
    emitted_spellings.push_back(spelling);
  }

  // v4: the bounded letter-class PREFIX options. They are a separate, always
  // complete list (the front end's letter-class choices must never be lost to
  // the spellings cap); each one is live-proven to narrow the segment.
  if (mode == LockMode::kPrefix) {
    std::vector<PrefixOption> options;
    if (!enumerate_prefix_options(session.get(), capability.prefix_keys, raw, &options))
      return nullptr;
    std::set<std::string> exact_tokens;
    if (!enumerate_exact_token_options(session.get(), emitted_spellings, &exact_tokens))
      return nullptr;

    std::set<std::string> lockable = exact_tokens;
    std::vector<std::string> prefix_options;
    std::map<std::string, std::string> semantics;
    for (const auto& token : exact_tokens) semantics[token] = "exact";
    for (const auto& option : options) {
      prefix_options.push_back(option.key);
      lockable.insert(option.key);
      // An exact-token label always wins (the key truly locks one token).
      if (semantics.find(option.key) == semantics.end())
        semantics[option.key] = prefix_semantics_name(option.semantics);
    }
    std::vector<std::pair<std::string, std::string>> ordered_semantics(
        semantics.begin(), semantics.end());
    std::string json = build_prefix_ambiguity_json(
        input, segment.start, segment.end, emitted_spellings,
        std::vector<std::string>(lockable.begin(), lockable.end()), prefix_options,
        ordered_semantics, complete);
    char* result = static_cast<char*>(malloc(json.size() + 1));
    if (!result) return nullptr;
    std::memcpy(result, json.c_str(), json.size() + 1);
    return result;
  }

  // Per-option lockability: a token is lockable only when its rewrite target is
  // itself proven against the CURRENT prism. Alias mode requires the
  // capability's opaque alias to enumerate to exactly that token; direct mode
  // requires the token itself to be such a key. Tokens that fail stay listed (display only)
  // but are NOT advertised as lockable. No option is ever synthesized from the
  // token shape; the live prism is the only authority.
  std::set<std::string> lockable;
  for (const auto& spelling : emitted_spellings) {
    if (mode == LockMode::kTokenAlias) {
      std::string alias;
      if (!capability_lock_alias(capability, spelling, &alias)) continue;
      std::set<std::string> alias_set;
      if (enumerate_segment_spellings(session.get(), alias, &alias_set) &&
          alias_set.size() == 1 && alias_set.find(spelling) != alias_set.end())
        lockable.insert(spelling);
    } else if (mode == LockMode::kDirect) {
      // The option IS the rewrite target: the source token must itself be a live
      // prism key whose full-span enumeration is exactly {option}.
      std::set<std::string> self_set;
      if (enumerate_segment_spellings(session.get(), spelling, &self_set) &&
          self_set.size() == 1 && self_set.find(spelling) != self_set.end())
        lockable.insert(spelling);
    }
  }

  const char* mode_name = mode == LockMode::kTokenAlias ? "bounded_token_alias"
                        : mode == LockMode::kDirect ? "direct_token"
                        : "none";
  std::string json = build_ambiguity_json(input, segment.start, segment.end,
                                          mode_name, spellings, lockable, cap,
                                          nullptr);

  char* result = static_cast<char*>(malloc(json.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, json.c_str(), json.size() + 1);
  return result;
}

extern "C" int rb_apply_ambiguity_spelling(uintptr_t session_id,
                                            const char* expected_input,
                                            int segment_start,
                                            int segment_end,
                                            const char* spelling) {
  if (session_id == 0 || !expected_input || !spelling) return RB_AMBIG_INVALID;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return RB_AMBIG_INVALID;
  rime::Context* context = session->context();
  rime::Schema* schema = session->schema();
  if (!context || !schema) return RB_AMBIG_INVALID;

  const std::string expected(expected_input);
  const std::string chosen(spelling);
  // Fresh binding verification at APPLY time too: a stale/cross-wired capability
  // must not rewrite input even if a previous report advertised a lock.
  const RewriteCapability capability = verified_rewrite_capability(session.get());
  const LockMode mode = lock_mode_of(capability);
  if (mode == LockMode::kNone) return RB_AMBIG_UNSUPPORTED;
  const std::string input = context->input();
  std::string raw;
  if (!context->IsComposing() || input != expected ||
      !live_tail_abc_span(context, input, segment_start, segment_end, &raw))
    return RB_AMBIG_STALE;

  // Re-prove the chosen spelling against the CURRENT prism's complete full-span
  // set. No cached/previous enumeration is trusted. (The prefix mode proves its
  // options differently — they are coded narrowings, not necessarily tokens of
  // the segment — so its membership rule lives in its own branch below.)
  std::set<std::string> spellings;
  if (!enumerate_segment_spellings(session.get(), raw, &spellings))
    return RB_AMBIG_INVALID;
  if (mode != LockMode::kPrefix &&
      (chosen.empty() || spellings.find(chosen) == spellings.end()))
    return RB_AMBIG_INVALID;

  // The rewrite target depends on the mode. All are re-proven here:
  //  * alias: the capability's opaque alias must be a prism key that enumerates
  //    to EXACTLY the chosen token (unique), so the merged ambiguity is
  //    genuinely resolved rather than shifted. This is what makes the alias path
  //    schema-agnostic: the alias is accepted only when the live prism resolves
  //    it back to the exact chosen token, whatever that token is.
  //  * prefix (v4): the chosen key must be an option of THIS raw segment,
  //    recomputed live: a declared single-character key whose interpretation set
  //    is a non-empty SUBSET of the segment's; or an exact token (a normal
  //    interpretation that is itself a live key interpreting to exactly itself).
  //    The rewrite is DIRECT (no opaque alias exists in this mode).
  std::string target = chosen;
  bool prefix_option = false;
  if (mode == LockMode::kTokenAlias) {
    std::string alias;
    if (!capability_lock_alias(capability, chosen, &alias))
      return RB_AMBIG_INVALID;
    std::set<std::string> alias_set;
    if (!enumerate_segment_spellings(session.get(), alias, &alias_set))
      return RB_AMBIG_INVALID;
    if (alias_set.size() != 1 || alias_set.find(chosen) == alias_set.end())
      return RB_AMBIG_INVALID;
    target = alias;
  } else if (mode == LockMode::kDirect) {
    // The direct target must itself enumerate uniquely to the chosen token.
    std::set<std::string> self_set;
    if (!enumerate_segment_spellings(session.get(), chosen, &self_set))
      return RB_AMBIG_INVALID;
    if (self_set.size() != 1 || self_set.find(chosen) == self_set.end())
      return RB_AMBIG_INVALID;
    target = chosen;
  } else if (mode == LockMode::kPrefix) {
    if (chosen.empty() || chosen.size() > 64) return RB_AMBIG_INVALID;
    std::vector<PrefixOption> options;
    if (!enumerate_prefix_options(session.get(), capability.prefix_keys, raw, &options))
      return RB_AMBIG_INVALID;
    for (const auto& option : options) {
      if (option.key == chosen) { prefix_option = true; break; }
    }
    if (!prefix_option) {
      // Not a letter-class narrowing: only an EXACT token of this segment may be
      // locked directly, and only when it is itself a live key resolving to
      // exactly that token.
      if (spellings.find(chosen) == spellings.end()) return RB_AMBIG_INVALID;
      std::set<std::string> exact_tokens;
      if (!enumerate_exact_token_options(
              session.get(), std::vector<std::string>(spellings.begin(), spellings.end()),
              &exact_tokens))
        return RB_AMBIG_INVALID;
      if (exact_tokens.find(chosen) == exact_tokens.end()) return RB_AMBIG_INVALID;
    }
    target = chosen;
  }

  const std::string rewritten =
      replace_span(input, segment_start, segment_end, target);
  context->set_input(rewritten);

  // Post-validate; never leave a half-written state.
  const int expected_end = segment_start + static_cast<int>(target.size());
  bool ok = context->IsComposing() && context->input() == rewritten;
  if (ok) {
    const auto& composition = context->composition();
    ok = !composition.empty();
    if (ok) {
      const rime::Segment& back = composition.back();
      ok = back.HasTag("abc") && static_cast<int>(back.start) == segment_start &&
           static_cast<int>(back.end) == expected_end;
    }
  }
  // The rewritten span must still be a valid, non-empty composition unit, and in
  // the prefix mode it must really narrow: every interpretation of the new span
  // has to be reachable from the segment the user actually typed. This is the
  // same subset proof the report advertised, re-run on the post-write state.
  if (ok && mode == LockMode::kPrefix) {
    std::map<std::string, rime::SpellingType> narrowed;
    ok = prism_key_interpretations(session.get(), target, &narrowed) &&
         !narrowed.empty();
    if (ok) {
      const std::string live_input = context->input();
      std::string live_raw;
      ok = live_tail_abc_span(context, live_input, segment_start, expected_end,
                              &live_raw) && live_raw == target;
      if (ok) ok = prefix_option || narrowed.size() == 1;
    }
  }
  if (!ok) {
    return rollback_result(context, input);
  }
  return RB_AMBIG_OK;
}

extern "C" int rb_restore_ambiguity_spelling(uintptr_t session_id,
                                              const char* expected_input,
                                              int segment_start,
                                              int segment_end,
                                              const char* expected_spelling,
                                              const char* reduced_code) {
  if (session_id == 0 || !expected_input || !expected_spelling || !reduced_code)
    return RB_AMBIG_INVALID;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return RB_AMBIG_INVALID;
  rime::Context* context = session->context();
  rime::Schema* schema = session->schema();
  if (!context || !schema) return RB_AMBIG_INVALID;
  rime::Config* config = schema->config();
  if (!config) return RB_AMBIG_INVALID;

  const std::string expected(expected_input);
  const std::string locked(expected_spelling);
  const std::string reduced(reduced_code);
  const RewriteCapability capability = verified_rewrite_capability(session.get());
  const LockMode mode = lock_mode_of(capability);
  if (mode == LockMode::kNone) return RB_AMBIG_UNSUPPORTED;

  // The live span is the REWRITE TARGET written by apply: the capability's opaque
  // alias in alias mode, or the token itself in direct mode.
  std::string locked_target = locked;
  if (mode == LockMode::kTokenAlias) {
    if (!capability_lock_alias(capability, locked, &locked_target))
      return RB_AMBIG_INVALID;
  } else if (mode == LockMode::kDirect) {
    locked_target = locked;  // the span is the token itself
  }
  const std::string input = context->input();
  std::string raw;
  if (!context->IsComposing() || input != expected ||
      !live_tail_abc_span(context, input, segment_start, segment_end, &raw))
    return RB_AMBIG_STALE;
  if (raw != locked_target) return RB_AMBIG_STALE;

  // A reduced code is only the schema's own typeable alphabet, never arbitrary
  // text: this refuses an arbitrary `set_input` through the restore path.
  std::string alphabet;
  if (!config->GetString("speller/alphabet", &alphabet)) return RB_AMBIG_INVALID;
  if (reduced.empty()) return RB_AMBIG_INVALID;
  for (char c : reduced) {
    if (alphabet.find(c) == std::string::npos) return RB_AMBIG_INVALID;
  }

  // Re-prove the locked span from the CURRENT prism before touching input: the
  // alias must resolve to exactly the token being unlocked. In the prefix mode
  // the locked span is the narrowing key itself, and its validity is proved on
  // the REDUCED side below (the reduced code must still offer that exact key),
  // which is the strongest form of "this unlock is lossless".
  if (mode != LockMode::kPrefix) {
    std::set<std::string> locked_set;
    if (!enumerate_segment_spellings(session.get(), raw, &locked_set))
      return RB_AMBIG_INVALID;
    if (mode == LockMode::kTokenAlias || mode == LockMode::kDirect) {
      if (locked_set.size() != 1 || locked_set.find(locked) == locked_set.end())
        return RB_AMBIG_STALE;
    } else if (locked_set.find(locked) == locked_set.end()) {
      return RB_AMBIG_STALE;
    }
  }

  const std::string rewritten =
      replace_span(input, segment_start, segment_end, reduced);
  context->set_input(rewritten);

  const int expected_end = segment_start + static_cast<int>(reduced.size());
  bool ok = context->IsComposing() && context->input() == rewritten;
  if (ok) {
    const auto& composition = context->composition();
    ok = !composition.empty();
    if (ok) {
      const rime::Segment& back = composition.back();
      ok = back.HasTag("abc") && static_cast<int>(back.start) == segment_start &&
           static_cast<int>(back.end) == expected_end;
    }
  }
  // The reduced code must genuinely re-enumerate to the spelling being
  // restored; otherwise this is not a lossless unlock.
  if (ok) {
    const std::string reduced_raw = context->input().substr(
        static_cast<size_t>(segment_start), reduced.size());
    if (mode == LockMode::kPrefix) {
      // Lossless means the reduced code still offers exactly this key.
      std::vector<PrefixOption> reduced_options;
      std::set<std::string> reduced_spellings;
      std::set<std::string> reduced_exact;
      ok = enumerate_prefix_options(session.get(), capability.prefix_keys,
                                    reduced_raw, &reduced_options) &&
           enumerate_segment_spellings(session.get(), reduced_raw, &reduced_spellings) &&
           enumerate_exact_token_options(
               session.get(),
               std::vector<std::string>(reduced_spellings.begin(), reduced_spellings.end()),
               &reduced_exact);
      if (ok) {
        ok = false;
        for (const auto& option : reduced_options) {
          if (option.key == locked) { ok = true; break; }
        }
        if (!ok) ok = reduced_exact.find(locked) != reduced_exact.end();
      }
    } else {
      std::set<std::string> reduced_set;
      ok = enumerate_segment_spellings(session.get(), reduced_raw, &reduced_set) &&
           reduced_set.find(locked) != reduced_set.end();
    }
  }
  if (!ok) {
    return rollback_result(context, input);
  }
  return RB_AMBIG_OK;
}

// Read-only, CANDIDATE-FREE verification of the active schema's rewrite
// capability, for the installer deploy check. It performs, in one serialized
// step on the caller's engine thread:
//   1. the SAME capability verification as apply/restore (adapter/source/
//      namespace/open Table and Prism);
//   2. ALIAS mode: for EVERY (token, alias) in the verified `lock_map`, a fresh
//      live-prism enumeration of the alias that must equal exactly {token};
//   3. DIRECT mode (table sources): for the bounded `direct_tokens` sample, a
//      fresh live-prism enumeration of the token that must equal exactly {token}
//      (the token is its own rewrite target). The domain is never enumerated.
//   4. PREFIX mode (v4, opted-in numeric script sources): for the bounded
//      `prefix_keys` sample, a fresh live-prism enumeration of the key proving it
//      is a real, non-empty interpretation unit of the companion's own grammar.
//      The per-segment narrowing proof is per user input and is not part of this
//      candidate-free check.
// It never feeds a key, never looks at a candidate, comment or literal, and works
// whether or not any dictionary word exists for a token. Returns malloc JSON:
//   {"present":bool,"verified":bool,"checked":N,"lock":"...","mode":"alias|direct|prefix","failures":[...]}
// `present=false` means the active schema declares no rewrite capability.
extern "C" char* rb_copy_rewrite_verification_json(uintptr_t session_id) {
  if (session_id == 0) return nullptr;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return nullptr;
  const RewriteCapability capability = verified_rewrite_capability(session.get());

  size_t checked = 0;
  std::vector<std::string> failures;
  if (capability.verified && capability.prefix) {
    for (const std::string& key : capability.prefix_keys) {
      ++checked;
      std::map<std::string, rime::SpellingType> key_interpretations;
      if (!enumerate_segment_interpretations(session.get(), key, &key_interpretations) ||
          key_interpretations.empty()) {
        failures.push_back(key);
      }
    }
  } else if (capability.verified && !capability.direct) {
    for (const auto& entry : capability.lock_map) {
      ++checked;
      std::set<std::string> alias_set;
      if (!enumerate_segment_spellings(session.get(), entry.second, &alias_set) ||
          alias_set.size() != 1 ||
          alias_set.find(entry.first) == alias_set.end()) {
        failures.push_back(entry.first);
      }
    }
  } else if (capability.verified && capability.direct) {
    for (const std::string& token : capability.direct_tokens) {
      ++checked;
      std::set<std::string> token_set;
      if (!enumerate_segment_spellings(session.get(), token, &token_set) ||
          token_set.size() != 1 || token_set.find(token) == token_set.end()) {
        failures.push_back(token);
      }
    }
  }

  std::string json = "{\"present\":";
  json += capability.present ? "true" : "false";
  json += ",\"verified\":";
  json += (capability.verified && failures.empty()) ? "true" : "false";
  json += ",\"checked\":" + std::to_string(checked);
  json += ",\"mode\":\"";
  json += capability.prefix ? "prefix" : (capability.direct ? "direct" : "alias");
  json += "\"";
  json += ",\"lock\":\"" + json_escape(capability.lock) + "\"";
  json += ",\"failures\":[";
  for (size_t i = 0; i < failures.size(); ++i) {
    if (i) json += ",";
    json += "\"" + json_escape(failures[i]) + "\"";
  }
  json += "]}";

  char* result = static_cast<char*>(malloc(json.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, json.c_str(), json.size() + 1);
  return result;
}

extern "C" void rb_spelling_reset(void) {
  drop_cached_dictionary();
  g_decode_count.store(0, std::memory_order_relaxed);
}

// Test-only (compiled only with -DRB_AMBIGUITY_SELFTEST, never in the shipped
// slices). Proves the emission invariant `lockable ⊆ spellings` under a synthetic
// over-cap input without needing a giant real dictionary. Returns 0 on success.
#ifdef RB_AMBIGUITY_SELFTEST
extern "C" int rb_ambiguity_json_selftest(void) {
  std::set<std::string> spellings;
  for (int i = 0; i < 100; ++i) {
    char buf[8];
    std::snprintf(buf, sizeof(buf), "s%03d", i);
    spellings.insert(buf);
  }
  std::set<std::string> lockable = spellings;  // every option lockable
  bool complete = true;
  std::string json = build_ambiguity_json("raw", 0, 3, "bounded_token_alias",
                                          spellings, lockable, 64, &complete);
  // Truncated to 64: the first 64 sorted spellings only, and lockable must not
  // contain anything beyond them.
  if (complete) return 1;
  if (json.find("\"spellings\":[\"s000\"") == std::string::npos) return 2;
  if (json.find("\"s063\"") == std::string::npos) return 3;
  if (json.find("\"s064\"") != std::string::npos) return 4;   // not emitted
  if (json.find("\"s090\"") != std::string::npos) return 5;   // never lockable
  if (json.find("\"complete\":false") == std::string::npos) return 6;
  // A second, non-truncating cap keeps the whole subset.
  bool complete2 = false;
  std::string json2 = build_ambiguity_json("raw", 0, 3, "none", spellings,
                                           lockable, 100, &complete2);
  if (!complete2) return 7;
  if (json2.find("\"s099\"") == std::string::npos) return 8;

  // v4 prefix shape: the narrowing keys are emitted in FULL even when the
  // spellings list truncates, `lockable` may reference either list, and the
  // per-option semantics are present. This is the wire invariant the front end
  // relies on to never lose a letter-class choice to a diagnostic cap.
  std::vector<std::string> prefix_options = {"a", "b", "c"};
  std::vector<std::string> prefix_lockable = {"a", "b", "c", "s000"};
  std::vector<std::pair<std::string, std::string>> semantics = {
      {"a", "initial"}, {"b", "initial"}, {"c", "initial"}, {"s000", "exact"}};
  std::string prefix_json = build_prefix_ambiguity_json(
      "2", 0, 1, {"s000", "s001"}, prefix_lockable, prefix_options,
      semantics, false);
  if (prefix_json.find("\"lock_mode\":\"prefix_token\"") == std::string::npos) return 9;
  if (prefix_json.find("\"prefix_options\":[\"a\",\"b\",\"c\"]") == std::string::npos)
    return 10;
  if (prefix_json.find("\"lockable\":[\"a\",\"b\",\"c\",\"s000\"]") == std::string::npos)
    return 11;
  if (prefix_json.find("\"option_semantics\":{\"a\":\"initial\",\"b\":\"initial\","
                       "\"c\":\"initial\",\"s000\":\"exact\"}") == std::string::npos)
    return 12;
  if (prefix_json.find("\"complete\":false") == std::string::npos) return 13;
  return 0;
}
#endif
