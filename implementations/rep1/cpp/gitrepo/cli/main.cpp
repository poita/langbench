// gitrepo <input path> <output dir>
//
// Reads <input path>/commands.txt, runs each command against the repository in
// <input path>/repo and writes the answer of command k to <output dir>/NNN.out.

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

#include "gitrepo/commands.hpp"
#include "gitrepo/repository.hpp"

namespace fs = std::filesystem;

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: " << argv[0] << " <input path> <output dir>\n";
    return 2;
  }
  fs::path input = argv[1];
  fs::path output = argv[2];

  std::string commands;
  {
    std::ifstream in(input / "commands.txt", std::ios::binary);
    commands.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
  }
  std::error_code ec;
  fs::create_directories(output, ec);

  gitrepo::Repository repo(input / "repo");

  std::string_view rest = commands;
  int number = 0;
  while (!rest.empty()) {
    std::size_t eol = rest.find('\n');
    std::string_view line = rest.substr(0, eol);
    rest = eol == std::string_view::npos ? std::string_view() : rest.substr(eol + 1);

    char name[32];
    std::snprintf(name, sizeof name, "%03d.out", ++number);
    std::string result = gitrepo::run_command_or_error(repo, line);
    std::ofstream out(output / name, std::ios::binary);
    out.write(result.data(), static_cast<std::streamsize>(result.size()));
  }
  return 0;
}
