// mime <input path> <output directory>
//
// Parses an mbox file or a directory of .eml files and writes a text dump of
// every message plus the decoded attachments into the output directory.
#include <cstdio>
#include <exception>

#include "mime/report.hpp"

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: %s <input path> <output directory>\n", argc > 0 ? argv[0] : "mime");
    return 2;
  }
  try {
    mime::process_mailbox(argv[1], argv[2]);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "mime: %s\n", e.what());
    return 1;
  }
  return 0;
}
