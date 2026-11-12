#include "sat/luby.hpp"

namespace sat {

double luby(double y, int i) {
  // Find the finite subsequence that contains index i, and its size.
  int size = 1, seq = 0;
  while (size < i + 1) {
    ++seq;
    size = 2 * size + 1;
  }
  while (size - 1 != i) {
    size = (size - 1) >> 1;
    --seq;
    i = i % size;
  }
  double r = 1.0;
  for (int k = 0; k < seq; ++k) r *= y;
  return r;
}

}  // namespace sat
