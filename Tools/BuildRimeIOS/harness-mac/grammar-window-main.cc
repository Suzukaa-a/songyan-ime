// Development-only focused probe for the bounded/lazy grammar validation
// (Tools/BuildRimeIOS/src/rime_grammar_bounds.h).
//
// Self-contained: includes only the validation header plus libc/libmman, so it
// compiles and runs without librime/glog. It proves:
//   1. predicate parity — a valid array is accepted and the historic corrupt
//      classes (root value/label, offset out of range, leaf tag, shape) are still
//      rejected when they live inside the reachable window;
//   2. bounded lookup — hostile/truncated input can only ever miss, never read
//      out of the mapping (run the ASan variant to prove the memory claim);
//   3. residency — validating a huge (sparse) array faults only a handful of
//      pages, unlike a full linear scan which faults every page.
#include "rime_grammar_bounds.h"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>
#include <string>
#include <filesystem>
#include <algorithm>
#include <chrono>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach.h>

using u32 = uint32_t;
static const size_t kUnit = 4;
static int failures = 0;

static void check(bool ok, const std::string& what) {
  if (!ok) { std::cerr << "FAIL: " << what << "\n"; ++failures; }
}

static u32 make_unit(u32 label, size_t offset, bool has_leaf, bool is_value, u32 value) {
  u32 u = 0;
  if (is_value) u |= 0x80000000u;
  if (has_leaf) u |= 0x100u;             // bit8
  u |= static_cast<u32>(offset) << 10;   // offset occupies bits 10+
  u |= (label & 0xffu);
  if (is_value) u |= (value & 0x7fffffffu);
  return u;
}

// A Darts-compatible array for key "ab" (value 42). The root block is base 0, so
// every unit in [0,255] is reachable and can be used to plant corruption.
static std::vector<u32> synthetic_valid(size_t count = 256) {
  std::vector<u32> a(count, 0u);
  a[0] = make_unit(0x00u, 0u, false, false, 0);      // root, base 0
  a[5] = make_unit(0x61u, 0u, false, false, 0);      // 'a' -> node 1|... (unused)
  a[1] = make_unit(0x62u, 9u, true, false, 0);       // 'b', has_leaf, anchor 1^9=8
  a[8] = make_unit(0x00u, 0u, false, true, 42u);     // value leaf 42
  return a;
}

// The historic validator, kept verbatim for a like-for-like fault comparison.
static bool legacy_full_scan(const void* data, size_t count) {
  if (!data || count < 256 || count % 256 || count > UINT32_MAX) return false;
  auto read = [data](size_t i) { u32 u; std::memcpy(&u, static_cast<const char*>(data) + i * 4, 4); return u; };
  if ((read(0) & (0x80000000u | 255u)) != 0) return false;
  for (size_t i = 0; i < count; ++i) {
    u32 u = read(i);
    if (u & 0x80000000u) continue;
    size_t base = i ^ ((u >> 10) << ((u & 512u) >> 6));
    if ((base | size_t(255)) >= count) return false;
    if ((u & 256u) && !(read(base) & 0x80000000u)) return false;
  }
  return true;
}

// Minor+major page faults attributable to this process.
static uint64_t page_faults() {
  struct rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
  return static_cast<uint64_t>(usage.ru_minflt) + static_cast<uint64_t>(usage.ru_majflt);
}

static uint64_t phys_footprint() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self_, TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return 0;
  return info.phys_footprint;
}

// Resident size (RSS): the metric the real-device ~300MB observation was taken
// with. phys_footprint and RSS are both reported because iOS jetsam accounting
// and `ps`-style RSS differ for clean file-backed mmap pages.
static uint64_t resident_size() {
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self_, MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return 0;
  return info.resident_size;
}

struct Measurement { uint64_t faults; uint64_t footprint; uint64_t rss; };
// Observable sink so the optimiser cannot dead-code-eliminate a pure validation
// call whose result would otherwise be unused (which would make the residency
// comparison meaningless).
static volatile bool g_sink = false;
template <class F>
static Measurement measure(F&& f, bool& ok) {
  uint64_t f0 = page_faults(), m0 = phys_footprint(), r0 = resident_size();
  ok = f();
  g_sink = ok;
  return { page_faults() - f0, phys_footprint() - m0, resident_size() - r0 };
}

int main(int argc, char** argv) {
  std::filesystem::path root = argc > 1 ? argv[1]
                                        : std::filesystem::temp_directory_path() / "grammar-window";
  std::filesystem::create_directories(root);
  std::filesystem::path real_model = argc > 2 ? argv[2] : std::filesystem::path{};

  // ---- 1. predicate parity ----
  auto good = synthetic_valid();
  check(good[8] == make_unit(0, 0, false, true, 42), "fixture leaf encoding");
  check(rb_grammar_validate_array(good.data(), good.size()),
        "valid array accepted by bounded validator");
  check(rb_grammar_validate_reachable(good.data(), good.size(), SIZE_MAX),
        "oversized validation budget is clamped to fixed storage");
  check(legacy_full_scan(good.data(), good.size()),
        "valid array accepted by legacy validator (parity)");
  check(rb_grammar_read_unit(good.data(), 8) == good[8], "unit read round-trips");

  { auto bad = good; bad[0] |= 0x80000000u;
    check(!rb_grammar_validate_array(bad.data(), bad.size()), "root value unit rejected"); }
  { auto bad = good; bad[0] = (bad[0] & ~0xffu) | 0x01u;
    check(!rb_grammar_validate_array(bad.data(), bad.size()), "root non-zero label rejected"); }
  { std::vector<u32> small(1, 1024u);
    check(!rb_grammar_validate_array(small.data(), small.size()), "sub-block array rejected"); }
  { std::vector<u32> mis(300, 0u);
    check(!rb_grammar_validate_array(mis.data(), mis.size()), "non-multiple-of-256 rejected"); }
  { auto bad = good; bad[5] = (bad[5] & 0x3ffu) | 0x7ffffc00u;   // bit31 clear, offset huge
    check(!rb_grammar_validate_array(bad.data(), bad.size()), "reachable bad offset rejected"); }
  { auto bad = good; bad[8] = 0u;
    check(!rb_grammar_validate_array(bad.data(), bad.size()), "reachable bad leaf tag rejected"); }
  { // historic corrupt classes, all planted on reachable units
    std::vector<std::vector<u32>> cases;
    { auto b = good; b[7]  = (b[7]  & 0x3ffu) | 0x7ffffc00u; cases.push_back(b); }
    { auto b = good; b[1]  = (b[1]  & 0x3ffu) | 0x7ffffc00u; cases.push_back(b); }
    { auto b = good; b[100] = (b[100] & 0x3ffu) | 0x7ffffc00u; cases.push_back(b); }
    { auto b = good; b[8] = 0u; cases.push_back(b); }
    for (size_t i = 0; i < cases.size(); ++i) {
      check(!rb_grammar_validate_array(cases[i].data(), cases[i].size()),
            "historic corrupt class " + std::to_string(i) + " rejected");
    }
  }

  // ---- 2. bounded lookup never over-reads and only misses on hostile input ----
  {
    struct Match { int value; std::size_t length; };
    Match results[8];
    auto hostile = good;
    hostile[0] = (hostile[0] & 0x3ffu) | 0x7ffffc00u;
    int n = rb_grammar_bounded_lookup(hostile.data(), hostile.size(), "abc", "abcdef", results, 8);
    check(n >= 0 && n <= 8, "bounded lookup returns a bounded count on hostile input");
    int m = rb_grammar_bounded_lookup(good.data(), 256, "zzzz", "yyyy", results, 8);
    check(m == 0, "bounded lookup misses on absent key");
  }

  // ---- 3. optional real 420MB grammar model (measured first, while cold) ----
  if (!real_model.empty() && std::filesystem::exists(real_model)) {
    const size_t offptr_off = 32 + 4 + 4;   // see GramDb::Load metadata layout below
    size_t file_bytes = 0;
    struct stat st{};
    {
      int fd = open(real_model.c_str(), O_RDONLY);
      if (fd >= 0 && fstat(fd, &st) == 0) { file_bytes = static_cast<size_t>(st.st_size); }
      if (fd >= 0) close(fd);
    }
    if (file_bytes == 0) {
      std::cerr << "realModel: stat failed\n";
    } else {
      // Mirror GramDb::Load array offset resolution: metadata is
      // {char format[32]; uint32_t db_checksum; uint32_t double_array_size;
      //  OffsetPtr<char> double_array;} and OffsetPtr is a relative int32.
      auto measure_model = [&](const char* label, bool use_bounded) {
        int fd = open(real_model.c_str(), O_RDONLY);
        check(fd >= 0, std::string(label) + ": opened");
        if (fd < 0) return;
        void* map = mmap(nullptr, file_bytes, PROT_READ, MAP_PRIVATE, fd, 0);
        if (map == MAP_FAILED) { close(fd); return; }
        size_t count = 0; bool valid = false;
        {
          int32_t relative = 0;
          std::memcpy(&relative, static_cast<const char*>(map) + offptr_off, sizeof(relative));
          int64_t offset = static_cast<int64_t>(offptr_off) + relative;
          check(relative != 0 && offset > 0 && static_cast<size_t>(offset) < file_bytes,
                std::string(label) + ": array offset in range");
          if (relative != 0 && offset > 0 && static_cast<size_t>(offset) < file_bytes) {
            const char* array = static_cast<const char*>(map) + offset;
            count = (file_bytes - static_cast<size_t>(offset)) / kUnit;
            auto t0 = std::chrono::steady_clock::now();
            Measurement m = measure([&] {
              return use_bounded ? rb_grammar_validate_array(array, count)
                                 : legacy_full_scan(array, count);
            }, valid);
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - t0).count();
            // `bytes*` fields are page-granular: compare the residency claim that
            // actually matters to iOS jetsam (footprint), not raw fault counts.
            std::cout << label << ": bytes=" << file_bytes << " units=" << count
                      << " valid=" << valid << " ms=" << ms
                      << " faultsDelta=" << m.faults
                      << " footprintDelta=" << m.footprint
                      << " rssDelta=" << m.rss << "\n";
          }
        }
        munmap(map, file_bytes);
        close(fd);
        (void)count;
      };
      measure_model("realModelBounded", true);
      measure_model("realModelLegacy", false);
    }
  }

  // ---- 4. residency on a huge sparse array (cold, synthetic) ----
  const size_t units = (512u * 1024u * 1024u) / kUnit;  // 512 MiB / 4
  const size_t big = units & ~size_t(255);
  const size_t bytes = big * kUnit;
  std::filesystem::path big_path = root / "large-window.bin";
  {
    int fd = open(big_path.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0644);
    check(fd >= 0, "large sparse file created");
    if (fd >= 0) {
      check(ftruncate(fd, static_cast<off_t>(bytes)) == 0, "large sparse file sized");
      const size_t final_block = big - 256;
      u32 root_unit = make_unit(0, final_block / 256u, false, false, 0);
      check(pwrite(fd, &root_unit, 4, 0) == 4, "root unit written");
      std::vector<u32> last(256, 0u);  // all zero: non-value, offset 0, anchor in range
      check(pwrite(fd, last.data(), 256 * kUnit,
                   static_cast<off_t>(final_block * kUnit)) == 256 * kUnit,
            "final block written");
      close(fd);
    }
  }
  {
    int fd = open(big_path.c_str(), O_RDONLY);
    check(fd >= 0, "large file reopened");
    Measurement bounded{};
    bool bounded_ok = false;
    if (fd >= 0) {
      void* map = mmap(nullptr, bytes, PROT_READ, MAP_PRIVATE, fd, 0);
      check(map != MAP_FAILED, "large file mapped");
      if (map != MAP_FAILED) {
        bounded = measure([&] {
          return rb_grammar_validate_array(static_cast<const char*>(map), bytes / kUnit);
        }, bounded_ok);
        std::cout << "bounded: valid=" << bounded_ok << " faultsDelta=" << bounded.faults
                  << " footprintDelta=" << bounded.footprint << " rssDelta=" << bounded.rss << "\n";
        check(bounded_ok, "large crafted array accepted by bounded validator");
        check(bounded.faults <= 64, "bounded validator faults only a few pages");
        munmap(map, bytes);
      }
      // Fresh mapping so the legacy scan starts from the same cold state.
      void* map2 = mmap(nullptr, bytes, PROT_READ, MAP_PRIVATE, fd, 0);
      if (map2 != MAP_FAILED) {
        bool ignored = false;
        Measurement legacy = measure([&] {
          return legacy_full_scan(static_cast<const char*>(map2), bytes / kUnit);
        }, ignored);
        std::cout << "legacy : faultsDelta=" << legacy.faults
                  << " footprintDelta=" << legacy.footprint << " rssDelta=" << legacy.rss << "\n";
        check(legacy.faults > bounded.faults,
              "legacy full scan faults far more pages than the bounded validator");
        munmap(map2, bytes);
      }
      close(fd);
    }
  }

  if (failures == 0) std::cout << "PASS grammar window bounds\n";
  return failures == 0 ? 0 : 1;
}
