#include <gtest/gtest.h>

#include "mime/message.hpp"

using namespace mime;

namespace {
Message parse(const std::string& s) { return parse_message(s, "t"); }
}  // namespace

TEST(Message, PlainDefaults) {
  Message m = parse("Subject: hi\n\nhello\n");
  EXPECT_EQ(m.part_count, 1);
  EXPECT_EQ(m.root.type, "text");
  EXPECT_EQ(m.root.subtype, "plain");
  EXPECT_EQ(m.root.charset, "us-ascii");
  EXPECT_EQ(m.root.cte, "7bit");
  EXPECT_EQ(m.root.content, "hello\n");
  EXPECT_EQ(m.text_index, 0);
  EXPECT_FALSE(m.html_index);
  EXPECT_TRUE(m.attachment_indices.empty());
}

TEST(Message, CrlfIsNormalised) {
  Message m = parse("A: b\r\n\r\nx\r\ny\r\n");
  EXPECT_EQ(m.root.content, "x\ny\n");
  EXPECT_EQ(m.byte_length, 14u);
}

TEST(Message, Multipart) {
  Message m = parse(
      "Content-Type: multipart/mixed; boundary=\"X\"\n\n"
      "pre\n--X\nContent-Type: text/plain; charset=iso-8859-1\n\ncaf\xe9\n"
      "--X\nContent-Type: text/html\n\n<b>\n--X\nContent-Type: application/octet-stream\n"
      "Content-Disposition: attachment; filename=\"a.bin\"\nContent-Transfer-Encoding: base64\n\n"
      "AAECAw==\n--X--\nepi\n");
  ASSERT_EQ(m.part_count, 4);
  EXPECT_EQ(m.root.kind, PartKind::Multipart);
  EXPECT_EQ(m.root.preamble_size, 3u);
  EXPECT_EQ(m.root.epilogue_size, 4u);
  EXPECT_EQ(m.text_index, 1);
  EXPECT_EQ(m.html_index, 2);
  ASSERT_EQ(m.attachment_indices.size(), 1u);
  const Part& a = m.root.children[2];
  EXPECT_EQ(a.index, 3);
  EXPECT_EQ(a.filename, "a.bin");
  EXPECT_EQ(a.content, std::string("\0\1\2\3", 4));
  EXPECT_EQ(m.root.children[0].content, "caf\xe9");
  EXPECT_EQ(part_text(m.root.children[0]), "caf\xc3\xa9");
}

TEST(Message, DelimiterEdgeCases) {
  // No delimiter: everything is preamble. Back-to-back delimiters: empty child.
  Message none = parse("Content-Type: multipart/mixed; boundary=B\n\nno delimiters\n");
  EXPECT_EQ(none.root.children.size(), 0u);
  EXPECT_EQ(none.root.preamble_size, 14u);
  EXPECT_FALSE(none.root.epilogue_size);

  Message empty = parse("Content-Type: multipart/mixed; boundary=B\n\n--B\n--B  \t\n--B--");
  ASSERT_EQ(empty.root.children.size(), 2u);
  EXPECT_EQ(empty.root.children[0].content, "");
  EXPECT_EQ(empty.root.epilogue_size, 0u);

  Message unclosed = parse("Content-Type: multipart/mixed; boundary=B\n\n--B\n\nabc\n");
  ASSERT_EQ(unclosed.root.children.size(), 1u);
  EXPECT_EQ(unclosed.root.children[0].content, "abc");
  EXPECT_FALSE(unclosed.root.epilogue_size);

  Message closed_first = parse("Content-Type: multipart/mixed; boundary=B\n\n--B--\nrest");
  EXPECT_EQ(closed_first.root.children.size(), 0u);
  EXPECT_EQ(closed_first.root.epilogue_size, 4u);

  // "--BX" is not a delimiter for boundary B.
  Message prefix = parse("Content-Type: multipart/mixed; boundary=B\n\n--BX\n--B\n\nq\n--B--\n");
  ASSERT_EQ(prefix.root.children.size(), 1u);
  EXPECT_EQ(prefix.root.preamble_size, 4u);
}

TEST(Message, MultipartWithoutBoundaryIsLeaf) {
  Message m = parse("Content-Type: multipart/mixed\n\nbody");
  EXPECT_EQ(m.root.kind, PartKind::Leaf);
  ASSERT_EQ(m.attachment_indices.size(), 1u);
}

TEST(Message, DigestDefaultsToRfc822) {
  Message m = parse(
      "Content-Type: multipart/digest; boundary=D\n\n--D\n\nSubject: inner\n\nbody\n--D--\n");
  ASSERT_EQ(m.part_count, 3);
  EXPECT_EQ(m.root.children[0].type, "message");
  EXPECT_EQ(m.root.children[0].kind, PartKind::Message);
  EXPECT_EQ(m.root.children[0].children[0].content, "body");
  // The inner part is not considered for body selection.
  EXPECT_FALSE(m.text_index);
  ASSERT_EQ(m.attachment_indices.size(), 1u);
  EXPECT_EQ(m.attachment_indices[0], 2);
}

TEST(Message, UnusableContentTypeFallsBack) {
  Message m = parse("Content-Type: garbage; charset=UTF-8\n\nx");
  EXPECT_EQ(m.root.type, "text");
  EXPECT_EQ(m.root.charset, "utf-8");
}

TEST(Message, AttachmentDispositionIsNotABody) {
  Message m = parse("Content-Disposition: attachment; filename=x.txt\n\nx");
  EXPECT_FALSE(m.text_index);
  EXPECT_EQ(m.attachment_indices.size(), 1u);
}

TEST(Message, FilenameFallsBackToName) {
  Message m = parse("Content-Type: application/pdf; name=n.pdf\n\nx");
  EXPECT_EQ(m.root.filename, "n.pdf");
}

TEST(Message, Flatten) {
  Message m = parse("Content-Type: multipart/mixed; boundary=X\n\n--X\n\na\n--X\n\nb\n--X--\n");
  auto parts = flatten(m);
  ASSERT_EQ(parts.size(), 3u);
  EXPECT_EQ(parts[2]->content, "b");
}
