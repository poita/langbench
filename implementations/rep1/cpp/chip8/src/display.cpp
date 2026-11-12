#include "chip8/display.hpp"

namespace chip8 {

std::string Display::to_text() const {
  std::string out;
  out.reserve((kWidth + 1) * kHeight);
  for (int y = 0; y < kHeight; ++y) {
    for (int x = 0; x < kWidth; ++x) out.push_back(pixel(x, y) ? '#' : '.');
    out.push_back('\n');
  }
  return out;
}

}  // namespace chip8
