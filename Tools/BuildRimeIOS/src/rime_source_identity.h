// ---------------------------------------------------------------------------
// rime_source_identity.h — shared source-schema facts and rewrite capability.
//
// Header-only so both bridge translation units (rime_display_map.cc and
// rime_spelling.cc) share ONE algorithm text.
//
//   * `SourceFacts` + `source_facts_from_config`: the declared source schema's
//     translator namespace / dictionary / alphabet / algebra / declarations.
//   * `producer_loaded`: whether the active producer's Table and Prism opened.
//   * `verify_rewrite_capability`: reads the companion's rewrite declaration and
//     gates the ambiguity lock on its structure and the live producer.
// ---------------------------------------------------------------------------
#ifndef RIME_SOURCE_IDENTITY_H_
#define RIME_SOURCE_IDENTITY_H_

#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include <rime/algo/utilities.h>
#include <rime/component.h>
#include <rime/config.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/prism.h>
#include <rime/dict/table.h>
#include <rime/resource.h>
#include <rime/schema.h>
#include <rime/service.h>
#include <rime/ticket.h>

namespace rime_identity {

// The one producer class this bridge can prove.
enum class ProducerClass { kNone, kScript, kTable };

// The ONE primary producer this bridge can prove. Both directions of the ambiguity
// feature work on a single primary dictionary:
//   * `script_translator` — a Script/Prism/Syllabifier source (pinyin,
//     double-pinyin, shape-code, dialect, ...);
//   * `table_translator`  — a Table/Prism source whose codes are the tokens
//     (Wubi/Cangjie-style shape codes).
//
// The PRIMARY producer is the one in the default `translator` namespace (an entry
// written without `@<name>`); auxiliary translators such as
// `table_translator@custom_phrase` or `lua_translator@*date_translator` are extra
// front-end translators, not the syllabary source. Two or more producers in the
// default namespace (genuinely mixed provenance) yield kNone, so such a schema is
// never trusted.
struct ProducerRef {
  ProducerClass klass = ProducerClass::kNone;
  std::string name_space;
};

inline const char* producer_class_name(ProducerClass klass) {
  switch (klass) {
    case ProducerClass::kScript: return "script_translator";
    case ProducerClass::kTable: return "table_translator";
    default: return "";
  }
}

inline ProducerRef single_producer(rime::Config* config) {
  ProducerRef result;
  if (!config) return result;
  std::vector<ProducerRef> default_slot;
  std::vector<ProducerRef> any_slot;
  for (int i = 0;; ++i) {
    std::string prescription;
    if (!config->GetString("engine/translators/@" + std::to_string(i),
                           &prescription))
      break;
    const size_t at = prescription.find('@');
    const std::string klass = prescription.substr(0, at);
    ProducerClass kind = ProducerClass::kNone;
    if (klass == "script_translator") kind = ProducerClass::kScript;
    else if (klass == "table_translator") kind = ProducerClass::kTable;
    else continue;
    const std::string name_space =
        at == std::string::npos ? "translator" : prescription.substr(at + 1);
    any_slot.push_back({kind, name_space});
    if (at == std::string::npos) default_slot.push_back({kind, name_space});
  }
  if (default_slot.size() == 1) return default_slot.front();
  if (default_slot.size() > 1) return ProducerRef{};  // mixed provenance -> refuse
  if (any_slot.size() == 1) return any_slot.front();
  return ProducerRef{};
}

// Convenience for the display path (which historically only needed the script
// namespaces): the single producer's namespace, empty when not provable.
inline std::vector<std::string> single_producer_namespaces(rime::Config* config) {
  const ProducerRef producer = single_producer(config);
  if (producer.klass == ProducerClass::kNone) return {};
  return {producer.name_space};
}

inline std::string delimiter_for(rime::Config* config, const std::string& name_space) {
  std::string value;
  if (config->GetString(name_space + "/delimiter", &value) && !value.empty())
    return value.substr(0, 1);
  if (config->GetString("speller/delimiter", &value) && !value.empty())
    return value.substr(0, 1);
  return " ";
}

struct SourceFacts {
  std::string source_schema;
  std::string name_space;
  std::string dictionary;
  std::string alphabet;
  std::vector<std::string> algebra;
  // The source's explicit semantic declaration (`keyboard_adapter_source`). Only
  // `canonical_pinyin` is recognized.
  std::string source_declaration;
  // The source's explicit opt-in for the bounded letter-class PREFIX lock layer
  // (`keyboard_rewrite_prefix`, e.g. `letter_class_v1`).
  std::string prefix_declaration;
  // The single producer's class name (`script_translator` / `table_translator`).
  std::string producer_class;
};

// Config-derived source facts of an already-opened schema.
inline bool source_facts_from_config(rime::Config* config,
                                     const std::string& source_schema,
                                     SourceFacts* facts) {
  if (!config || !facts) return false;
  const ProducerRef producer = single_producer(config);
  if (producer.klass == ProducerClass::kNone) return false;
  facts->source_schema = source_schema;
  facts->name_space = producer.name_space;
  facts->producer_class = producer_class_name(producer.klass);
  if (!config->GetString(facts->name_space + "/dictionary", &facts->dictionary) ||
      facts->dictionary.empty())
    return false;
  // Default to a-z when the schema does not declare an alphabet, matching the
  // librime/adaptability default, so the projection and the eligibility/generation
  // contract never disagree about the physical input alphabet.
  if (!config->GetString("speller/alphabet", &facts->alphabet) ||
      facts->alphabet.empty())
    facts->alphabet = "abcdefghijklmnopqrstuvwxyz";
  facts->algebra.clear();
  auto rules = config->GetList("speller/algebra");
  if (rules) {
    for (size_t i = 0; i < rules->size(); ++i) {
      rime::an<rime::ConfigValue> value = rules->GetValueAt(i);
      if (value) facts->algebra.push_back(value->str());
    }
  }
  if (!config->GetString("keyboard_adapter_source", &facts->source_declaration))
    facts->source_declaration.clear();
  if (!config->GetString("keyboard_rewrite_prefix", &facts->prefix_declaration))
    facts->prefix_declaration.clear();
  return true;
}

// True when the active producer's primary Table and Prism are open. Only
// `Dictionary::Load()` (itself IsOpen-guarded) is called: the component shares
// Table/Prism objects across the process, and re-opening a table would unmap
// memory a live translator iterator is borrowing.
inline bool producer_loaded(rime::Dictionary* dictionary) {
  if (!dictionary) return false;
  if (!dictionary->Load() || !dictionary->loaded()) return false;
  const auto& table = dictionary->primary_table();
  const auto& prism = dictionary->prism();
  return table && table->IsOpen() && prism && prism->IsOpen();
}

// ---- rewrite capability verification ---------------------------------------

// The declared input-rewrite capability of the active schema. `verified` is the
// decisive gate: true only when the declaration is structurally complete AND its
// source/producer binding recomputes exactly.
//
// Three families:
//   * ALIAS (script sources, wire `bounded_token_alias_rewrite_v2`): a bounded
//     `lock_map` maps each token to an opaque alias.
//     The alias is rewritten into the input and re-proven against the live prism.
//   * DIRECT (table sources, wire `direct_token_rewrite_v3`): NO lock_map. The
//     chosen token (a genuine source code) is itself a live prism key and is
//     rewritten directly; `direct_tokens` is a bounded sample used by the deploy
//     check. The token domain is the source dictionary's own code inventory, so
//     nothing is enumerated or aliased per code.
//   * PREFIX (numeric script sources with an explicit opt-in, wire
//     `prefix_token_rewrite_v4`): NO lock_map, NO per-token metadata. The bounded
//     `prefix_keys` sample names the single-character live prism keys the
//     companion's own grammar adds (letter-class attachments). At report/apply
//     time the runtime proves per segment that each option is a live key whose
//     interpretation set is a non-empty SUBSET of the segment's, so the rewrite
//     only ever narrows. The deploy check proves every sampled key is live.
struct RewriteCapability {
  bool present = false;
  bool verified = false;
  bool direct = false;                     // v3 direct-code mode
  bool prefix = false;                     // v4 letter-class prefix mode
  std::string lock;                        // e.g. direct_token_rewrite_v3
  std::string prefix_layer;                // e.g. letter_class_v1 (v4 only)
  std::map<std::string, std::string> lock_map;
  std::vector<std::string> direct_tokens;  // bounded deploy-check sample
  std::vector<std::string> prefix_keys;    // bounded single-character key sample
};

inline const char* kTokenAliasLockValue() { return "bounded_token_alias_rewrite_v2"; }
inline const char* kDirectTokenLockValue() { return "direct_token_rewrite_v3"; }
inline const char* kPrefixTokenLockValue() { return "prefix_token_rewrite_v4"; }
// The bounded letter-class grammar layer version a v4 companion must declare. A
// v4 block naming any other layer is refused (fail closed), so a future layer
// needs its own wire version.
inline const char* kLetterClassLayerValue() { return "letter_class_v1"; }

inline bool is_known_rewrite_lock(const std::string& value) {
  return value == kTokenAliasLockValue() ||
         value == kDirectTokenLockValue() ||
         value == kPrefixTokenLockValue();
}

// A v4 prefix key is a single printable ASCII character: bounded by one byte,
// inside the speller alphabet range the compact layouts can express, and never a
// control character. The runtime still re-proves liveness against the live prism.
inline bool is_prefix_key_token(const std::string& value) {
  if (value.size() != 1) return false;
  const unsigned char c = static_cast<unsigned char>(value[0]);
  return c >= 0x20 && c < 0x7F;
}

inline void read_string_list(rime::Config* config, const std::string& path,
                             std::vector<std::string>* out) {
  out->clear();
  auto list = config->GetList(path);
  if (!list) return;
  for (size_t i = 0; i < list->size(); ++i) {
    auto value = rime::As<rime::ConfigValue>(list->GetAt(i));
    if (value && !value->str().empty()) out->push_back(value->str());
  }
}

inline void read_string_map(rime::Config* config, const std::string& path,
                            std::map<std::string, std::string>* out) {
  out->clear();
  auto map = config->GetMap(path);
  if (!map) return;
  for (auto it = map->begin(); it != map->end(); ++it) {
    auto value = rime::As<rime::ConfigValue>(it->second);
    if (value) (*out)[it->first] = value->str();
  }
}

// Reads the active schema's rewrite capability and checks it against the live
// producer and the declared source schema.
//
// The `keyboard_rewrite` block declares version 2 + alias lock + `lock_map`, OR
// version 3 + direct lock + bounded `direct_tokens`, OR version 4 + prefix lock +
// `prefix_layer` + bounded `prefix_keys`.
//
// Verification (all must hold, or `verified` stays false):
//   * a recognized lock value matching its wire version, `adapter_schema` == the
//     ACTIVE schema id, and the payload required by the mode (a non-empty
//     `lock_map` for alias, a non-empty bounded `direct_tokens` for direct, a
//     non-empty bounded single-character `prefix_keys` + the recognized
//     `prefix_layer` for prefix);
//   * the ACTIVE producer's primary Table & Prism are open;
//   * the declared source schema resolves to exactly ONE producer (script or
//     table, not mixed), and its class/namespace agree.
//
// A leftover `source_fingerprint` key in an older companion is ignored.
//
// This runs on the caller's serialized engine thread. It is the rewrite-side
// analogue of `RimeDisplayContext::authorizedMode()`; the two intentionally
// share this one algorithm.
inline RewriteCapability verify_rewrite_capability(rime::Session* session,
                                                   rime::Schema* schema,
                                                   rime::Config* config,
                                                   rime::Dictionary* producer_dictionary) {
  RewriteCapability result;
  if (!schema || !config) return result;

  // --- read the declaration ---
  if (!config->GetMap("keyboard_rewrite")) return result;
  std::string lock, adapter_schema, source_schema, namespace_decl;
  int version = 0;
  config->GetInt("keyboard_rewrite/version", &version);
  config->GetString("keyboard_rewrite/lock", &lock);
  config->GetString("keyboard_rewrite/adapter_schema", &adapter_schema);
  config->GetString("keyboard_rewrite/source_schema", &source_schema);
  config->GetString("keyboard_rewrite/translator_namespace", &namespace_decl);
  config->GetString("keyboard_rewrite/prefix_layer", &result.prefix_layer);
  read_string_map(config, "keyboard_rewrite/lock_map", &result.lock_map);
  read_string_list(config, "keyboard_rewrite/direct_tokens", &result.direct_tokens);
  read_string_list(config, "keyboard_rewrite/prefix_keys", &result.prefix_keys);
  if (lock.empty() && result.lock_map.empty() && result.direct_tokens.empty() &&
      result.prefix_keys.empty())
    return result;  // no capability
  result.present = true;
  result.lock = lock;

  const bool v2_shape_ok = version == 2 && lock == kTokenAliasLockValue();
  const bool v3_shape_ok = version == 3 && lock == kDirectTokenLockValue();
  const bool v4_shape_ok = version == 4 && lock == kPrefixTokenLockValue();
  if (!v2_shape_ok && !v3_shape_ok && !v4_shape_ok) return result;
  if (!is_known_rewrite_lock(result.lock)) return result;
  if (adapter_schema != schema->schema_id()) return result;
  if (v3_shape_ok) {
    result.direct = true;
    // Bounded deploy-check sample; per-code enumeration is deliberately NOT part
    // of the wire format.
    if (result.direct_tokens.empty() || result.direct_tokens.size() > 64) return result;
    if (!result.lock_map.empty()) return result;  // direct mode carries no map
  } else if (v4_shape_ok) {
    result.prefix = true;
    // The bounded single-character key sample + the recognized grammar layer. The
    // runtime re-proves each key live; nothing is enumerated per segment here.
    if (result.prefix_keys.empty() || result.prefix_keys.size() > 64) return result;
    if (!result.lock_map.empty() || !result.direct_tokens.empty()) return result;
    for (const std::string& key : result.prefix_keys) {
      if (!is_prefix_key_token(key)) return result;
    }
    if (result.prefix_layer != kLetterClassLayerValue()) return result;
  } else {
    if (result.lock_map.empty()) return result;
    if (result.lock_map.size() > 4096) return result;
  }
  if (source_schema.empty()) return result;

  // --- producer must be loaded ---
  if (!producer_loaded(producer_dictionary)) return result;

  // --- declared source facts (fresh) ---
  auto* schema_component = rime::Config::Require("schema");
  if (!schema_component) return result;
  rime::the<rime::Config> source_config(schema_component->Create(source_schema));
  SourceFacts source;
  if (!source_config || !source_facts_from_config(source_config.get(),
                                                  source_schema, &source)) {
    return result;
  }
  if (!namespace_decl.empty() && namespace_decl != source.name_space) return result;
  // The direct mode only makes sense for a table source; the alias and prefix
  // modes only for a script source. A mismatch is refused (a copied/cross-wired
  // block).
  if (result.direct && source.producer_class != "table_translator") return result;
  if ((!result.direct) && source.producer_class != "script_translator") return result;
  // A v4 companion is only authorized for a source that EXPLICITLY opted into the
  // bounded letter-class prefix layer, so a block copied onto a non-opted
  // companion (or generated from a non-opted source) is refused here.
  if (result.prefix && source.prefix_declaration != kLetterClassLayerValue())
    return result;

  result.verified = true;
  return result;
}

}  // namespace rime_identity

#endif  // RIME_SOURCE_IDENTITY_H_
