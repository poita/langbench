#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>

#include "test_util.hpp"

using namespace kiln;

TEST(Vfs, ReadWriteRemove) {
  Vfs vfs;
  EXPECT_FALSE(vfs.exists("a"));
  vfs.write("a", "hello\n");
  EXPECT_EQ(*vfs.read("a"), "hello\n");
  EXPECT_EQ(toHex16(vfs.hash("a")), "a9bc80cca21f28b3");
  vfs.write("a", "abc\n");
  EXPECT_EQ(toHex16(vfs.hash("a")), "fc17b183ee074373");  // hash cache invalidated
  EXPECT_TRUE(vfs.remove("a"));
  EXPECT_FALSE(vfs.remove("a"));
}

TEST(Vfs, GlobSkipsGeneratedAndState) {
  Vfs vfs = kiln::testing::makeVfs({{"a.txt", ""}, {"out/b.txt", ""}, {".kiln-state", ""}, {"s/c.txt", ""}});
  auto all = vfs.glob(*GlobPattern::compile("**"));
  EXPECT_EQ(all, (std::vector<std::string>{"a.txt", "s/c.txt"}));
  vfs.remove("a.txt");
  EXPECT_EQ(vfs.glob(*GlobPattern::compile("*.txt")).size(), 0u);
  EXPECT_EQ(vfs.glob(*GlobPattern::compile("s/**")), (std::vector<std::string>{"s/c.txt"}));
}

TEST(Vfs, GlobTrailingDoubleStarMatchesBareFile) {
  Vfs vfs = kiln::testing::makeVfs({{"src", ""}, {"srcx", ""}});
  EXPECT_EQ(vfs.glob(*GlobPattern::compile("src/**")), (std::vector<std::string>{"src"}));
}

TEST(Vfs, GeneratedPathsAreSorted) {
  Vfs vfs = kiln::testing::makeVfs({{"out/b", ""}, {".kiln-state", ""}, {"out/a", ""}, {"x", ""}});
  EXPECT_EQ(vfs.generatedPaths(), (std::vector<std::string>{".kiln-state", "out/a", "out/b"}));
}

TEST(Vfs, DirectoryRoundTrip) {
  namespace fs = std::filesystem;
  fs::path dir = fs::temp_directory_path() / "kiln_vfs_test";
  fs::remove_all(dir);
  Vfs vfs = kiln::testing::makeVfs({{"a/b/c.txt", std::string("x\0y", 3)}, {"top", "t"}});
  vfs.writeDirectory((dir / "ws").string());
  std::ofstream(dir / "ws" / "session.txt") << "build\n";
  Vfs loaded = Vfs::loadDirectory((dir / "ws").string(), "session.txt");
  EXPECT_EQ(loaded.size(), 2u);
  EXPECT_EQ(*loaded.read("a/b/c.txt"), std::string("x\0y", 3));
  fs::remove_all(dir);
}
