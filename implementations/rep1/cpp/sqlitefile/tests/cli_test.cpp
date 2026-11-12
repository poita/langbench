// End-to-end test of the command-line tool on a database built in memory.

#include <gtest/gtest.h>

#include <unistd.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "db_builder.hpp"

namespace fs = std::filesystem;
using namespace sqlitefile;
using testsupport::DbBuilder;

namespace {

std::string slurp(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

class CliTest : public ::testing::Test {
 protected:
  void SetUp() override {
    root_ = fs::temp_directory_path() /
            ("sqlitefile_cli_test_" + std::to_string(::getpid()) + "_" +
             ::testing::UnitTest::GetInstance()->current_test_info()->name());
    fs::remove_all(root_);
    fs::create_directories(root_ / "in");
    fs::create_directories(root_ / "out");
  }
  void TearDown() override { fs::remove_all(root_); }

  int run() {
    std::string cmd = std::string("\"") + SQLITEFILE_CLI_PATH + "\" \"" + (root_ / "in").string() +
                      "\" \"" + (root_ / "out").string() + "\"";
    return std::system(cmd.c_str());
  }

  fs::path root_;
};

}  // namespace

TEST_F(CliTest, WritesOneNumberedFilePerQuery) {
  DbBuilder b;
  b.addTable("t", "CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT)",
             {{1, {Value::null(), Value::text("x")}}, {2, {Value::null(), Value::text("y")}}});
  auto bytes = b.build();
  {
    std::ofstream db(root_ / "in" / "data.sqlite", std::ios::binary);
    db.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    std::ofstream q(root_ / "in" / "queries.txt", std::ios::binary);
    q << ".tables\nSELECT * FROM t\nCOUNT nosuch\nSELECT b FROM t WHERE a = 99";  // no final LF
  }
  EXPECT_EQ(run(), 0);
  EXPECT_EQ(slurp(root_ / "out" / "001.txt"), "t\n");
  EXPECT_EQ(slurp(root_ / "out" / "002.txt"), "1\tx\n2\ty\n");
  EXPECT_EQ(slurp(root_ / "out" / "003.txt"), "error\n");
  EXPECT_TRUE(fs::exists(root_ / "out" / "004.txt"));
  EXPECT_EQ(slurp(root_ / "out" / "004.txt"), "");
  std::size_t files = 0;
  for (auto& e : fs::directory_iterator(root_ / "out")) { (void)e; ++files; }
  EXPECT_EQ(files, 4u);
}

TEST_F(CliTest, UnreadableDatabaseGivesErrorsAndExitsZero) {
  {
    std::ofstream db(root_ / "in" / "bad.sqlite", std::ios::binary);
    db << "this is not a database";
    std::ofstream q(root_ / "in" / "queries.txt", std::ios::binary);
    q << ".tables\nCOUNT t\n";
  }
  EXPECT_EQ(run(), 0);
  EXPECT_EQ(slurp(root_ / "out" / "001.txt"), "error\n");
  EXPECT_EQ(slurp(root_ / "out" / "002.txt"), "error\n");
}
