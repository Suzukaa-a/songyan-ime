#include "rime_grammar_diagnostics.h"
#include <mutex>
#include <string>
#include <vector>
#include <sstream>
#include <iomanip>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <atomic>
#include <algorithm>
#include <filesystem>
#include <rime/service.h>
#include <rime/engine.h>
#include <rime/schema.h>
#include <rime/registry.h>

namespace {
std::mutex lock;
std::atomic<bool> enabled{false};
struct Instance { const void* instance; const void* config; std::string path; };
std::vector<Instance> instances;
unsigned long long queries = 0, lookups = 0, hits = 0;
struct Load { std::string path, error; bool success; size_t entries; };
struct Query { std::string path, context, word; double score; bool rear; };
std::vector<Load> loads;
std::vector<Query> samples;
std::string quote(const std::string& s) {
  std::ostringstream o; o << '"';
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') o << '\\' << c;
    else if (c < 32) o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << (unsigned)c << std::dec;
    else o << c;
  }
  o << '"'; return o.str();
}
}
extern "C" void rb_grammar_diagnostics_reset(int value) {
  std::lock_guard<std::mutex> guard(lock);
  enabled = value != 0; queries = lookups = hits = 0; loads.clear(); samples.clear();
}
extern "C" void rb_grammar_load_event(const char* path, int success, size_t entries, const char* error) {
  std::lock_guard<std::mutex> guard(lock);
  // One outcome per model path, matching the lifetime of Octagram's own language cache.
  // Do not evict a successful outcome while the native component still owns that mapping.
  for (auto& load : loads) {
    if (load.path == (path ? path : "")) { load = {path ? path : "", error ? error : "", success != 0, entries}; return; }
  }
  loads.push_back({path ? path : "", error ? error : "", success != 0, entries});
}
extern "C" int rb_grammar_diagnostics_enabled(void) { return enabled.load(std::memory_order_relaxed); }
extern "C" int rb_component_available(const char* name) {
  return name && rime::Registry::instance().Find(name) != nullptr;
}
extern "C" void rb_grammar_instance_attach(const void* instance, const void* config, const char* path) {
  std::error_code error;
  auto canonical = std::filesystem::weakly_canonical(path, error);
  if (error) return;
  std::lock_guard<std::mutex> guard(lock);
  instances.push_back({instance, config, canonical.string()});
}
extern "C" void rb_grammar_instance_detach(const void* instance) {
  std::lock_guard<std::mutex> guard(lock);
  instances.erase(std::remove_if(instances.begin(), instances.end(), [instance](const Instance& i) { return i.instance == instance; }), instances.end());
}
// Caller serializes with session selection/destruction (RimeEngine queue).
extern "C" int rb_grammar_session_loaded(size_t session, const char* path) {
  auto s = rime::Service::instance().GetSession(session);
  if (!s || !s->schema() || !path) return 0;
  auto config = s->schema()->config();
  std::error_code error;
  auto canonical = std::filesystem::weakly_canonical(path, error).string();
  if (error) return 0;
  std::lock_guard<std::mutex> guard(lock);
  for (const auto& i : instances) if (i.config == config && i.path == canonical) return 1;
  return 0;
}
extern "C" void rb_grammar_lookup_event(int matches) {
  if (!rb_grammar_diagnostics_enabled()) return;
  std::lock_guard<std::mutex> guard(lock);
  if (!enabled) return;
  ++lookups; if (matches > 0) hits += (unsigned)matches;
}
extern "C" void rb_grammar_query_event(const char* path, const char* context, const char* word, double score, int rear) {
  if (!rb_grammar_diagnostics_enabled()) return;
  std::lock_guard<std::mutex> guard(lock);
  if (!enabled) return;
  ++queries;
  if (samples.size() == 16) samples.erase(samples.begin());
  samples.push_back({path, context, word, score, rear != 0});
}
extern "C" char* rb_grammar_diagnostics_json(void) {
  std::lock_guard<std::mutex> guard(lock);
  std::ostringstream o;
  o << "{\"recording\":" << (enabled ? "true" : "false")
    << ",\"queryCount\":" << queries << ",\"lookupCount\":" << lookups << ",\"matchCount\":" << hits << ",\"loads\":[";
  bool comma = false;
  for (const auto& l : loads) {
    if (comma) o << ','; comma = true;
    o << "{\"path\":" << quote(l.path) << ",\"success\":" << (l.success ? "true" : "false")
      << ",\"entries\":" << l.entries << ",\"error\":" << quote(l.error) << '}';
  }
  o << "],\"samples\":["; comma = false;
  for (const auto& q : samples) {
    if (comma) o << ','; comma = true;
    o << "{\"path\":" << quote(q.path) << ",\"context\":" << quote(q.context) << ",\"word\":" << quote(q.word)
      << ",\"score\":";
    if (std::isfinite(q.score)) o << std::setprecision(17) << q.score;
    else o << "null";
    o << ",\"rear\":" << (q.rear ? "true" : "false") << '}';
  }
  o << "]}";
  const auto text = o.str();
  auto result = static_cast<char*>(std::malloc(text.size() + 1));
  if (result) std::memcpy(result, text.c_str(), text.size() + 1);
  return result;
}
