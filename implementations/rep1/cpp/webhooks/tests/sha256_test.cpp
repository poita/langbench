#include <gtest/gtest.h>

#include <string>

#include "webhooks/hex.hpp"
#include "webhooks/sha256.hpp"

using namespace webhooks;

namespace {
std::string hash_hex(std::string_view s) { return to_hex(sha256(as_bytes(s))); }
}  // namespace

TEST(Sha256, EmptyString) {
  EXPECT_EQ(hash_hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}

TEST(Sha256, Abc) {
  EXPECT_EQ(hash_hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

TEST(Sha256, TwoBlockNistVector) {
  EXPECT_EQ(hash_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}

TEST(Sha256, MillionA) {
  EXPECT_EQ(hash_hex(std::string(1000000, 'a')),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

TEST(Sha256, PaddingBoundaries) {
  // Known digests around the 55/56/63/64-byte padding edges, cross-checked by
  // comparing one-shot and byte-at-a-time hashing for every length.
  for (std::size_t len = 0; len <= 200; ++len) {
    std::string msg(len, 'x');
    Sha256 incremental;
    for (char c : msg) incremental.update(std::string_view(&c, 1));
    EXPECT_EQ(to_hex(incremental.finish()), hash_hex(msg)) << "len " << len;
  }
  EXPECT_EQ(hash_hex(std::string(55, 'a')),
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318");
  EXPECT_EQ(hash_hex(std::string(56, 'a')),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");
  EXPECT_EQ(hash_hex(std::string(64, 'a')),
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
}

TEST(Sha256, ResetAllowsReuse) {
  Sha256 h;
  h.update("abc");
  h.finish();
  h.reset();
  h.update("abc");
  EXPECT_EQ(to_hex(h.finish()), hash_hex("abc"));
}
