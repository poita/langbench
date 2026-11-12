// End-to-end tests of the command-line tool via popen().

#include <gtest/gtest.h>

#include <cstdio>
#include <string>

namespace {

std::string run_cli(const std::string& input_hex) {
  const std::string cmd = std::string("printf '%s\\n' '") + input_hex + "' | '" + INFLATE_CLI_PATH + "'";
  std::FILE* p = popen(cmd.c_str(), "r");
  EXPECT_NE(p, nullptr);
  std::string out;
  char buf[4096];
  std::size_t n;
  while (p && (n = std::fread(buf, 1, sizeof buf, p)) > 0) out.append(buf, n);
  if (p) EXPECT_EQ(pclose(p), 0);
  return out;
}

}  // namespace

TEST(Cli, EmptyResultPrintsEmptyLine) { EXPECT_EQ(run_cli("0300"), "\n"); }
TEST(Cli, StoredBlock) { EXPECT_EQ(run_cli("010100feff41"), "41\n"); }
TEST(Cli, FixedBlockWithCopy) { EXPECT_EQ(run_cli("4b4c4a862000"), "616263616263616263\n"); }
TEST(Cli, MalformedPrintsErrorAndExitsZero) {
  EXPECT_EQ(run_cli("030200"), "error\n");
  EXPECT_EQ(run_cli(""), "error\n");
}
