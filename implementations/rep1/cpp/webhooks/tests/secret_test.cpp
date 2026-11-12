#include <gtest/gtest.h>

#include "webhooks/hex.hpp"
#include "webhooks/secret.hpp"

using namespace webhooks;

TEST(Secret, PrefixIsOptional) {
  auto a = parse_secret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw");
  auto b = parse_secret("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw");
  ASSERT_TRUE(a && b);
  EXPECT_EQ(*a, *b);
  EXPECT_EQ(to_hex(*a), "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0");
}

TEST(Secret, PrefixIsStrippedOnlyOnce) {
  // The second "whsec_" is Base64 data: 10 characters ("whsec_AAAA") -> 7 bytes.
  auto s = parse_secret("whsec_whsec_AAAA");
  ASSERT_TRUE(s);
  EXPECT_EQ(s->size(), 7u);
  EXPECT_NE(*s, *parse_secret("AAAA"));
}

TEST(Secret, UnpaddedLongerKey) {
  auto s = parse_secret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr");
  ASSERT_TRUE(s);
  EXPECT_EQ(s->size(), 25u);
}

TEST(Secret, InvalidSecrets) {
  EXPECT_FALSE(parse_secret("whsec_"));  // decodes to zero bytes
  EXPECT_FALSE(parse_secret(""));
  EXPECT_FALSE(parse_secret("whsec_A"));  // length 1 mod 4
  EXPECT_FALSE(parse_secret("a$b="));
}
