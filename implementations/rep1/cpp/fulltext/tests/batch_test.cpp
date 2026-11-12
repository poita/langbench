#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>

#include "fulltext/batch.hpp"
#include "fulltext/corpus.hpp"

using namespace fulltext;
namespace fs = std::filesystem;

TEST(QueryFile, DirectivesCommentsAndNumbering) {
  const auto q = parse_query_file(
      "# a comment\n"
      "\n"
      "first query\n"
      "%k 3\n"
      "  second query  \r\n"
      "%k\t\t25 \n"
      "%kk 5\n"
      "%k 5x\n"
      "last");
  ASSERT_EQ(q.size(), 5u);
  EXPECT_EQ(q[0].number, 1u);
  EXPECT_EQ(q[0].text, "first query");
  EXPECT_EQ(q[0].k, 10u);
  EXPECT_EQ(q[1].text, "second query");
  EXPECT_EQ(q[1].k, 3u);
  EXPECT_EQ(q[2].text, "%kk 5");  // not a directive shape: an ordinary query
  EXPECT_EQ(q[2].k, 25u);
  EXPECT_EQ(q[3].text, "%k 5x");
  EXPECT_EQ(q[4].number, 5u);
  EXPECT_EQ(q[4].text, "last");
}

TEST(QueryFile, EmptyFile) { EXPECT_TRUE(parse_query_file("").empty()); }

TEST(Output, StatsFormat) {
  const Index idx = Index::build({{"note", "The quick brown fox jumps over the lazy dog."}});
  EXPECT_EQ(format_stats(idx), "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n");
  EXPECT_EQ(format_stats(Index::build({})), "documents 0\ntokens 0\nterms 0\navgdl 0.0000\n");
}

TEST(Output, ResultsFormat) {
  const Index idx = Index::build({{"note", "The quick brown fox jumps over the lazy dog."}});
  const Searcher s(idx);
  const auto q = parse_query_file("fox\ncat\n");
  EXPECT_EQ(format_results(s, q),
            "QUERY 1 fox\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n"
            "QUERY 2 cat\nHITS 0\n");
}

TEST(RunDirectory, EndToEnd) {
  const fs::path root = fs::temp_directory_path() / "fulltext_batch_test";
  fs::remove_all(root);
  fs::create_directories(root / "in" / "docs" / "sub");
  const auto put = [](const fs::path& p, const std::string& s) { std::ofstream(p, std::ios::binary) << s; };
  put(root / "in" / "docs" / "b.txt", "beta alpha");
  put(root / "in" / "docs" / "a.txt", "alpha");
  put(root / "in" / "docs" / "ignored.md", "alpha");
  put(root / "in" / "queries.txt", "alpha\n");
  run_directory(root / "in", root / "out");
  EXPECT_EQ(read_file(root / "out" / "results.txt"),
            "QUERY 1 alpha\nHITS 2\n1\ta\t0.2111\talpha\n2\tb\t0.1604\tbeta alpha\n");
  EXPECT_EQ(read_file(root / "out" / "stats.txt"), "documents 2\ntokens 3\nterms 2\navgdl 1.5000\n");
  fs::remove_all(root);
}

TEST(RunDirectory, MissingDocsDirectoryIsEmptyCorpus) {
  const fs::path root = fs::temp_directory_path() / "fulltext_batch_test2";
  fs::remove_all(root);
  fs::create_directories(root / "in");
  std::ofstream(root / "in" / "queries.txt") << "anything\n";
  run_directory(root / "in", root / "out");
  EXPECT_EQ(read_file(root / "out" / "results.txt"), "QUERY 1 anything\nHITS 0\n");
  fs::remove_all(root);
}
