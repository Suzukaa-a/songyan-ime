// Real public levers and LevelDB probe for the complete candidate framework.
#include <rime_api.h>
#include <rime_levers_api.h>
#include <cerrno>
#include <csignal>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <vector>

namespace fs = std::filesystem;

static void check(bool value, const char* label) {
  if (!value) throw std::runtime_error(label);
  std::cout << "PASS " << label << std::endl;
}

static std::string read_file(const fs::path& file) {
  std::ifstream input(file, std::ios::binary);
  if (!input.is_open()) throw std::runtime_error("cannot read fixture output: " + file.string());
  const std::string text{std::istreambuf_iterator<char>(input), {}};
  if (input.bad()) throw std::runtime_error("fixture output read failed");
  return text;
}

static void write_file(const fs::path& file, const std::string& text) {
  if (fs::exists(file)) throw std::runtime_error("fixture file already exists");
  std::ofstream output(file, std::ios::binary);
  output << text;
  output.close();
  if (output.fail()) throw std::runtime_error("fixture input write failed");
}

struct Snapshot {
  std::map<std::string, std::string> metadata;
  std::vector<std::string> rows;
};

static Snapshot parse_snapshot(const std::string& text) {
  if (text.empty() || text.back() != '\n') throw std::runtime_error("snapshot lacks complete final line");
  Snapshot result;
  std::istringstream input(text);
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty()) continue;
    if (line.rfind("#@/", 0) == 0) {
      const auto tab = line.find('\t');
      if (tab == std::string::npos || !result.metadata.emplace(line.substr(2, tab - 2), line.substr(tab + 1)).second)
        throw std::runtime_error("invalid or duplicate metadata line");
    } else if (line[0] != '#') {
      const auto first = line.find('\t');
      const auto second = first == std::string::npos ? first : line.find('\t', first + 1);
      if (first == std::string::npos || second == std::string::npos || line.find('\t', second + 1) != std::string::npos)
        throw std::runtime_error("snapshot body is not a complete three-column row");
      result.rows.push_back(line);
    }
  }
  return result;
}

static std::string seed_text(const std::string& name, bool empty = false) {
  return "# Rime user dictionary\n#@/db_name\t" + name +
      "\n#@/db_type\tuserdb\n#@/rime_version\t1.17.0\n#@/tick\t1\n#@/user_id\ttest-source\n" +
      (empty ? "" : "a \tpositive\tc=1 d=1 t=1\nb \tzero\tc=0 d=2 t=1\nz \tdeleted\tc=-2 d=0.5 t=1\n");
}

static void seed(RimeLeversApi* levers, const fs::path& root, const std::string& name, bool empty = false) {
  const auto file = root / (name + "-input.userdb.txt");
  write_file(file, seed_text(name, empty));
  check(levers->restore_user_dict(file.c_str()) != 0, "public restore seeds and closes real LevelDB userdb");
  check(fs::is_directory(root / "user" / (name + ".userdb")), "seed created the real native userdb directory");
}

int main(int argc, char** argv) {
  RimeApi* api = rime_get_api();
  bool initialized = false;
  struct rlimit prior{};
  bool limited = false;
  auto old_signal = SIG_DFL;
  try {
    check(argc == 2, "one fresh scratch root supplied");
    const auto repository = fs::path(__FILE__).parent_path().parent_path().parent_path().parent_path();
    const auto parent = fs::canonical(repository / ".scratch");
    const auto root = fs::absolute(argv[1]).lexically_normal();
    check(root.parent_path() == parent && root.filename().string().rfind("learning-engine-io-", 0) == 0 &&
          fs::weakly_canonical(root) == root && !fs::exists(root), "verified new direct scratch child");
    check(fs::create_directory(root), "exclusive IO probe root created");
    for (const auto* name : {"shared", "user", "logs"}) fs::create_directory(root / name);
    const auto shared = (root / "shared").string(), user = (root / "user").string(), logs = (root / "logs").string();
    check(api && RIME_API_AVAILABLE(api, get_user_data_sync_dir) && RIME_API_AVAILABLE(api, run_task), "real core C API available");
    const char* modules[] = {"default", "levers", nullptr};
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared.c_str();
    traits.user_data_dir = user.c_str();
    traits.log_dir = logs.c_str();
    traits.min_log_level = 3;
    traits.app_name = "rime.learning-engine-io";
    traits.modules = modules;
    api->setup(&traits);
    api->initialize(&traits);
    initialized = true;
    check(api->run_task("installation_update") != 0 && api->run_task("installation_update") != 0,
          "real installation creation and reload establish UUID and sync root");
    auto* module = api->find_module("levers");
    check(module && module->get_api, "real levers module available");
    auto* levers = reinterpret_cast<RimeLeversApi*>(module->get_api());
    check(RIME_API_AVAILABLE(levers, restore_user_dict) && RIME_API_AVAILABLE(levers, backup_user_dict) &&
          RIME_API_AVAILABLE(levers, export_user_dict), "original int-Bool public levers ABI available");
    char sync_buffer[4096]{};
    api->get_user_data_sync_dir(sync_buffer, sizeof(sync_buffer));
    const fs::path sync(sync_buffer);
    check(!sync.empty() && fs::weakly_canonical(sync).string().rfind(user + "/", 0) == 0,
          "native API resolves the owned installation-specific sync directory");

    seed(levers, root, "normal");
    check(levers->backup_user_dict("normal") != 0, "real full-framework public backup succeeds");
    const auto snapshot_file = sync / "normal.userdb.txt";
    const auto complete = read_file(snapshot_file);
    const auto snapshot = parse_snapshot(complete);
    check(snapshot.metadata.at("/db_name") == "normal" && snapshot.metadata.at("/db_type") == "userdb" &&
          snapshot.metadata.at("/rime_version") == "1.17.0" && snapshot.metadata.at("/user_id") == api->get_user_id(),
          "normal snapshot contains native metadata and actual installation UUID");
    check(snapshot.rows == std::vector<std::string>{"a \tpositive\tc=1 d=1 t=1", "b \tzero\tc=0 d=2 t=1", "z \tdeleted\tc=-2 d=0.5 t=1"},
          "real raw backup preserves positive zero deleted commits and d/t");
    write_file(root / "normal-complete.userdb.txt", complete);
    const auto exported_file = root / "export.tsv";
    check(levers->export_user_dict("normal", exported_file.c_str()) == 2, "public export returns positive plus zero row count");
    const auto exported = parse_snapshot(read_file(exported_file));
    check(exported.rows == std::vector<std::string>{"positive\ta\t1", "zero\tb\t0"},
          "ordinary export filters deletion and deliberately discards d/t");

    const auto boundary = complete.find("z \tdeleted\t");
    check(boundary != std::string::npos && boundary > 0 && complete[boundary - 1] == '\n' &&
          parse_snapshot(complete.substr(0, boundary)).rows.size() == 2, "fault boundary follows two complete rows and metadata");
    check(getrlimit(RLIMIT_FSIZE, &prior) == 0 && boundary < prior.rlim_cur, "file-size resource limit read and can be lowered");
    struct rlimit limit{static_cast<rlim_t>(boundary), prior.rlim_max};
    old_signal = signal(SIGXFSZ, SIG_IGN);
    check(old_signal != SIG_ERR, "SIGXFSZ ignored only for controlled write failure");
    check(setrlimit(RLIMIT_FSIZE, &limit) == 0, "snapshot-size limit installed after all setup and seeding");
    limited = true;
    const int result = levers->backup_user_dict("normal");
    check(setrlimit(RLIMIT_FSIZE, &prior) == 0, "original file-size limit restored");
    limited = false;
    check(signal(SIGXFSZ, old_signal) != SIG_ERR, "original SIGXFSZ disposition restored");
    const auto prefix = read_file(snapshot_file);
    std::cout << "BOUNDARY public_backup=" << result << " limit=" << boundary << " actual_bytes=" << prefix.size() << std::endl;
    check(prefix.size() == boundary && prefix == complete.substr(0, boundary) && parse_snapshot(prefix).rows.size() == 2,
          "actual native output reached exact intact prefix missing the deleted row");
    check(result == 0, "real public backup rejects complete-line truncated output");
    write_file(root / "normal-prefix.userdb.txt", prefix);
    check(levers->backup_user_dict("normal") != 0 && read_file(snapshot_file) == complete,
          "normal backup still succeeds after real write fault and limit restoration");

    seed(levers, root, "empty", true);
    check(levers->backup_user_dict("empty") != 0, "real empty userdb backup succeeds");
    const auto empty = parse_snapshot(read_file(sync / "empty.userdb.txt"));
    check(empty.rows.empty() && empty.metadata.at("/db_name") == "empty" && empty.metadata.at("/db_type") == "userdb" &&
          empty.metadata.count("/tick") == 1 && empty.metadata.at("/user_id") == api->get_user_id(),
          "empty native backup retains genuine metadata without invented rows");
    const auto empty_export = root / "empty-export.tsv";
    check(levers->export_user_dict("empty", empty_export.c_str()) == 0 && parse_snapshot(read_file(empty_export)).rows.empty(),
          "empty native export returns zero and an actual complete header-only file");

    seed(levers, root, "open");
    const auto open_file = sync / "open.userdb.txt";
    check(!fs::exists(open_file) && fs::create_directory(open_file), "exact native snapshot path is a directory before backup");
    check(levers->backup_user_dict("open") == 0 && fs::is_directory(open_file), "real public backup propagates snapshot open failure");
    api->finalize();
    initialized = false;
    std::cout << "PASS complete framework real-LevelDB public levers IO probe " << root << std::endl;
    return 0;
  } catch (const std::exception& error) {
    if (limited) { setrlimit(RLIMIT_FSIZE, &prior); signal(SIGXFSZ, old_signal); }
    if (initialized) api->finalize();
    std::cerr << "FAIL " << error.what() << std::endl;
    return 1;
  }
}
