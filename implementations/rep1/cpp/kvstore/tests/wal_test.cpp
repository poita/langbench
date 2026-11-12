#include <gtest/gtest.h>

#include "tessera/crc32.hpp"
#include "tessera/database.hpp"
#include "tessera/executor.hpp"
#include "tessera/wal.hpp"

using namespace tessera;

static std::string hex(const std::uint8_t* p, std::size_t n) {
  static const char* d = "0123456789abcdef";
  std::string out;
  for (std::size_t i = 0; i < n; ++i) {
    out += d[p[i] >> 4];
    out += d[p[i] & 15];
  }
  return out;
}

TEST(Wal, EmptyLogIsTheSpecHeader) {
  Wal wal;
  ASSERT_EQ(wal.size(), 32u);
  EXPECT_EQ(hex(wal.bytes().data(), 32),
            "5445535357414c31000104000000000000000000000000000000000051e72153");
}

TEST(Wal, FirstCommitRecordHeadersMatchSpec) {
  Database db;
  db.put("a", Value::integer(1));
  const auto& b = db.wal_file();
  ASSERT_EQ(b.size(), 2152u);
  EXPECT_EQ(hex(&b[32], 24), "010000000000000000000001000000010000040076292e36");
  EXPECT_EQ(hex(&b[32 + 1048], 24), "0100000000000000000000010000000200000400760d60f7");
  EXPECT_EQ(hex(&b[32 + 2096], 24), "0200000000000000000000010000000200000000a8a0aa22");
}

TEST(Wal, DamagedHeaderDiscardsEverything) {
  Database db;
  db.put("a", Value::integer(1));
  auto bytes = db.wal_file();
  bytes[12] = 1;  // reserved byte must be zero
  WalRecovery rec = Wal::recover(bytes);
  EXPECT_TRUE(rec.images.empty());
  EXPECT_EQ(rec.wal.size(), 32u);
  EXPECT_EQ(Wal::recover({}).wal.size(), 32u);
}

TEST(Wal, TruncationKeepsOnlyWholeTransactions) {
  Database db;
  db.put("a", Value::integer(1));
  db.put("b", Value::integer(2));
  const auto full = db.wal_file();
  ASSERT_EQ(full.size(), 4272u);
  for (std::size_t cut = 0; cut <= full.size(); ++cut) {
    std::vector<std::uint8_t> part(full.begin(), full.begin() + static_cast<std::ptrdiff_t>(cut));
    WalRecovery rec = Wal::recover(part);
    std::size_t expect = cut >= 4272 ? 4272 : cut >= 2152 ? 2152 : 32;
    EXPECT_EQ(rec.wal.size(), expect) << "cut at " << cut;
    EXPECT_EQ(rec.images.size(), expect == 4272 ? 4u : expect == 2152 ? 2u : 0u);
  }
}

TEST(Wal, TrailingGarbageIsTrimmed) {
  Database db;
  db.put("a", Value::integer(1));
  auto bytes = db.wal_file();
  bytes.insert(bytes.end(), 100, 0);
  EXPECT_EQ(Wal::recover(bytes).wal.size(), 2152u);
}

TEST(Wal, WrongFrameCountStopsTheScan) {
  Database db;
  db.put("a", Value::integer(1));
  auto bytes = db.wal_file();
  // Rewrite the commit record's frame_count (3 instead of 2) with a valid CRC.
  std::size_t at = 32 + 2096;
  put32(&bytes[at + 12], 3);
  put32(&bytes[at + 20], crc32(&bytes[at], 20));
  EXPECT_EQ(Wal::recover(bytes).wal.size(), 32u);
}

TEST(Recovery, ReplayedLogGivesTheSameDatabase) {
  Database db;
  run_script(db, "put \"a\" 1\nput \"b\" {x:[1,2]}\ncreate index x\n");
  DatabaseImage image{db.main_file(), db.wal_file()};
  Database reopened(image);
  EXPECT_EQ(run_script(reopened, "scan\nstat\n"), run_script(db, "scan\nstat\n"));
  EXPECT_EQ(reopened.main_file(), db.main_file());
  EXPECT_EQ(reopened.wal_file(), db.wal_file());
}
