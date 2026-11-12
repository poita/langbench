// kiln <input directory> <output directory>
//
// Runs the session script `<input>/session.txt` against the workspace in
// `<input>` and writes `log.txt` and the final `workspace/` into `<output>`.

#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>

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

    std::ifstream sin(input / "session.txt", std::ios::binary);
    if (!sin) {
      std::cerr << "kiln: cannot read " << (input / "session.txt") << "\n";
      return 1;
    }
    std::ostringstream script;
    script << sin.rdbuf();

    kiln::Vfs vfs = kiln::Vfs::loadDirectory(input.string(), "session.txt");
    std::string log = kiln::runSession(vfs, script.str());

    fs::create_directories(output);
    {
      std::ofstream out(output / "log.txt", std::ios::binary | std::ios::trunc);
      out.write(log.data(), static_cast<std::streamsize>(log.size()));
    }
    vfs.writeDirectory((output / "workspace").string());
  } catch (const std::exception& e) {
    std::cerr << "kiln: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
