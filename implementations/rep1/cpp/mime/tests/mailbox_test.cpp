#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>

#include "mime/mailbox.hpp"

using namespace mime;
namespace fs = std::filesystem;

TEST(Mailbox, SplitMbox) {
  auto msgs = split_mbox(
      "junk\n\nFrom a\nA: 1\n\nbody\n\nFrom b\nB: 2\n\nFrom c\nC: 3\nFrom not a separator\n");
  ASSERT_EQ(msgs.size(), 3u);
  EXPECT_EQ(msgs[0].source_id, "mbox:1");
  EXPECT_EQ(msgs[0].bytes, "A: 1\n\nbody\n");
  EXPECT_EQ(msgs[1].bytes, "B: 2\n");
  EXPECT_EQ(msgs[2].bytes, "C: 3\nFrom not a separator\n");
}

TEST(Mailbox, NoSeparator) {
  EXPECT_TRUE(split_mbox("A: 1\nFrom x\n").empty());
  EXPECT_TRUE(split_mbox("").empty());
}

TEST(Mailbox, SeparatorAtEofAndFirstLine) {
  auto msgs = split_mbox("From x");
  ASSERT_EQ(msgs.size(), 1u);
  EXPECT_EQ(msgs[0].bytes, "");
}

TEST(Mailbox, CrlfEmptyLineCountsAsEmpty) {
  auto msgs = split_mbox("From a\r\nA: 1\r\n\r\nFrom b\r\nB: 2\r\n");
  ASSERT_EQ(msgs.size(), 2u);
  EXPECT_EQ(msgs[0].bytes, "A: 1\r\n\r\n");
}

TEST(Mailbox, ReadDirectory) {
  fs::path dir = fs::temp_directory_path() / "mime_mailbox_test_dir";
  fs::remove_all(dir);
  fs::create_directories(dir / "sub.eml");
  for (const char* name : {"b.eml", "a.eml", "Z.eml", "skip.txt", "C.EML"}) {
    std::ofstream(dir / name, std::ios::binary) << name;
  }
  auto msgs = read_mailbox(dir);
  ASSERT_EQ(msgs.size(), 3u);
  EXPECT_EQ(msgs[0].source_id, "Z.eml");
  EXPECT_EQ(msgs[1].source_id, "a.eml");
  EXPECT_EQ(msgs[2].source_id, "b.eml");
  EXPECT_EQ(msgs[2].bytes, "b.eml");
  fs::remove_all(dir);
}
