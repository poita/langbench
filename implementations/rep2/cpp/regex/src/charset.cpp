#include "rx/charset.hpp"

namespace rx {

std::size_t CharSet::size() const {
  std::size_t n = 0;
  for (unsigned c = 0; c < 256; ++c) n += contains(static_cast<unsigned char>(c));
  return n;
}

CharSet CharSet::digits() {
  CharSet s;
  s.add_range('0', '9');
  return s;
}

CharSet CharSet::word() {
  CharSet s;
  s.add_range('a', 'z');
  s.add_range('A', 'Z');
  s.add_range('0', '9');
  s.add('_');
  return s;
}

CharSet CharSet::space() {
  CharSet s;
  for (char c : {' ', '\t', '\n', '\r', '\f', '\v'}) s.add(static_cast<unsigned char>(c));
  return s;
}

}  // namespace rx
