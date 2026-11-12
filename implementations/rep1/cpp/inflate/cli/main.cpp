// Command-line front end: reads a hex-encoded raw DEFLATE stream on stdin and
// prints the decompressed bytes as hex, or the word "error" if the stream is
// malformed. Always exits 0 (see SPEC.md).

#include <cstdio>
#include <string>
#include <vector>

#include "inflate/hex.hpp"
#include "inflate/inflate.hpp"

namespace {

std::string read_all(std::FILE* f) {
  std::string s;
  char buf[1 << 16];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) s.append(buf, n);
  return s;
}

}  // namespace

int main() {
  const std::string text = read_all(stdin);
  std::vector<std::uint8_t> stream;
  std::string line = "error";
  if (inflate::hex_decode(text, stream)) {
    const inflate::Result r = inflate::inflate(stream);
    if (r) line = inflate::hex_encode(r.data);
  }
  line.push_back('\n');
  std::fwrite(line.data(), 1, line.size(), stdout);
  return std::fflush(stdout) == 0 ? 0 : 1;
}
