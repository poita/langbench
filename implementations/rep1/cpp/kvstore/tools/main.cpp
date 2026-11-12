// tessera-cli <input dir> <output dir>
//
// Reads commands.txt (and optionally main.tdb / main.twal) from the input
// directory, runs the script, and writes results.txt, main.tdb and main.twal
// into the output directory.

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>

#include "tessera/tessera.hpp"

namespace fs = std::filesystem;

namespace {

std::vector<std::uint8_t> read_file(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  if (!in) return {};
  return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(in), {});
}

bool write_file(const fs::path& p, const void* data, std::size_t size) {
  std::ofstream out(p, std::ios::binary | std::ios::trunc);
  out.write(static_cast<const char*>(data), static_cast<std::streamsize>(size));
  return static_cast<bool>(out);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: " << argv[0] << " <input dir> <output dir>\n";
    return 2;
  }
  const fs::path in = argv[1], out = argv[2];

  std::vector<std::uint8_t> script = read_file(in / "commands.txt");
  tessera::DatabaseImage image;
  image.main = read_file(in / "main.tdb");
  image.wal = read_file(in / "main.twal");

  tessera::Database db(std::move(image));
  std::string results = tessera::run_script(
      db, std::string_view(reinterpret_cast<const char*>(script.data()), script.size()));

  std::error_code ec;
  fs::create_directories(out, ec);
  bool ok = write_file(out / "results.txt", results.data(), results.size()) &&
            write_file(out / "main.tdb", db.main_file().data(), db.main_file().size()) &&
            write_file(out / "main.twal", db.wal_file().data(), db.wal_file().size());
  if (!ok) {
    std::cerr << "error: cannot write output files\n";
    return 1;
  }
  return 0;
}
