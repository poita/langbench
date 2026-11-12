#include <gtest/gtest.h>

#include "gitrepo/error.hpp"
#include "gitrepo/object_store.hpp"
#include "gitrepo/objects.hpp"

using namespace gitrepo;

namespace {
const std::string kTree(40, 'a');
const std::string kParent1(40, 'b');
const std::string kParent2(40, 'c');
}  // namespace

TEST(CommitParse, HeadersAndSubject) {
  std::string payload =
      "tree " + kTree + "\nparent " + kParent1 + "\nparent " + kParent2 +
      "\nauthor Ada  Lovelace  <ada@x> 1400003600 +0100\n"
      "committer C <c@x> 1500000000 -0500\n"
      "gpgsig -----BEGIN-----\n line\n -----END-----\n\n"
      "\n\nFix the thing   \nand the other\n\nbody\n";
  Commit c = parse_commit(payload);
  EXPECT_EQ(c.tree.hex(), kTree);
  ASSERT_EQ(c.parents.size(), 2u);
  EXPECT_EQ(c.parents[0].hex(), kParent1);
  EXPECT_EQ(c.parents[1].hex(), kParent2);
  EXPECT_EQ(c.author.name, "Ada  Lovelace");
  EXPECT_EQ(c.author.timestamp, 1400003600u);
  EXPECT_EQ(c.committer.timestamp, 1500000000u);
  EXPECT_EQ(c.subject, "Fix the thing and the other");
  EXPECT_EQ(c.message, "\n\nFix the thing   \nand the other\n\nbody\n");
}

TEST(CommitParse, LastDuplicateHeaderWinsAndNoMessage) {
  std::string payload = "tree " + kTree + "\ntree " + kParent1 + "\nauthor A <a> 5 +0000";
  Commit c = parse_commit(payload);
  EXPECT_EQ(c.tree.hex(), kParent1);
  EXPECT_EQ(c.author.timestamp, 5u);
  EXPECT_EQ(c.message, "");
  EXPECT_EQ(c.subject, "");
}

TEST(CommitParse, MissingIdentFields) {
  Commit c = parse_commit("tree " + kTree + "\nauthor Nobody\ncommitter X <x>\n\nm\n");
  EXPECT_EQ(c.author.name, "Nobody");
  EXPECT_EQ(c.author.timestamp, 0u);
  EXPECT_EQ(c.committer.timestamp, 0u);
}

TEST(CommitParse, SignedTimestampSignIsIgnored) {
  Commit c = parse_commit("tree " + kTree + "\nauthor A <a>   -42 +0000\n\nm\n");
  EXPECT_EQ(c.author.timestamp, 42u);
}

TEST(CommitParse, RejectsMalformed) {
  EXPECT_THROW(parse_commit("author A <a> 1 +0\n\nm"), Error);        // no tree
  EXPECT_THROW(parse_commit("tree nothex\n\nm"), Error);
  EXPECT_THROW(parse_commit("tree " + kTree + "\nparent zz\n\nm"), Error);
}

TEST(CommitSubject, WhitespaceRules) {
  EXPECT_EQ(commit_subject(""), "");
  EXPECT_EQ(commit_subject("\n \t\n"), "");
  EXPECT_EQ(commit_subject("one\n"), "one");
  EXPECT_EQ(commit_subject("one\ntwo\r\n\nthree"), "one two");
  EXPECT_EQ(commit_subject("one \t\f\v\n  \nbody"), "one");
}

TEST(TreeParse, EntriesInStoredOrder) {
  std::string payload;
  payload += "100644 a.txt";
  payload += '\0';
  payload += std::string(20, '\x01');
  payload += "40000 dir";
  payload += '\0';
  payload += std::string(20, '\x02');
  payload += "160000 sub";
  payload += '\0';
  payload += std::string(20, '\x03');
  Tree t = parse_tree(payload);
  ASSERT_EQ(t.entries.size(), 3u);
  EXPECT_EQ(t.entries[0].name, "a.txt");
  EXPECT_EQ(t.entries[0].mode, 0100644u);
  EXPECT_EQ(t.entries[0].type(), ObjectType::Blob);
  EXPECT_EQ(t.entries[1].mode, 040000u);
  EXPECT_TRUE(t.entries[1].is_tree());
  EXPECT_EQ(t.entries[2].type(), ObjectType::Commit);
  EXPECT_EQ(t.entries[2].id.bytes[0], 3);
}

TEST(TreeParse, RejectsTruncatedAndMalformed) {
  EXPECT_NO_THROW(parse_tree(""));
  EXPECT_THROW(parse_tree(std::string("100644 a") + '\0' + "short"), Error);
  EXPECT_THROW(parse_tree("100644 a"), Error);
  EXPECT_THROW(parse_tree(std::string("1x0644 a") + '\0' + std::string(20, 'x')), Error);
  EXPECT_THROW(parse_tree(std::string("100644 ") + '\0' + std::string(20, 'x')), Error);
}

TEST(TagParse, ObjectHeader) {
  Tag t = parse_tag("object " + kTree + "\ntype commit\ntag v1\n\nmsg\n");
  EXPECT_EQ(t.target.hex(), kTree);
  EXPECT_THROW(parse_tag("type commit\n"), Error);
}

TEST(Delta, CopyAndInsert) {
  std::string base = "0123456789";
  // base size 10, result size 8: copy(offset 2, size 4), insert "XY", copy(offset 8, size 2)
  std::string delta;
  delta += '\x0a';
  delta += '\x08';
  delta += static_cast<char>(0x80 | 0x01 | 0x10);
  delta += '\x02';
  delta += '\x04';
  delta += '\x02';
  delta += "XY";
  delta += static_cast<char>(0x80 | 0x01 | 0x10);
  delta += '\x08';
  delta += '\x02';
  EXPECT_EQ(apply_delta(base, delta), "2345XY89");
}

TEST(Delta, ZeroSizeCopyMeans64K) {
  std::string base(0x10000, 'q');
  // base size and result size are both 0x10000 (varint 80 80 04); then a copy
  // with no offset and no size bytes, which means 0x10000 bytes from offset 0.
  std::string delta("\x80\x80\x04\x80\x80\x04\x80", 7);
  EXPECT_EQ(apply_delta(base, delta), base);
}

TEST(Delta, RejectsInconsistentDeltas) {
  std::string base = "abc";
  EXPECT_THROW(apply_delta(base, std::string("\x04\x01x", 3)), Error);              // wrong base size
  EXPECT_THROW(apply_delta(base, std::string("\x03\x05\x01x", 4)), Error);         // result too short
  EXPECT_THROW(apply_delta(base, std::string("\x03\x01\x00", 3)), Error);          // opcode 0
  EXPECT_THROW(apply_delta(base, std::string("\x03\x03\x90\x04", 4)), Error);      // copy past end
  EXPECT_THROW(apply_delta(base, std::string("\x03\x03\x05" "x", 4)), Error);      // truncated insert
  EXPECT_THROW(apply_delta(base, std::string("\x03\x01\x02xy", 5)), Error);        // result too long
}
