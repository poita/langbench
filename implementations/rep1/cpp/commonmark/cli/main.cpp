// commonmark-cli: reads Markdown on stdin (or from FILE arguments) and writes
// the HTML on stdout.
#include <cstdio>
#include <cstring>
#include <string>

#include "commonmark/commonmark.h"

namespace {

bool read_all(std::FILE* in, std::string& out) {
  char buf[1 << 16];
  std::size_t got;
  while ((got = std::fread(buf, 1, sizeof buf, in)) > 0) out.append(buf, got);
  return !std::ferror(in);
}

void usage(std::FILE* to) {
  std::fputs(
      "usage: commonmark-cli [FILE...]\n"
      "Converts CommonMark to HTML. Reads standard input when no FILE is given\n"
      "(or FILE is '-'), writes the HTML to standard output.\n",
      to);
}

}  // namespace

int main(int argc, char** argv) {
  std::string input;
  if (argc <= 1) {
    if (!read_all(stdin, input)) {
      std::fputs("commonmark-cli: error reading standard input\n", stderr);
      return 1;
    }
  } else {
    for (int i = 1; i < argc; ++i) {
      const char* arg = argv[i];
      if (std::strcmp(arg, "-h") == 0 || std::strcmp(arg, "--help") == 0) {
        usage(stdout);
        return 0;
      }
      std::FILE* in = std::strcmp(arg, "-") == 0 ? stdin : std::fopen(arg, "rb");
      if (in == nullptr) {
        std::fprintf(stderr, "commonmark-cli: cannot open %s\n", arg);
        return 1;
      }
      const bool ok = read_all(in, input);
      if (in != stdin) std::fclose(in);
      if (!ok) {
        std::fprintf(stderr, "commonmark-cli: error reading %s\n", arg);
        return 1;
      }
    }
  }

  const std::string html = commonmark::to_html(input);
  if (!html.empty() && std::fwrite(html.data(), 1, html.size(), stdout) != html.size()) return 1;
  return std::fflush(stdout) == 0 ? 0 : 1;
}
