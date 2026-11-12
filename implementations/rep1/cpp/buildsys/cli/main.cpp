// kiln: runs a session directory and writes its log and final workspace.
//
//   kiln <input directory> <output directory>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>

#include "kiln/kiln.hpp"

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: " << (argc > 0 ? argv[0] : "kiln") << " <input directory> <output directory>\n";
    return 2;
  }
  namespace fs = std::filesystem;
  try {
    const fs::path input = argv[1];
    const fs::path output = argv[2];

    std::ifstream script_file(input / "session.txt", std::ios::binary);
    if (!script_file) {
      std::cerr << "kiln: cannot read " << (input / "session.txt").string() << "\n";
      return 1;
    }
    std::string script((std::istreambuf_iterator<char>(script_file)), std::istreambuf_iterator<char>());

    kiln::Vfs workspace = kiln::Vfs::load_directory(input.string(), "session.txt");
    std::string log = kiln::run_session(workspace, script);

    fs::create_directories(output);
    std::ofstream log_file(output / "log.txt", std::ios::binary | std::ios::trunc);
    log_file << log;
    log_file.close();
    if (!log_file) {
      std::cerr << "kiln: cannot write log.txt\n";
      return 1;
    }
    workspace.save_directory((output / "workspace").string());
  } catch (const std::exception& e) {
    std::cerr << "kiln: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
