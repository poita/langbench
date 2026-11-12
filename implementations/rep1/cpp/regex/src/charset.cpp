#include "regex/charset.hpp"

namespace regex {

CharSet CharSet::single(unsigned char c) {
  CharSet s;
  s.add(c);
  return s;
}

CharSet CharSet::all() {
  CharSet s;
  s.invert();
  return s;
}

void CharSet::add_range(unsigned char lo, unsigned char hi) {
  for (unsigned c = lo; c <= hi; ++c) add(static_cast<unsigned char>(c));
}

void CharSet::add_all(const CharSet& o) {
  for (int i = 0; i < 4; ++i) w_[i] |= o.w_[i];
}

void CharSet::invert() {
  for (auto& w : w_) w = ~w;
}

void CharSet::invert_ascii() {
  w_[0] = ~w_[0];
  w_[1] = ~w_[1];
  w_[2] = 0;
  w_[3] = 0;
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

}  // namespace regex
