#include <cstdio>

#include "softfloat/softfloat.h"

int main() {
  namespace sf = softfloat;
  const sf::Bits32 one = 0x3f800000, three = 0x40400000;
  std::printf("1/3     = %08x\n", sf::div(one, three));                       // 3eaaaaab
  std::printf("sqrt(2) = %08x\n", sf::sqrt(0x40000000));                      // 3fb504f3
  std::printf("inf-inf = %08x\n", sf::sub(sf::kPositiveInfinity, sf::kPositiveInfinity));  // 7fc00000
}
