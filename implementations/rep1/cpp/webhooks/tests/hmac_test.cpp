#include <gtest/gtest.h>

#include <string>

#include "webhooks/hex.hpp"
#include "webhooks/hmac.hpp"

using namespace webhooks;

TEST(Hmac, Rfc4231Case1) {
  Bytes key(20, 0x0b);
  EXPECT_EQ(to_hex(hmac_sha256(key, as_bytes("Hi There"))),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
}

TEST(Hmac, Rfc4231Case2) {
  EXPECT_EQ(to_hex(hmac_sha256(as_bytes("Jefe"), as_bytes("what do ya want for nothing?"))),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
}

TEST(Hmac, Rfc4231LongKeyIsHashedFirst) {
  Bytes key(131, 0xaa);
  EXPECT_EQ(to_hex(hmac_sha256(key, as_bytes("Test Using Larger Than Block-Size Key - Hash Key First"))),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
}

TEST(Hmac, EmptyKeyAndMessage) {
  EXPECT_EQ(to_hex(hmac_sha256({}, {})),
            "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");
}

TEST(Hmac, CopiedPrototypeReusesKey) {
  HmacSha256 proto(as_bytes("Jefe"));
  HmacSha256 a = proto, b = proto;
  a.update("what do ya want ").update("for nothing?");
  b.update("what do ya want for nothing?");
  EXPECT_EQ(a.finish(), b.finish());
}

TEST(Hmac, ConstantTimeEqual) {
  Bytes a{1, 2, 3}, b{1, 2, 3}, c{1, 2, 4}, d{1, 2};
  EXPECT_TRUE(constant_time_equal(a, b));
  EXPECT_FALSE(constant_time_equal(a, c));
  EXPECT_FALSE(constant_time_equal(a, d));
}
