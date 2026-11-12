#include <gtest/gtest.h>

#include "gitrepo/sha1.hpp"

using gitrepo::Sha1;
using gitrepo::sha1;

TEST(Sha1, EmptyString) {
  EXPECT_EQ(sha1("").hex(), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
}

TEST(Sha1, Abc) {
  EXPECT_EQ(sha1("abc").hex(), "a9993e364706816aba3e25717850c26c9cd0d89d");
}

TEST(Sha1, TwoBlockMessage) {
  EXPECT_EQ(sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").hex(),
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1");
}

TEST(Sha1, MillionAs) {
  Sha1 h;
  std::string chunk(1000, 'a');
  for (int i = 0; i < 1000; ++i) h.update(chunk);
  EXPECT_EQ(h.finish().hex(), "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
}

TEST(Sha1, IncrementalMatchesOneShot) {
  std::string data;
  for (int i = 0; i < 300; ++i) data += static_cast<char>(i * 7);
  for (std::size_t step : {1u, 3u, 63u, 64u, 65u, 200u}) {
    Sha1 h;
    for (std::size_t i = 0; i < data.size(); i += step) h.update(data.substr(i, step));
    EXPECT_EQ(h.finish(), sha1(data)) << "step " << step;
  }
}

TEST(Sha1, GitBlobId) {
  EXPECT_EQ(sha1(std::string("blob 9\0one file\n", 16)).hex(),
            "b7814cae2e925fe74c6cd5816462fff515ccb256");
}
