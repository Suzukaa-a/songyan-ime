// ---------------------------------------------------------------------------
// rime_display_map.cc — forward algebra projection + runtime display context.
//
// See rime_display_map.h for the contract. This mirrors DictCompiler::BuildPrism
// (dict_compiler.cc:296-367): take the primary Table syllabary, build a Script,
// apply the schema's own (unmerged) speller/algebra through librime Projection,
// then read back every final spelling together with the origin token carried in
// Spelling::str and the properties librime composed (normal / correction).
//
// No inversion, no string-Apply shortcut, no guessing: only librime's Script
// branch/property semantics. Algebra load failure and a non-empty algebra whose
// Apply reports "not modified" are both refused (the latter is indistinguishable
// from a runtime error and must never be silently treated as identity).
// ---------------------------------------------------------------------------
#include "rime_display_map.h"
#include "rime_source_identity.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <rime/algo/algebra.h>
#include <rime/algo/spelling.h>
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

namespace {

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

// Source facts are shared verbatim with the ambiguity rewrite primitive through
// this ONE header (no second copy to drift).
using rime_identity::delimiter_for;
using rime_identity::producer_loaded;
using rime_identity::single_producer_namespaces;
using rime_identity::source_facts_from_config;
using rime_identity::SourceFacts;

// Per (origin token, final spelling) aggregate: a normal spelling exists if any
// path is kNormalSpelling; correction is false if any path is a non-correction.
struct SpellingAggregate {
  bool normal = false;
  bool correction = true;
  bool present = false;
};

// Appends the declared capability object (or null when malformed). Returns
// whether the raw `keyboard_adapter` KEY exists in the config at all — regardless
// of its type (map / scalar / list / null) and parse success — so any declared
// block, even a malformed or YAML-null one, suppresses the legacy spelling
// protocol without ever authorizing a decode.
//
// Presence must be checked by iterating the parent map's entries: librime stores
// a YAML `null` value as a nullptr entry, and both `GetItem`/`GetMap` AND
// `ConfigMap::HasKey` (defined as `bool(Get(key))`) report it as absent. Only the
// stored entry's key distinguishes null from a truly missing key.
bool append_capability_json(std::string& json, rime::Config* config) {
  bool present = false;
  if (auto root = config->AsMap()) {
    for (auto it = root->begin(); it != root->end(); ++it) {
      if (it->first == "keyboard_adapter") {
        present = true;
        break;
      }
    }
  }
  auto capability = config->GetMap("keyboard_adapter");
  if (!capability) {
    json += "null";
    return present;
  }
  int version = 0;
  std::string mode, source_schema, name_space, separator, policy;
  if (!config->GetInt("keyboard_adapter/version", &version) ||
      !config->GetString("keyboard_adapter/display_mode", &mode) ||
      !config->GetString("keyboard_adapter/source_schema", &source_schema) ||
      !config->GetString("keyboard_adapter/translator_namespace", &name_space) ||
      !config->GetString("keyboard_adapter/separator", &separator)) {
    json += "null";
    return true;
  }
  config->GetString("keyboard_adapter/mapping_policy", &policy);
  std::string adapter_schema;
  config->GetString("keyboard_adapter/adapter_schema", &adapter_schema);
  std::map<std::string, std::string> syllables;
  auto syllable_map = config->GetMap("keyboard_adapter/syllables");
  if (syllable_map) {
    for (auto it = syllable_map->begin(); it != syllable_map->end(); ++it) {
      auto value = rime::As<rime::ConfigValue>(it->second);
      if (value) syllables[it->first] = value->str();
    }
  }
  json += "{\"version\":" + std::to_string(version);
  json += ",\"display_mode\":\"" + json_escape(mode) + "\"";
  json += ",\"source_schema\":\"" + json_escape(source_schema) + "\"";
  json += ",\"translator_namespace\":\"" + json_escape(name_space) + "\"";
  json += ",\"separator\":\"" + json_escape(separator) + "\"";
  json += ",\"mapping_policy\":\"" + json_escape(policy) + "\"";
  json += ",\"adapter_schema\":\"" + json_escape(adapter_schema) + "\"";
  json += ",\"syllables\":{";
  bool first = true;
  for (const auto& entry : syllables) {
    if (!first) json += ",";
    first = false;
    json += "\"" + json_escape(entry.first) + "\":\"" +
            json_escape(entry.second) + "\"";
  }
  json += "}}";
  return true;
}

void append_string_array(std::string& json, const std::vector<std::string>& values) {
  json += "[";
  for (size_t i = 0; i < values.size(); ++i) {
    if (i) json += ",";
    json += "\"" + json_escape(values[i]) + "\"";
  }
  json += "]";
}

}  // namespace

// Runtime display context for the ACTIVE schema: its declared capability block
// (if any), the config facts of the source schema it names, and the ACTIVE
// producer facts. Swift authorizes source_code/canonical only when the block, the
// source schema and the producer agree and the producer's table/prism are loaded;
// otherwise it falls back to the native preedit with a zero candidate decode.
extern "C" char* rb_copy_display_context_json(uintptr_t session_id) {
  if (session_id == 0) return nullptr;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return nullptr;
  rime::Schema* schema = session->schema();
  if (!schema) return nullptr;
  rime::Config* config = schema->config();
  if (!config) return nullptr;

  std::string source_schema;
  config->GetString("keyboard_adapter/source_schema", &source_schema);

  // Active producer facts (the adapter actually running now). The prism name is
  // the one DictionaryComponent resolves: `namespace/prism` when the key is
  // present, else the dictionary name (matching upstream). This is a display
  // label.
  const std::vector<std::string> producer_namespaces =
      single_producer_namespaces(config);
  std::string producer_namespace;
  std::string producer_dictionary;
  std::string producer_prism;
  if (producer_namespaces.size() == 1) {
    producer_namespace = producer_namespaces.front();
    config->GetString(producer_namespace + "/dictionary", &producer_dictionary);
    if (!config->GetString(producer_namespace + "/prism", &producer_prism)) {
      producer_prism = producer_dictionary;
    }
  }
  bool producer_ready = false;
  if (!producer_namespace.empty()) {
    if (auto* component = rime::Dictionary::Require("dictionary")) {
      std::unique_ptr<rime::Dictionary> dictionary(
          component->Create(rime::Ticket(schema, producer_namespace)));
      producer_ready = producer_loaded(dictionary.get());
    }
  }
  // Source config facts (opened by id).
  auto* schema_component = rime::Config::Require("schema");
  SourceFacts source;
  rime::the<rime::Config> source_config;
  bool have_source = false;
  if (schema_component && !source_schema.empty()) {
    source_config.reset(schema_component->Create(source_schema));
    have_source = source_config && source_facts_from_config(
                                      source_config.get(), source_schema, &source);
  }

  std::string json = "{\"capability\":";
  const bool capability_present = append_capability_json(json, config);
  json += ",\"capability_present\":";
  json += capability_present ? "true" : "false";
  json += ",\"producer\":";
  json += "{\"schema_id\":\"" + json_escape(schema->schema_id()) + "\"";
  json += ",\"translator_namespace\":\"" + json_escape(producer_namespace) + "\"";
  json += ",\"dictionary\":\"" + json_escape(producer_dictionary) + "\"";
  json += ",\"prism\":\"" + json_escape(producer_prism) + "\"";
  json += ",\"producer_loaded\":";
  json += producer_ready ? "true" : "false";
  json += "}";

  json += ",\"source\":";
  if (!have_source) {
    json += "null";
  } else {
    json += "{\"source_schema\":\"" + json_escape(source.source_schema) + "\"";
    json += ",\"translator_namespace\":\"" + json_escape(source.name_space) + "\"";
    json += ",\"producer_class\":\"" + json_escape(source.producer_class) + "\"";
    json += ",\"dictionary\":\"" + json_escape(source.dictionary) + "\"";
    json += ",\"alphabet\":\"" + json_escape(source.alphabet) + "\"";
    json += ",\"declaration\":\"" + json_escape(source.source_declaration) + "\"";
    json += ",\"prefix_declaration\":\"" + json_escape(source.prefix_declaration) + "\"";
    json += ",\"algebra\":";
    append_string_array(json, source.algebra);
    json += "}";
  }

  json += "}";

  char* result = static_cast<char*>(std::malloc(json.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, json.c_str(), json.size() + 1);
  return result;
}

extern "C" void rb_copy_display_context_free(char* json) {
  std::free(json);
}

extern "C" char* rb_syllable_display_map_json(uintptr_t session_id) {
  if (session_id == 0) return nullptr;
  auto session =
      rime::Service::instance().GetSession((rime::SessionId)session_id);
  if (!session) return nullptr;
  rime::Schema* schema = session->schema();
  if (!schema) return nullptr;
  rime::Config* config = schema->config();
  if (!config) return nullptr;

  const std::vector<std::string> namespaces = single_producer_namespaces(config);
  if (namespaces.size() != 1) return nullptr;
  const std::string name_space = namespaces.front();

  auto* component = rime::Dictionary::Require("dictionary");
  if (!component) return nullptr;
  rime::Dictionary* dictionary =
      component->Create(rime::Ticket(schema, name_space));
  if (!dictionary) return nullptr;
  if (!dictionary->Load() || !dictionary->loaded()) {
    delete dictionary;
    return nullptr;
  }

  rime::Syllabary syllabary;
  const auto& primary_table = dictionary->primary_table();
  if (!primary_table || !primary_table->IsOpen() ||
      !primary_table->GetSyllabary(&syllabary) || syllabary.empty()) {
    delete dictionary;
    return nullptr;
  }
  rime::Script script;
  for (const auto& token : syllabary) script.AddSyllable(token);

  auto algebra = config->GetList("speller/algebra");
  std::vector<std::string> algebra_rules;
  if (algebra) {
    for (size_t i = 0; i < algebra->size(); ++i) {
      rime::an<rime::ConfigValue> value = algebra->GetValueAt(i);
      if (value) algebra_rules.push_back(value->str());
    }
  }
  if (!algebra_rules.empty()) {
    rime::Projection projection;
    if (!projection.Load(algebra) || !projection.Apply(&script)) {
      // Load failure or "not modified": cannot prove the projection.
      delete dictionary;
      return nullptr;
    }
  }

  // Origin token -> final spelling -> properties.
  std::map<std::string, std::map<std::string, SpellingAggregate>> by_token;
  for (const auto& token : syllabary) by_token[token];  // include erased tokens
  for (const auto& entry : script) {
    const std::string& final_text = entry.first;
    if (final_text.empty()) continue;
    for (const rime::Spelling& spelling : entry.second) {
      const std::string& origin = spelling.str;
      SpellingAggregate& aggregate = by_token[origin][final_text];
      aggregate.present = true;
      aggregate.normal = aggregate.normal ||
          (spelling.properties.type == rime::kNormalSpelling);
      aggregate.correction = aggregate.correction && spelling.properties.is_correction;
    }
  }

  std::string alphabet;
  if (!config->GetString("speller/alphabet", &alphabet) || alphabet.empty())
    alphabet = "abcdefghijklmnopqrstuvwxyz";
  std::string dictionary_name;
  if (!config->GetString(name_space + "/dictionary", &dictionary_name) ||
      dictionary_name.empty()) {
    dictionary_name = dictionary->name();
  }
  delete dictionary;

  SourceFacts facts;
  facts.source_schema = schema->schema_id();
  facts.name_space = name_space;
  facts.dictionary = dictionary_name;
  facts.alphabet = alphabet;
  facts.algebra = algebra_rules;
  facts.producer_class = rime_identity::producer_class_name(
      rime_identity::single_producer(config).klass);
  config->GetString("keyboard_adapter_source", &facts.source_declaration);
  config->GetString("keyboard_rewrite_prefix", &facts.prefix_declaration);

  std::string json = "{";
  json += "\"source_schema\":\"" + json_escape(facts.source_schema) + "\",";
  json += "\"translator_namespace\":\"" + json_escape(facts.name_space) + "\",";
  json += "\"producer_class\":\"" + json_escape(facts.producer_class) + "\",";
  json += "\"dictionary\":\"" + json_escape(facts.dictionary) + "\",";
  json += "\"alphabet\":\"" + json_escape(facts.alphabet) + "\",";
  json += "\"separator\":\"" + json_escape(delimiter_for(config, name_space)) + "\",";
  json += "\"declaration\":\"" + json_escape(facts.source_declaration) + "\",";
  json += "\"prefix_declaration\":\"" + json_escape(facts.prefix_declaration) + "\",";
  json += "\"algebra\":";
  append_string_array(json, facts.algebra);
  json += ",\"syllables\":{";
  bool first_token = true;
  for (const auto& token_entry : by_token) {
    if (!first_token) json += ",";
    first_token = false;
    json += "\"" + json_escape(token_entry.first) + "\":[";
    bool first_spelling = true;
    for (const auto& spelling_entry : token_entry.second) {
      if (!first_spelling) json += ",";
      first_spelling = false;
      const SpellingAggregate& aggregate = spelling_entry.second;
      json += "{\"text\":\"" + json_escape(spelling_entry.first) + "\",";
      json += std::string("\"normal\":") + (aggregate.normal ? "true" : "false") + ",";
      json += std::string("\"correction\":") + (aggregate.correction ? "true" : "false") + "}";
    }
    json += "]";
  }
  json += "}}";

  char* result = static_cast<char*>(std::malloc(json.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, json.c_str(), json.size() + 1);
  return result;
}

extern "C" void rb_syllable_display_map_free(char* json) {
  std::free(json);
}
