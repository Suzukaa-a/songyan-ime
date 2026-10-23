#pragma once
#include <cstdint>
#include <cstring>
#include <cstddef>

// Darts-clone DoubleArrayUnit: bit31=value, bit8=has_leaf,
// offset=(unit>>10)<<((unit&512)>>6). Builder allocates 256-unit blocks;
// unused cells have offset zero. memcpy avoids alignment assumptions.
//
// ---------------------------------------------------------------------------
// Bounded / lazy structural validation (2026-09-23)
// ---------------------------------------------------------------------------
// The previous `rb_grammar_validate_array` linearly scanned EVERY unit of the
// double array at load time. For the 420,339,756-byte wanxiang grammar model
// (105,084,928 units) that touched every mapped page, driving the keyboard
// extension's phys_footprint far past its jetsam budget, so iOS reclaimed the
// process on essentially every dismissal (the user-visible "complete reload
// every time, no resume").
//
// The eager scan was never required for memory safety: `rb_grammar_bounded_lookup`
// already performs a bounds-checked read for every node, transition and leaf it
// touches, so a hostile offset can only ever produce a *miss*, never an
// out-of-bounds access. What the full scan bought was "reject a structurally
// corrupt file at load instead of silently behaving as a non-matching model".
//
// This header preserves that property with an O(1)-touched-byte budget:
//   1. O(1) header/root checks (count shape; root must be a non-value node with
//      label 0);
//   2. a bounded breadth-first walk of the REACHABLE node graph starting at the
//      root. Each expanded node reads the 256-unit block its offset derives, so
//      the walk validates whole Darts blocks contiguously (one cache/page line
//      at a time) instead of the whole file.
//
// Hard bound: at most `rb_grammar_validate_max_blocks` blocks are read, i.e. at
// most `max_blocks * 256 * 4` bytes (default 16 blocks = 16 KiB) regardless of
// model size. Units outside that reachable window are validated lazily by the
// bounds-checked lookup before any use, so runtime accesses stay bounded and a
// truncated/corrupt model can neither read out of the mapping nor spin. A
// corruption deeper than the window simply fails to match; it can never corrupt
// memory.

// Maximum number of derived blocks read during load-time validation. Constant
// and independent of model size (16 blocks = 16 KiB = a handful of pages).
inline constexpr size_t rb_grammar_validate_max_blocks = 16;
// Bounded frontier of pending blocks; a hostile fan-out cannot grow it without
// bound (values beyond the cap are validated lazily on first access instead).
inline constexpr size_t rb_grammar_validate_frontier = 64;

// Accessors (memcpy avoids alignment assumptions).
inline uint32_t rb_grammar_read_unit(const void* data, size_t i) {
  uint32_t u;
  std::memcpy(&u, static_cast<const char*>(data) + i * 4, 4);
  return u;
}
inline size_t rb_grammar_unit_offset(uint32_t u) {
  return static_cast<size_t>((u >> 10) << ((u & 512u) >> 6));
}

// O(1) shape + root checks. Never scans the array.
inline bool rb_grammar_check_root(const void* data, size_t count) {
  if (!data || count < 256 || count % 256 || count > UINT32_MAX) return false;
  uint32_t root = rb_grammar_read_unit(data, 0);
  // Root must be a non-value node (bit31 clear) whose label is 0 (the builder
  // always reserves index 0 as the empty-context root).
  if (root & 0x80000000u) return false;
  if ((root & 255u) != 0) return false;
  return true;
}

// Bounded reachable-closure validation over Darts blocks.
//
// Returns true when every block reachable within `max_blocks` is structurally
// sound (each non-value unit's derived anchor is inside the array and, when
// `has_leaf` is set, its derived leaf is a value unit). Returns false on the
// first *provable* defect found inside the window.
//
// Reads at most `max_blocks` blocks (contiguous 256-unit windows) and uses only
// fixed stack storage; memory touched is independent of the model size.
//
// `noinline` is deliberate: it keeps the bounded walker a distinct symbol in the
// shipped archive so the bounded design stays verifiable at the binary level
// (see Tests/ProjectStructure/test_grammar_bounds_bounded_contract.py).
__attribute__((noinline))
inline bool rb_grammar_validate_reachable(
    const void* data, size_t count,
    size_t max_blocks = rb_grammar_validate_max_blocks) {
  if (!rb_grammar_check_root(data, count)) return false;
  // The visited set below has a compile-time capacity. Keep the public test
  // override safe even when a caller requests a larger window.
  if (max_blocks > rb_grammar_validate_max_blocks) {
    max_blocks = rb_grammar_validate_max_blocks;
  }
  if (max_blocks == 0) return true;

  auto read = [data, count](size_t i, uint32_t& u) {
    if (!data || i >= count) return false;
    std::memcpy(&u, static_cast<const char*>(data) + i * 4, 4);
    return true;
  };

  // Pending block bases (anchor values) and the bounded set of visited bases.
  size_t pending[rb_grammar_validate_frontier];
  size_t visited[rb_grammar_validate_max_blocks];
  size_t head = 0, tail = 0, visited_count = 0, blocks_read = 0;

  uint32_t root;
  if (!read(0, root)) return false;
  pending[tail++] = rb_grammar_unit_offset(root);

  while (head < tail) {
    if (blocks_read >= max_blocks) break;  // window reached: tail is lazy-validated
    const size_t base = pending[head++];
    if ((base | size_t(255)) >= count) return false;  // derived block out of range
    bool seen = false;
    for (size_t v = 0; v < visited_count; ++v) {
      if (visited[v] == base) { seen = true; break; }
    }
    if (seen) continue;
    visited[visited_count++] = base;
    ++blocks_read;
    // Validate the 256-unit derived block contiguously. Every unit in a Darts
    // block is a potential node, so the per-unit checks below match a full
    // linear scan restricted to reachable blocks.
    for (size_t i = 0; i < 256; ++i) {
      const size_t node = base ^ i;
      uint32_t u;
      if (!read(node, u)) return false;
      if (u & 0x80000000u) continue;  // value unit: no derived block
      const size_t anchor = node ^ rb_grammar_unit_offset(u);
      if ((anchor | size_t(255)) >= count) return false;
      if (u & 256u) {                 // has_leaf: derived leaf must be a value
        uint32_t leaf;
        if (!read(anchor, leaf)) return false;
        if (!(leaf & 0x80000000u)) return false;
      }
      // Follow the derived block, subject to the bounded frontier.
      if (tail < rb_grammar_validate_frontier) pending[tail++] = anchor;
    }
  }
  return true;
}

// Stable name used by the instrumented `gram_db.cc` and other call sites; performs
// the bounded reachable check. `noinline` keeps both this entry point and the
// bounded walker as distinct symbols in the shipped archive.
__attribute__((noinline))
inline bool rb_grammar_validate_array(const void* data, size_t count) {
  return rb_grammar_validate_reachable(data, count);
}

// Same XOR traversal/prefix semantics as upstream darts.h:489/441, with
// checked reads for every node, resumed prefix, transition and leaf.
template<class Match>
int rb_grammar_bounded_lookup(const void* data, size_t count,
                              const char* context, const char* word,
                              Match* results, size_t capacity) {
  auto read = [data, count](size_t i, uint32_t& u) {
    if (!data || i >= count) return false;
    std::memcpy(&u, static_cast<const char*>(data) + i * 4, 4); return true;
  };
  auto offset = [](uint32_t u) { return (u >> 10) << ((u & 512u) >> 6); };
  size_t node = 0;
  uint32_t u;
  if (!read(node, u)) return 0;
  for (auto p = reinterpret_cast<const unsigned char*>(context); *p; ++p) {
    node ^= offset(u) ^ *p;
    if (!read(node, u) || (u & 0x800000ffu) != *p) return 0;
  }
  size_t found = 0;
  for (size_t i = 0; word[i]; ++i) {
    auto label = static_cast<unsigned char>(word[i]);
    node ^= offset(u) ^ label;
    if (!read(node, u)) return 0;
    if ((u & 0x800000ffu) != label) break;
    if (u & 256u) {
      uint32_t leaf;
      if (!read(node ^ offset(u), leaf) || !(leaf & 0x80000000u)) return 0;
      // GramDb callers iterate the returned count over their fixed buffer.
      // Unlike Darts' total-match count, never return more than was written.
      if (found < capacity) results[found++] = {static_cast<int>(leaf & 0x7fffffffu), i + 1};
    }
  }
  return static_cast<int>(found);
}
