#include "bigint/magnitude.hpp"

#include <gtest/gtest.h>

#include <stdexcept>

using namespace bigint::mag;

namespace {
std::string str(const Magnitude& m) {
  std::string s;
  append_digits(m, s);
  return s;
}
}  // namespace

TEST(Magnitude, ParseAndPrintRoundTrip) {
  EXPECT_EQ(str(from_digits("0")), "0");
  EXPECT_EQ(str(from_digits("000000000000000000123")), "123");
  EXPECT_EQ(str(from_digits("1000000000")), "1000000000");
  EXPECT_EQ(str(from_digits("123456789012345678901234567890")), "123456789012345678901234567890");
  EXPECT_TRUE(from_digits("000").empty());
}

TEST(Magnitude, RejectsNonDigits) {
  EXPECT_THROW(from_digits("12a"), std::invalid_argument);
  EXPECT_THROW(from_digits("-1"), std::invalid_argument);
}

TEST(Magnitude, LimbBoundaryCarries) {
  EXPECT_EQ(str(add(from_digits("999999999"), from_digits("1"))), "1000000000");
  EXPECT_EQ(str(sub(from_digits("1000000000000000000"), from_digits("1"))), "999999999999999999");
  EXPECT_EQ(str(mul(from_digits("999999999"), from_digits("999999999"))), "999999998000000001");
}

TEST(Magnitude, Compare) {
  EXPECT_EQ(compare(from_digits("5"), from_digits("5")), 0);
  EXPECT_EQ(compare(from_digits("4"), from_digits("5")), -1);
  EXPECT_EQ(compare(from_digits("10000000000"), from_digits("999999999")), 1);
}

TEST(Magnitude, DivmodSingleLimb) {
  auto [q, r] = divmod(from_digits("123456789123456789"), from_digits("1000"));
  EXPECT_EQ(str(q), "123456789123456");
  EXPECT_EQ(str(r), "789");
}

TEST(Magnitude, DivmodMultiLimbIdentity) {
  // Exercises the qhat correction and the add-back step with adversarial limbs.
  const char* as[] = {
      "999999999999999999999999999999999999999999999999",
      "1000000000000000000000000000000000000000000000000",
      "999999999000000000999999999000000000999999999",
      "340282366920938463463374607431768211456123456789012345678901234567890",
  };
  const char* bs[] = {
      "999999999999999999", "1000000000000000000", "500000000500000000",
      "999999999000000001", "123456789987654321123456789", "499999999999999999999",
  };
  for (const char* as_ : as) {
    for (const char* bs_ : bs) {
      Magnitude a = from_digits(as_), b = from_digits(bs_);
      auto [q, r] = divmod(a, b);
      EXPECT_LT(compare(r, b), 0) << as_ << " / " << bs_;
      EXPECT_EQ(compare(add(mul(q, b), r), a), 0) << as_ << " / " << bs_;
    }
  }
}

TEST(Magnitude, DivmodKnuthAddBackCase) {
  // Classic case where qhat is one too large after the two-limb test.
  Magnitude b = {0, 999999999, 500000000};
  Magnitude a = mul(b, Magnitude{999999999});
  a = add(a, Magnitude{0, 999999999});
  auto [q, r] = divmod(a, b);
  EXPECT_EQ(compare(add(mul(q, b), r), a), 0);
  EXPECT_LT(compare(r, b), 0);
}

TEST(Magnitude, DivmodByZeroThrows) {
  EXPECT_THROW(divmod(from_digits("5"), Magnitude{}), std::domain_error);
}

TEST(Magnitude, Pow) {
  EXPECT_EQ(str(pow(from_digits("2"), 100)), "1267650600228229401496703205376");
  EXPECT_EQ(str(pow(from_digits("0"), 0)), "1");
  EXPECT_EQ(str(pow(from_digits("0"), 5)), "0");
  EXPECT_EQ(str(pow(from_digits("12345"), 1)), "12345");
}
