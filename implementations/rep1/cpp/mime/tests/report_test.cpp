#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <sstream>

#include "mime/mailbox.hpp"
#include "mime/report.hpp"

using namespace mime;
namespace fs = std::filesystem;

namespace {

const char* kMbox =
    "From nobody Mon Sep  1 00:00:00 2025\n"
    "Subject: =?utf-8?Q?Caf=C3=A9?= report\n"
    "From: Ann Example <ann@example.com>\n"
    "To: bob@example.org, Carl <carl@example.org>\n"
    "Date: Mon, 1 Sep 2025 12:30:00 +0200\n"
    "MIME-Version: 1.0\n"
    "Content-Type: multipart/mixed; boundary=\"X\"\n"
    "\n"
    "ignore me\n"
    "--X\n"
    "Content-Type: text/plain; charset=iso-8859-1\n"
    "\n"
    "caf\xe9\n"
    "--X\n"
    "Content-Type: application/octet-stream\n"
    "Content-Disposition: attachment; filename=\"a.bin\"\n"
    "Content-Transfer-Encoding: base64\n"
    "\n"
    "AAECAw==\n"
    "--X--\n"
    "\n";

const char* kExpectedMessage =
    "[message]\n"
    "id 0001\n"
    "source \"mbox:1\"\n"
    "\n"
    "[headers]\n"
    "subject: \"Caf\xc3\xa9 report\"\n"
    "from: \"Ann Example <ann@example.com>\"\n"
    "to: \"bob@example.org, Carl <carl@example.org>\"\n"
    "date: \"Mon, 1 Sep 2025 12:30:00 +0200\"\n"
    "mime-version: \"1.0\"\n"
    "content-type: \"multipart/mixed; boundary=\\\"X\\\"\"\n"
    "\n"
    "[addresses]\n"
    "from 0 display=\"Ann Example\" spec=\"ann@example.com\"\n"
    "to 0 display=\"\" spec=\"bob@example.org\"\n"
    "to 1 display=\"Carl\" spec=\"carl@example.org\"\n"
    "\n"
    "[date]\n"
    "raw \" Mon, 1 Sep 2025 12:30:00 +0200\"\n"
    "valid yes\n"
    "utc 2025-09-01T10:30:00Z\n"
    "offset +0200\n"
    "epoch 1756722600\n"
    "\n"
    "[structure]\n"
    "0 multipart/mixed cte=7bit boundary=\"X\" parts=2 preamble=9 epilogue=0\n"
    "  1 text/plain charset=iso-8859-1 cte=7bit size=4 adler32=04680214 role=text\n"
    "  2 application/octet-stream cte=base64 disposition=attachment filename=\"a.bin\" size=4 "
    "adler32=000e0007 role=attachment\n"
    "\n"
    "[body]\n"
    "text 1 chars 4\n"
    "| caf\xc3\xa9\n"
    "html none\n"
    "\n"
    "[attachments]\n"
    "2 type=application/octet-stream filename=\"a.bin\" size=4 adler32=000e0007 "
    "file=parts/0001/002.bin\n";

std::string slurp(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

}  // namespace

TEST(Report, WorkedExample) {
  auto raw = split_mbox(kMbox);
  ASSERT_EQ(raw.size(), 1u);
  EXPECT_EQ(raw[0].bytes.size(), 427u);
  Message m = parse_message(raw[0].bytes, raw[0].source_id);
  EXPECT_EQ(render_message(m, 1), kExpectedMessage);
  EXPECT_EQ(render_summary({m}),
            "messages 1\n0001 source=\"mbox:1\" bytes=427 parts=3 attachments=1 text=1 html=-\n");
}

TEST(Report, BodyLines) {
  Message m = parse_message("Content-Type: text/plain\n\na\n\n\xc2\n", "s");
  std::string out = render_message(m, 7);
  EXPECT_NE(out.find("text 0 chars 5\n| a\n| \n| \xef\xbf\xbd\n"), std::string::npos) << out;
  // Empty text: no lines.
  Message e = parse_message("A: b\n\n", "s");
  EXPECT_NE(render_message(e, 1).find("text 0 chars 0\nhtml none\n"), std::string::npos);
}

TEST(Report, NoHeaders) {
  Message m = parse_message("", "s");
  std::string out = render_message(m, 1);
  EXPECT_NE(out.find("[headers]\n\n[addresses]\n\n[date]\nnone\n"), std::string::npos) << out;
}

TEST(Report, WritesTree) {
  fs::path base = fs::temp_directory_path() / "mime_report_test";
  fs::remove_all(base);
  fs::create_directories(base);
  {
    std::ofstream(base / "in.mbox", std::ios::binary) << kMbox;
  }
  process_mailbox(base / "in.mbox", base / "out");
  EXPECT_EQ(slurp(base / "out" / "messages" / "0001.txt"), kExpectedMessage);
  EXPECT_EQ(slurp(base / "out" / "parts" / "0001" / "002.bin"), std::string("\0\1\2\3", 4));
  EXPECT_TRUE(fs::exists(base / "out" / "summary.txt"));
  fs::remove_all(base);
}

TEST(Report, FormatNumber) {
  EXPECT_EQ(format_number(7, 4), "0007");
  EXPECT_EQ(format_number(12345, 4), "12345");
  EXPECT_EQ(attachment_path(3, 12), "parts/0003/012.bin");
}
