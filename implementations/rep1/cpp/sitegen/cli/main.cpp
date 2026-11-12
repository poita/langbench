// Command-line front end: sitegen <input directory> <output directory>
#include <exception>
#include <iostream>
#include <string>

#include "sitegen/generator.hpp"

namespace {

void print_usage(std::ostream& out) {
  out << "usage: sitegen <input directory> <output directory>\n"
         "\n"
         "Reads the site source in <input directory> (site.toml, content/, templates/,\n"
         "static/) and writes the generated website into <output directory>.\n"
         "\n"
         "options:\n"
         "  -h, --help   show this help\n";
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 2 && (std::string(argv[1]) == "-h" || std::string(argv[1]) == "--help")) {
    print_usage(std::cout);
    return 0;
  }
  if (argc != 3) {
    print_usage(std::cerr);
    return 2;
  }
  try {
    sitegen::generate_site(argv[1], argv[2]);
  } catch (const sitegen::TemplateError& e) {
    std::cerr << "sitegen: template error (" << sitegen::to_string(e.kind()) << "): " << e.what() << "\n";
    return 1;
  } catch (const std::exception& e) {
    std::cerr << "sitegen: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
