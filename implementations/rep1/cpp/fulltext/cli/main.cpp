// fulltext <input directory> <output directory>
//
// Indexes <input>/docs/*.txt, runs <input>/queries.txt against the index and
// writes results.txt and stats.txt into <output>.
#include <cstdio>
#include <exception>

#include "fulltext/batch.hpp"

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: %s <input directory> <output directory>\n", argv[0]);
    return 2;
  }
  try {
    fulltext::run_directory(argv[1], argv[2]);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "fulltext: %s\n", e.what());
    return 1;
  }
  return 0;
}
