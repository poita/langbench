// Command-line tool: sqlitefile_cli <input directory> <output directory>
//
// The input directory holds one `*.sqlite` file and `queries.txt`; for the
// n-th query line the tool writes `NNN.txt` into the output directory.
// A failing query writes the single line `error`. Exit status is 0 unless
// the arguments are unusable.

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include "sqlitefile/sqlitefile.hpp"

namespace fs = std::filesystem;

namespace {

std::optional<fs::path> findDatabase(const fs::path& dir) {
  std::vector<fs::path> found;
  std::error_code ec;
  for (const auto& entry : fs::directory_iterator(dir, ec)) {
    if (entry.path().extension() == ".sqlite") found.push_back(entry.path());
  }
  if (found.empty()) return std::nullopt;
  std::sort(found.begin(), found.end());
  return found.front();
}

std::vector<std::string> readLines(const fs::path& path) {
  std::ifstream in(path, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  std::string text = ss.str();
  std::vector<std::string> lines;
  std::size_t start = 0;
  while (start < text.size()) {
    std::size_t nl = text.find('\n', start);
    if (nl == std::string::npos) nl = text.size();
    lines.push_back(text.substr(start, nl - start));
    start = nl + 1;
  }
  return lines;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: " << argv[0] << " <input directory> <output directory>\n";
    return 2;
  }
  fs::path input = argv[1], output = argv[2];
  std::vector<std::string> queries = readLines(input / "queries.txt");

  std::optional<sqlitefile::Database> db;
  if (auto path = findDatabase(input)) {
    try {
      db.emplace(sqlitefile::Database::open(*path));
    } catch (const sqlitefile::Error& e) {
      std::cerr << "cannot open database: " << e.what() << "\n";
    }
  }

  for (std::size_t i = 0; i < queries.size(); ++i) {
    std::string result;
    try {
      if (!db) throw sqlitefile::Error("no database");
      result = db->run(queries[i]);
    } catch (const std::exception&) {
      result = "error\n";
    }
    char name[32];
    std::snprintf(name, sizeof name, "%03zu.txt", i + 1);
    std::ofstream out(output / name, std::ios::binary);
    out << result;
  }
  return 0;
}
