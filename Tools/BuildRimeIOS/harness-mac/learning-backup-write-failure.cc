#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <csignal>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <rime/dict/db_utils.h>
#include <rime/dict/table_db.h>
#include <rime/dict/tsv.h>
#include <rime/dict/user_db.h>

namespace fs = std::filesystem;
using Rows = std::vector<std::pair<std::string, std::string>>;

#ifndef LEARNING_IO_INTERPOSER
static void check(bool value, const char* label) {
  if (!value) throw std::runtime_error(label);
  std::cout << "PASS " << label << std::endl;
}
static std::string contents(const fs::path& file) {
  std::ifstream input(file, std::ios::binary);
  check(input.is_open(), "read controlled test output");
  return std::string(std::istreambuf_iterator<char>(input), {});
}

// Only the storage boundary is a fixture. DbSource, formatters, TsvWriter,
// UserDbHelper::UniformBackup and TextDb::SaveToFile are real pinned sources.
class FixtureAccessor : public rime::DbAccessor {
 public:
  FixtureAccessor(Rows rows, int fail_after) : rows_(std::move(rows)), fail_after_(fail_after) {}
  bool Reset() override { position_ = 0; error_ = false; return !exhausted(); }
  bool Jump(const rime::string&) override { return Reset(); }
  bool GetNextRecord(rime::string* key, rime::string* value) override {
    if (fail_after_ >= 0 && position_ == static_cast<size_t>(fail_after_)) {
      error_ = true;
      return false;
    }
    if (exhausted()) return false;
    *key = rows_[position_].first;
    *value = rows_[position_++].second;
    return true;
  }
  bool exhausted() override { return position_ == rows_.size(); }
  bool HasError() const
#ifdef LEARNING_IO_CANDIDATE
      override
#endif
  { return error_; }
 private:
  Rows rows_;
  int fail_after_;
  size_t position_ = 0;
  bool error_ = false;
};

class FixtureDb : public rime::Db {
 public:
  explicit FixtureDb(const fs::path& root) : Db(rime::path(root / "source.userdb"), "learning_failures") {
    metadata = {{"/db_name", "learning_failures"}, {"/db_type", "userdb"},
                {"/rime_version", "1.17.0"}, {"/tick", "0"}, {"/user_id", "test-source"}};
    data = {{"a \tpositive", "c=1 d=1 t=0"}, {"b \tzero", "c=0 d=0 t=0"},
            {"z \tdeleted", "c=-2 d=0.5 t=0"}};
    loaded_ = true;
  }
  bool Open() override { return true; }
  bool OpenReadOnly() override { return true; }
  bool Close() override { return true; }
  bool Backup(const rime::path& file) override { return rime::UserDbHelper(this).UniformBackup(file); }
  bool Restore(const rime::path&) override { return false; }
  bool MetaFetch(const rime::string& key, rime::string* value) override {
    for (const auto& row : metadata) if (row.first == key) { *value = row.second; return true; }
    return false;
  }
  bool MetaUpdate(const rime::string&, const rime::string&) override { return false; }
  rime::an<rime::DbAccessor> QueryMetadata() override {
    return std::make_shared<FixtureAccessor>(metadata, fail_metadata_after);
  }
  rime::an<rime::DbAccessor> QueryAll() override {
    return std::make_shared<FixtureAccessor>(data, fail_data_after);
  }
  rime::an<rime::DbAccessor> Query(const rime::string&) override { return QueryAll(); }
  bool Fetch(const rime::string&, rime::string*) override { return false; }
  bool Update(const rime::string&, const rime::string&) override { return false; }
  bool Erase(const rime::string&) override { return false; }
  Rows metadata, data;
  int fail_metadata_after = -1, fail_data_after = -1;
};

#endif

#ifdef LEARNING_IO_INTERPOSER
static fs::path fault_file;
static bool fail_close = false, fail_flush = false, injected = false;
static bool matches(FILE* file) {
  if (fault_file.empty()) return false;
  struct stat actual{}, target{};
  return fstat(fileno(file), &actual) == 0 && stat(fault_file.c_str(), &target) == 0 &&
         actual.st_dev == target.st_dev && actual.st_ino == target.st_ino;
}
extern "C" int controlled_close(FILE* file) {
  bool fail = fail_close && matches(file);
  int result = fclose(file);
  if (fail) { injected = true; errno = EIO; return EOF; }
  return result;
}
extern "C" int controlled_flush(FILE* file) {
  if (file && fail_flush && matches(file)) { injected = true; errno = EIO; return EOF; }
  return fflush(file);
}
#ifdef __APPLE__
#define INTERPOSE(replacement, original) \
  __attribute__((used)) static const struct { const void* replacement; const void* original; } \
  interpose_##original __attribute__((section("__DATA,__interpose"))) = { \
      reinterpret_cast<const void*>(replacement), reinterpret_cast<const void*>(original) }
INTERPOSE(controlled_close, fclose);
INTERPOSE(controlled_flush, fflush);
#else
#error This controlled fault-injection harness requires macOS dyld interposition.
#endif
extern "C" void learning_fault_configure(const char* file, int mode) {
  fault_file = fs::path(file);
  fail_flush = mode == 1;
  fail_close = mode == 2;
  injected = false;
}
extern "C" int learning_fault_was_injected() { return injected ? 1 : 0; }
#else
extern "C" void learning_fault_configure(const char*, int);
extern "C" int learning_fault_was_injected();

static size_t body_rows(const std::string& text) {
  std::istringstream input(text);
  std::string line;
  size_t count = 0;
  while (std::getline(input, line)) if (!line.empty() && line[0] != '#') ++count;
  return count;
}

int main(int argc, char** argv) {
  try {
    check(argc == 3, "mode and fresh scratch directory supplied");
    const bool candidate = std::string(argv[1]) == "candidate";
    check(candidate || std::string(argv[1]) == "baseline", "known build mode");
    const fs::path repository = fs::path(__FILE__).parent_path().parent_path().parent_path().parent_path();
    const fs::path allowed = fs::canonical(repository / ".scratch/learning-backup-io-candidate");
    const fs::path root = fs::absolute(argv[2]).lexically_normal();
    check(root.string().find(allowed.string() + "/") == 0 &&
          fs::weakly_canonical(root) == root && !fs::exists(root), "only a verified fresh scratch subtree");
    check(fs::create_directory(root), "exclusive controlled run directory created");
    FixtureDb db(root);
    const fs::path full = root / "full.userdb.txt";
    check(db.Backup(rime::path(full)), "real UniformBackup writes all three learning rows");
    const auto complete = contents(full);
    check(body_rows(complete) == 3 && complete.find("c=-2") != std::string::npos,
          "raw backup retains positive zero and deleted values");
    const fs::path exported = root / "export.tsv";
    rime::TsvWriter table_writer(rime::path(exported), rime::TableDb::format.formatter);
    rime::DbSource table_source(&db);
    check((table_writer << table_source) == 2, "real table formatter counts positive and zero but not deleted");
    check(body_rows(contents(exported)) == 2, "export deliberately filters deleted rows");

    FixtureDb empty(root);
    empty.data.clear();
    const fs::path empty_file = root / "empty.userdb.txt";
    check(empty.Backup(rime::path(empty_file)), "empty raw user dictionary backup succeeds");
    const auto empty_text = contents(empty_file);
    check(body_rows(empty_text) == 0 && empty_text.find("#@/tick\t0\n") != std::string::npos &&
          empty_text.find("#@/db_type\tuserdb\n") != std::string::npos,
          "empty backup preserves genuine metadata without fabricating rows");

    const fs::path bad_open = root / "open.userdb.txt";
    check(fs::create_directory(bad_open), "open-failure target is an owned directory");
    check(db.Backup(rime::path(bad_open)) == !candidate, "open failure follows expected real UniformBackup result");

    const size_t boundary = complete.find("z \tdeleted\t");
    check(boundary != std::string::npos && boundary > 0 && complete[boundary - 1] == '\n',
          "failure boundary is exactly after complete positive and zero rows");
    const fs::path limited = root / "limited.userdb.txt";
    pid_t child = fork();
    check(child >= 0, "isolated file-size fault child created");
    if (child == 0) {
      signal(SIGXFSZ, SIG_IGN);
      struct rlimit limit{static_cast<rlim_t>(boundary), static_cast<rlim_t>(boundary)};
      if (setrlimit(RLIMIT_FSIZE, &limit) != 0) _exit(30);
      bool result = db.Backup(rime::path(limited));
      std::cout << "BOUNDARY UniformBackup=" << result << " max_bytes=" << boundary << std::endl;
      _exit(result == !candidate ? 0 : 31);
    }
    int status = 0;
    check(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
          "complete-line write failure follows expected real UniformBackup result");
    const auto prefix = contents(limited);
    check(prefix.size() == boundary && prefix == complete.substr(0, boundary) &&
          body_rows(prefix) == 2 && prefix.find("c=-2") == std::string::npos,
          "failed output is an intact metadata-and-row prefix missing only deleted learning");
    std::cout << "PREFIX valid_complete_lines=1 rows=2 source_rows=3 export_count=2" << std::endl;

    for (bool close : {false, true}) {
      const auto file = root / (close ? "close.userdb.txt" : "flush.userdb.txt");
      learning_fault_configure(file.c_str(), close ? 2 : 1);
      bool result = db.Backup(rime::path(file));
      const bool was_injected = learning_fault_was_injected() != 0;
      learning_fault_configure("", 0);
      check(was_injected, close ? "controlled close failure reached real stream" : "controlled flush failure reached real stream");
      check(result == !candidate, close ? "close failure propagates" : "flush failure propagates");
    }

    db.fail_data_after = 2;
    check(db.Backup(rime::path(root / "cursor.userdb.txt")) == !candidate,
          "source data iteration error is not mistaken for normal EOF");
    db.fail_data_after = -1;
    db.fail_metadata_after = 3;
    check(db.Backup(rime::path(root / "metadata-error.userdb.txt")) == !candidate,
          "source metadata iteration error propagates");
    db.fail_metadata_after = -1;
    db.data.emplace_back("invalid key without tab", "c=1 d=1 t=0");
    check(db.Backup(rime::path(root / "formatter.userdb.txt")) == !candidate,
          "raw backup formatter rejection is not silently omitted");
    db.data.pop_back();

    rime::TableDb table(rime::path(root / "table-source.txt"), "table_fixture");
    check(table.Open(), "real TableDb fixture opens");
    check(table.Update("a \tpositive", "c=1 d=1 t=0"), "real table fixture populated");
    check(table.Backup(rime::path(bad_open)) == !candidate,
          "real TextDb SaveToFile propagates output failure");
    std::cout << "ALL PASS " << (candidate ? "candidate" : "baseline reproduction") << std::endl;
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << std::endl;
    return 1;
  }
}
#endif
