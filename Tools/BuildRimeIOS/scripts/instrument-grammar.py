#!/usr/bin/env python3
"""Apply checked instrumentation to a fresh source COPY, never to upstream/cache checkouts."""
import shutil
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:])
if target.exists():
    raise SystemExit("Instrumented target already exists; use a fresh directory")
shutil.copytree(source, target, ignore=shutil.ignore_patterns('.git'))
def edit(name, changes):
    path = target / 'src' / name
    text = path.read_text()
    text = '#include "rime_grammar_diagnostics.h"\n#include "rime_grammar_bounds.h"\n#include <filesystem>\n#include <cstddef>\n' + text
    for old, new in changes:
        if text.count(old) != 1:
            raise SystemExit(f"Pinned source instrumentation mismatch: {name}: {old[:60]}")
        text = text.replace(old, new)
    path.write_text(text)
edit('gram_db.cc', [
    ('  metadata_ = Find<grammar::Metadata>(0);', '  // Find<T> checks only the starting offset; validate the complete mapped header.\n  if (file_size() < sizeof(grammar::Metadata)) { Close(); return false; }\n  metadata_ = Find<grammar::Metadata>(0);'),
    ('  if (IsOpen())', '  struct Trace { std::string path; bool ok = false; size_t entries = 0;\n    ~Trace() { rb_grammar_load_event(path.c_str(), ok, entries, ok ? "" : "GramDb::Load failed; see engine log"); }\n  } trace{file_path().string()};\n  trie_->clear();\n  if (IsOpen())'),
    ('  if (!OpenReadOnly()) {', '  std::error_code file_error;\n  auto bytes = std::filesystem::file_size(file_path(), file_error);\n  if (file_error || bytes < sizeof(grammar::Metadata)) {\n    LOG(ERROR) << "truncated or unreadable gram metadata"; return false;\n  }\n  bool opened = false;\n  try { opened = OpenReadOnly(); }\n  catch (const std::exception& e) { LOG(ERROR) << e.what(); return false; }\n  if (!opened) {'),
    ('  if (!boost::starts_with(string(metadata_->format), kGrammarFormatPrefix)) {', '  if (!std::memchr(metadata_->format, 0, grammar::Metadata::kFormatMaxLength) ||\n      string(metadata_->format) != kGrammarFormat) {'),
    ('  char* array = metadata_->double_array.get();', '  int32_t relative = 0;\n  std::memcpy(&relative, &metadata_->double_array, sizeof(relative));\n  int64_t offset = int64_t(offsetof(grammar::Metadata, double_array)) + relative;\n  if (relative == 0 || offset < int64_t(sizeof(grammar::Metadata)) ||\n      uint64_t(offset) > file_size() || metadata_->double_array_size == 0 ||\n      metadata_->double_array_size > (file_size() - size_t(offset)) / trie_->unit_size()) {\n    LOG(ERROR) << "gram double array lies outside mapped file"; Close(); return false;\n  }\n  char* array = address() + offset;'),
    ('  trie_->set_array(array, array_size);', '  if (offset % alignof(uint32_t) || !rb_grammar_validate_array(array, array_size)) {\n    LOG(ERROR) << "invalid Darts internal structure"; Close(); return false;\n  }\n  trie_->set_array(array, array_size);\n  trace.ok = true; trace.entries = array_size;'),
    ('''  size_t node_pos = 0;
  size_t key_pos = 0;
  trie_->traverse(context.c_str(), node_pos, key_pos);
  if (key_pos == context.length()) {
    return trie_->commonPrefixSearch(
        word.c_str(), results, kMaxResults, 0, node_pos);
  }
  return 0;''', '''  int count = rb_grammar_bounded_lookup(trie_->array(), trie_->size(),
      context.c_str(), word.c_str(), results, kMaxResults);
  if (rb_grammar_diagnostics_enabled()) rb_grammar_lookup_event(count);
  return count;''')
])
edit('octagram.cc', [
    ('    db_ = component->GetDb(language);', '    db_ = component->GetDb(language);\n    if (db_) rb_grammar_instance_attach(this, config, db_->file_path().string().c_str());'),
    ('Octagram::~Octagram() {}', 'Octagram::~Octagram() { rb_grammar_instance_detach(this); }'),
    ('  return result;\n}', '  if (rb_grammar_diagnostics_enabled())\n    rb_grammar_query_event(db_->file_path().string().c_str(), context.c_str(), word.c_str(), result, is_rear);\n  return result;\n}')])
