// Cross-check against the host FPU as a *test oracle only* (the library itself
// never uses floating point). Assumes the host is IEEE-754 binary32 with
// round-to-nearest-even and denormals enabled.
#include <gtest/gtest.h>

#include <cmath>
#include <cstring>
#include <random>
#include <vector>

#include "softfloat/softfloat.h"

namespace sf = softfloat;
using sf::Bits32;
using sf::kQuietNaN;

namespace {

float to_f(Bits32 b) { float f; std::memcpy(&f, &b, 4); return f; }
Bits32 from_f(float f) {
  if (std::isnan(f)) return kQuietNaN;
  Bits32 b; std::memcpy(&b, &f, 4); return b;
}

enum Op { kAdd, kSub, kMul, kDiv, kSqrt };

Bits32 oracle(Op op, Bits32 a, Bits32 b) {
  volatile float x = to_f(a), y = to_f(b), r = 0;
  switch (op) {
    case kAdd: r = x + y; break;
    case kSub: r = x - y; break;
    case kMul: r = x * y; break;
    case kDiv: r = x / y; break;
    case kSqrt: r = std::sqrt(x); break;
  }
  return from_f(r);
}

Bits32 ours(Op op, Bits32 a, Bits32 b) {
  switch (op) {
    case kAdd: return sf::add(a, b);
    case kSub: return sf::sub(a, b);
    case kMul: return sf::mul(a, b);
    case kDiv: return sf::div(a, b);
    case kSqrt: return sf::sqrt(a);
  }
  return 0;
}

const char* name(Op op) {
  static const char* n[] = {"add", "sub", "mul", "div", "sqrt"};
  return n[op];
}

void check(Op op, Bits32 a, Bits32 b) {
  ASSERT_EQ(ours(op, a, b), oracle(op, a, b)) << name(op) << std::hex << " " << a << " " << b;
}

// Operand generator biased towards the interesting regions.
Bits32 gen(std::mt19937& rng) {
  const Bits32 r = rng();
  switch (rng() % 8) {
    case 0: return r;                                   // anything
    case 1: return r & 0x807fffffu;                     // zero/denormal
    case 2: return (r & 0x80000000u) | 0x00800000u | (r & 0x7u);          // near min normal
    case 3: return (r & 0x80000000u) | 0x7f000000u | (r & 0x7fffffu);     // near max
    case 4: return (r & 0x80000000u) | (0x3f000000u + ((r >> 23) & 0x3u) * 0x00800000u) | (r & 0xffu);
    case 5: return (r & 0x80000000u) | (r & 0x7fu) | ((r >> 8) & 0x3f800000u);  // few sig bits
    case 6: return (r & 0x80000000u) | (r & 0x7f800000u) | ((r & 1) ? 0 : 0x7fffffu);
    default: return (r & 0xff800000u) | ((r >> 9) & 0x1fu) << 18;           // few sig bits
  }
}

}  // namespace

TEST(Reference, RandomBinaryOps) {
  std::mt19937 rng(12345);
  for (int i = 0; i < 400000; ++i) {
    const Bits32 a = gen(rng), b = gen(rng);
    for (Op op : {kAdd, kSub, kMul, kDiv}) {
      check(op, a, b);
      if (HasFatalFailure()) return;
    }
  }
}

TEST(Reference, RandomSqrt) {
  std::mt19937 rng(777);
  for (int i = 0; i < 1000000; ++i) {
    check(kSqrt, gen(rng), 0);
    if (HasFatalFailure()) return;
  }
}

TEST(Reference, SqrtAllDenormalsAndSmallNormals) {
  for (Bits32 a = 0; a < 0x01000000u; a += 7) {
    check(kSqrt, a, 0);
    if (HasFatalFailure()) return;
  }
}

TEST(Reference, ExponentSweepAroundSubnormalBoundary) {
  // Sweep exponents of both operands with a few significand patterns.
  const Bits32 sigs[] = {0, 1, 0x400000, 0x7fffff, 0x555555, 0x2aaaaa, 0x7ffffe};
  for (Bits32 ea = 0; ea < 256; ++ea)
    for (Bits32 eb = 0; eb < 256; ++eb)
      for (Bits32 sa : sigs)
        for (Bits32 sb : sigs)
          for (Op op : {kAdd, kSub, kMul, kDiv}) {
            check(op, (ea << 23) | sa, (eb << 23) | sb);
            if (HasFatalFailure()) return;
          }
}
