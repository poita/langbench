#include <gtest/gtest.h>

#include <map>
#include <random>

#include "integrity.hpp"
#include "tessera/btree.hpp"

using namespace tessera;

namespace {

Cell make(const std::string& key, std::size_t inline_len) {
  Cell c;
  c.key = key;
  c.doc_len = static_cast<std::uint32_t>(inline_len);
  c.inline_data = std::string(inline_len, 'x');
  return c;
}

// Commits the pager's pending pages and verifies the resulting file.
void verify(Pager& pager, std::size_t expected_docs) {
  pager.header().primary_count = static_cast<std::uint32_t>(expected_docs);
  pager.stage_header();
  pager.commit_dirty();
  pager.checkpoint();
  auto docs = testing_util::Checker(pager.main_file(), /*parse_docs=*/false).run();
  (void)docs;
}

}  // namespace

TEST(BTree, EmptyTree) {
  Pager pager({});
  BTree t(pager, pager.header().primary_root, BTree::Kind::Primary);
  EXPECT_FALSE(t.find("a"));
  EXPECT_FALSE(t.erase("a"));
  EXPECT_EQ(t.height(), 0u);
}

TEST(BTree, SplitsAtTheSpecifiedPoint) {
  // Each cell costs 12 + 1 + 192 + 2 = 207 bytes: four fit (828), five do not (1035).
  Pager pager({});
  BTree t(pager, pager.header().primary_root, BTree::Kind::Primary);
  for (char k : {'a', 'b', 'c', 'd'}) t.insert(make(std::string(1, k), 192));
  EXPECT_EQ(t.height(), 1u);
  t.insert(make("e", 192));
  EXPECT_EQ(t.height(), 2u);
  // P = 0, 207, 414, 621, ...: the smallest m with 2*P[m] >= 1035 is 3.
  Node root = decode_node(pager.read(pager.header().primary_root));
  ASSERT_EQ(root.cells.size(), 1u);
  EXPECT_EQ(root.cells[0].key, "c");
  EXPECT_EQ(decode_node(pager.read(root.cells[0].child)).cells.size(), 3u);
  EXPECT_EQ(decode_node(pager.read(root.link)).cells.size(), 2u);
  // Allocation order: leaf (2), right sibling (3), new root (4).
  EXPECT_EQ(root.link, 3u);
  EXPECT_EQ(pager.header().primary_root, 4u);
}

TEST(BTree, RandomInsertEraseAgainstModel) {
  for (unsigned seed = 1; seed <= 6; ++seed) {
    std::mt19937 rng(seed);
    Pager pager({});
    BTree t(pager, pager.header().primary_root, BTree::Kind::Primary);
    std::map<std::string, std::size_t> model;
    auto key = [&] {
      std::size_t len = 1 + rng() % (seed % 2 ? 6 : 100);
      std::string k;
      for (std::size_t i = 0; i < len; ++i) k.push_back(static_cast<char>('a' + rng() % 6));
      return k;
    };
    for (int step = 0; step < 4000; ++step) {
      std::string k = key();
      if (rng() % 100 < (step < 1500 ? 80 : 35)) {
        std::size_t len = rng() % 193;
        t.insert(make(k, len));
        model[k] = len;
      } else {
        EXPECT_EQ(t.erase(k), model.erase(k) == 1);
      }
      if (step % 500 == 499) verify(pager, model.size());
    }
    // contents
    std::vector<std::string> seen;
    t.scan_from("", [&](const Cell& c) {
      seen.push_back(c.key);
      EXPECT_EQ(c.inline_data.size(), model.at(c.key));
      return true;
    });
    std::vector<std::string> expect;
    for (auto& [k, v] : model) expect.push_back(k);
    EXPECT_EQ(seen, expect);

    // reverse scans with and without a bound
    std::vector<std::string> rev;
    t.scan_reverse(std::nullopt, [&](const Cell& c) { rev.push_back(c.key); return true; });
    EXPECT_EQ(rev, std::vector<std::string>(expect.rbegin(), expect.rend()));
    if (!expect.empty()) {
      std::string bound = expect[expect.size() / 2];
      std::vector<std::string> below;
      t.scan_reverse(bound, [&](const Cell& c) { below.push_back(c.key); return true; });
      std::vector<std::string> want;
      for (auto it = expect.rbegin(); it != expect.rend(); ++it)
        if (*it < bound) want.push_back(*it);
      EXPECT_EQ(below, want);
    }
    // drain the tree completely
    for (auto& k : expect) EXPECT_TRUE(t.erase(k));
    EXPECT_EQ(pager.header().primary_root, 0u);
    verify(pager, 0);
  }
}

TEST(BTree, ScanFromLowerBound) {
  Pager pager({});
  BTree t(pager, pager.header().primary_root, BTree::Kind::Primary);
  for (int i = 0; i < 500; ++i) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "k%04d", i * 2);
    t.insert(make(buf, 100));
  }
  std::vector<std::string> got;
  t.scan_from("k0101", [&](const Cell& c) {
    got.push_back(c.key);
    return got.size() < 3;
  });
  EXPECT_EQ(got, (std::vector<std::string>{"k0102", "k0104", "k0106"}));
}

TEST(BTree, FreeAllIsPostOrder) {
  Pager pager({});
  BTree t(pager, pager.header().primary_root, BTree::Kind::Primary);
  for (int i = 0; i < 40; ++i) t.insert(make(std::string(1, char('A' + i)), 150));
  std::size_t pages = pager.header().page_count - 1;
  std::uint32_t root = pager.header().primary_root;
  EXPECT_EQ(t.free_all(), pages);
  EXPECT_EQ(pager.header().freelist_count, pages);
  EXPECT_EQ(pager.header().primary_root, 0u);
  // Post-order: the root is freed last, so it heads the free list.
  EXPECT_EQ(pager.header().freelist_head, root);
}
