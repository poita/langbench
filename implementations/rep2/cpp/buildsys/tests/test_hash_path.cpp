#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;

TEST(Hash, KnownVectors) {
  EXPECT_EQ(toHex16(fnv1a("")), "cbf29ce484222325");
  EXPECT_EQ(toHex16(fnv1a("hello\n")), "a9bc80cca21f28b3");
  EXPECT_EQ(toHex16(fnv1a("abc\n")), "fc17b183ee074373");
}

TEST(Hash, ParseHex16) {
  std::uint64_t v = 0;
  EXPECT_TRUE(parseHex16("a9bc80cca21f28b3", v));
  EXPECT_EQ(v, fnv1a("hello\n"));
  EXPECT_FALSE(parseHex16("A9bc80cca21f28b3", v));  // uppercase rejected
  EXPECT_FALSE(parseHex16("a9bc80cca21f28b", v));   // too short
  EXPECT_FALSE(parseHex16("a9bc80cca21f28bz", v));
}

TEST(Path, WorkspacePaths) {
  EXPECT_TRUE(isWorkspacePath("a"));
  EXPECT_TRUE(isWorkspacePath("src/a.b-c+d_e/x"));
  EXPECT_TRUE(isWorkspacePath(".kiln-state"));
  EXPECT_FALSE(isWorkspacePath(""));
  EXPECT_FALSE(isWorkspacePath("/a"));
  EXPECT_FALSE(isWorkspacePath("a/"));
  EXPECT_FALSE(isWorkspacePath("a//b"));
  EXPECT_FALSE(isWorkspacePath("a/./b"));
  EXPECT_FALSE(isWorkspacePath("a/../b"));
  EXPECT_FALSE(isWorkspacePath("a b"));
  EXPECT_FALSE(isWorkspacePath("a@b"));
  EXPECT_FALSE(isWorkspacePath(std::string(256, 'a')));
  EXPECT_TRUE(isWorkspacePath(std::string(255, 'a')));
}

TEST(Path, PhonyAndGenerated) {
  EXPECT_TRUE(isPhonyRef("@all"));
  EXPECT_FALSE(isPhonyRef("@"));
  EXPECT_FALSE(isPhonyRef("@1x"));
  EXPECT_FALSE(isPhonyRef("all"));
  EXPECT_TRUE(isGeneratedPath("out/a"));
  EXPECT_FALSE(isGeneratedPath("outer/a"));
  EXPECT_FALSE(isGeneratedPath("src/out/a"));
}
