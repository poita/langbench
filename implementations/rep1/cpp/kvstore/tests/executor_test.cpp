#include <gtest/gtest.h>

#include "tessera/executor.hpp"

using namespace tessera;

TEST(Executor, SplitLinesFollowsTheSpec) {
  EXPECT_EQ(split_lines("").size(), 0u);
  EXPECT_EQ(split_lines("a\nb\n").size(), 2u);
  EXPECT_EQ(split_lines("a\nb").size(), 2u);
  EXPECT_EQ(split_lines("a\nb\n\n").size(), 3u);
  EXPECT_EQ(split_lines("\n").size(), 1u);
}

TEST(Executor, SmallScriptFromTheSpec) {
  Database db;
  std::string out = run_script(db,
                               "put \"b\" 2\n"
                               "put \"a\" {name:\"ada\",age:36}\n"
                               "get \"a\"\n"
                               "scan\n"
                               "stat\n");
  EXPECT_EQ(out,
            "[1] ok put created\n"
            "[2] ok put created\n"
            "[3] ok get value\n"
            "  {\"age\":36,\"name\":\"ada\"}\n"
            "[4] ok scan 2\n"
            "  \"a\" = {\"age\":36,\"name\":\"ada\"}\n"
            "  \"b\" = 2\n"
            "[5] ok stat\n"
            "  pages 2\n  free 0\n  freehead 0\n  docs 2\n  root 2\n  height 1\n"
            "  commits 2\n  indexes 0\n  wal 4272\n");
}

TEST(Executor, ErrorsDoNotStopTheScript) {
  Database db;
  std::string out = run_script(db, "\nbogus\nget \"x\"\nput \"a\" 1\ncommit\n");
  EXPECT_EQ(out,
            "[1] error syntax\n[2] error unknown-command\n[3] error not-found\n"
            "[4] ok put created\n[5] error no-txn\n");
}

TEST(Executor, OpenTransactionIsRolledBackAtTheEnd) {
  Database db;
  run_script(db, "begin\nput \"a\" 1\n");
  EXPECT_FALSE(db.in_transaction());
  EXPECT_FALSE(db.get("a"));
  EXPECT_EQ(db.wal_file().size(), 32u);
}

TEST(Executor, TransactionStatusLines) {
  Database db;
  std::string out = run_script(db,
                               "begin\nput \"a\" 1\nstat\ncommit\nbegin\nrollback\ncheckpoint\n");
  EXPECT_NE(out.find("[4] ok commit 1 frames 2\n"), std::string::npos);
  EXPECT_NE(out.find("[6] ok rollback\n"), std::string::npos);
  EXPECT_NE(out.find("[7] ok checkpoint pages 2\n"), std::string::npos);
  EXPECT_NE(out.find("  wal 32\n"), std::string::npos);  // uncommitted pages are not counted
}

TEST(Executor, IndexCommandsReportPaths) {
  Database db;
  std::string out = run_script(db,
                               "put \"u1\" {a:{b:1}}\ncreate index a . b\nindexes\ndrop index a.b\nindexes\n");
  EXPECT_NE(out.find("[2] ok create index a.b entries 1\n"), std::string::npos);
  EXPECT_NE(out.find("  0 a.b root 3 entries 1\n"), std::string::npos);
  EXPECT_NE(out.find("[4] ok drop index a.b pages 1\n"), std::string::npos);
  EXPECT_NE(out.find("[5] ok indexes 0\n"), std::string::npos);
}
