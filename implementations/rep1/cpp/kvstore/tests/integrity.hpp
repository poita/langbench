#pragma once
// Test helper: checks the structural invariants of a database file.

#include <gtest/gtest.h>

#include <map>
#include <set>
#include <string>
#include <vector>

#include "tessera/database.hpp"
#include "tessera/header.hpp"
#include "tessera/index_key.hpp"
#include "tessera/node.hpp"
#include "tessera/overflow.hpp"

namespace testing_util {

using namespace tessera;

class Checker {
 public:
  // `parse_docs` = false skips deserialising documents (for trees of opaque cells).
  explicit Checker(const std::vector<std::uint8_t>& file, bool parse_docs = true)
      : file_(file), parse_docs_(parse_docs) {}

  // Verifies the whole file; returns the documents found, in key order.
  std::map<std::string, Value> run() {
    Page p1 = page(1);
    h_ = Header::decode(p1);
    EXPECT_EQ(file_.size(), std::size_t(h_.page_count) * kPageSize);
    EXPECT_TRUE(p1 == h_.encode()) << "page 1 is not canonical";
    used_.insert(1);

    std::map<std::string, Value> docs;
    if (h_.primary_root) {
      std::string prev;
      bool have_prev = false;
      std::size_t leaf_depth = 0;
      walk(h_.primary_root, std::nullopt, std::nullopt, 1, leaf_depth, true, true,
           [&](const Cell& c) {
             std::string bytes = c.inline_data;
             if (c.overflow) bytes += chain(c.overflow);
             EXPECT_EQ(bytes.size(), c.doc_len);
             docs.emplace(c.key, parse_docs_ ? deserialize(bytes) : Value());
             if (have_prev) EXPECT_LT(prev, c.key);
             prev = c.key;
             have_prev = true;
           });
      check_leaf_chain(h_.primary_root);
    }
    EXPECT_EQ(docs.size(), h_.primary_count);

    for (const auto& slot : h_.slots) {
      if (!slot.live) continue;
      std::set<std::string> found;
      if (slot.root) {
        std::size_t leaf_depth = 0;
        walk(slot.root, std::nullopt, std::nullopt, 1, leaf_depth, false, true,
             [&](const Cell& c) { found.insert(c.key); });
        check_leaf_chain(slot.root);
      }
      std::set<std::string> expect;
      Path path = split_path_text(slot.path);
      for (const auto& [k, d] : docs) {
        auto e = index_entry_key(d, path, k);
        if (e) expect.insert(*e);
      }
      EXPECT_EQ(found, expect) << "index " << slot.path;
      EXPECT_EQ(found.size(), slot.entries);
    }

    // free list
    std::uint32_t n = 0;
    for (std::uint32_t p = h_.freelist_head; p != 0 && n <= h_.page_count; ++n) {
      Page pg = page(p);
      EXPECT_EQ(pg[0], 0);
      EXPECT_TRUE(used_.insert(p).second) << "page " << p << " is both free and in use";
      p = get32(&pg[4]);
    }
    EXPECT_EQ(n, h_.freelist_count);
    EXPECT_EQ(used_.size(), h_.page_count) << "leaked or double-counted pages";
    return docs;
  }

 private:
  Page page(std::uint32_t no) const {
    Page p{};
    EXPECT_GE(no, 1u);
    EXPECT_LE(std::size_t(no) * kPageSize, file_.size());
    std::copy_n(file_.begin() + (std::size_t(no) - 1) * kPageSize, kPageSize, p.begin());
    return p;
  }

  std::string chain(std::uint32_t first) {
    std::string out;
    for (std::uint32_t p = first; p;) {
      EXPECT_TRUE(used_.insert(p).second);
      Page pg = page(p);
      EXPECT_EQ(pg[0], 3);
      std::size_t len = get16(&pg[8]);
      EXPECT_GE(len, 1u);
      out.append(reinterpret_cast<const char*>(&pg[12]), len);
      for (std::size_t i = 12 + len; i < kPageSize; ++i) EXPECT_EQ(pg[i], 0);
      p = get32(&pg[4]);
    }
    return out;
  }

  template <typename F>
  void walk(std::uint32_t no, std::optional<std::string> lo, std::optional<std::string> hi,
            std::size_t depth, std::size_t& leaf_depth, bool primary, bool is_root, F&& visit) {
    EXPECT_TRUE(used_.insert(no).second) << "page " << no << " reachable twice";
    Page pg = page(no);
    Node node = decode_node(pg);
    EXPECT_TRUE(encode_node(node) == pg) << "page " << no << " is not canonical";
    EXPECT_LE(tessera::used(node), kCapacity);
    if (!is_root) EXPECT_FALSE(node.cells.empty()) << "empty non-root page " << no;
    for (std::size_t i = 1; i < node.cells.size(); ++i)
      EXPECT_LT(node.cells[i - 1].key, node.cells[i].key);
    if (node.is_leaf()) {
      EXPECT_EQ(node.type, primary ? PageType::PrimaryLeaf : PageType::IndexLeaf);
      if (leaf_depth == 0) leaf_depth = depth;
      EXPECT_EQ(leaf_depth, depth) << "leaves at different depths";
      for (const Cell& c : node.cells) {
        if (lo) EXPECT_GT(c.key, *lo);
        if (hi) EXPECT_LE(c.key, *hi);
        visit(c);
      }
      return;
    }
    std::optional<std::string> low = lo;
    for (const Cell& c : node.cells) {
      walk(c.child, low, c.key, depth + 1, leaf_depth, primary, false, visit);
      low = c.key;
    }
    walk(node.link, low, hi, depth + 1, leaf_depth, primary, false, visit);
  }

  // Following `link` from the leftmost leaf must visit leaves in key order.
  void check_leaf_chain(std::uint32_t root) {
    std::uint32_t p = root;
    while (true) {
      Node n = decode_node(page(p));
      if (n.is_leaf()) break;
      p = n.cells.empty() ? n.link : n.cells[0].child;
    }
    std::string prev;
    bool first = true;
    std::size_t guard = 0;
    while (p && guard++ <= file_.size()) {
      Node n = decode_node(page(p));
      for (const auto& c : n.cells) {
        if (!first) EXPECT_LT(prev, c.key);
        prev = c.key;
        first = false;
      }
      p = n.link;
    }
  }

  const std::vector<std::uint8_t>& file_;
  bool parse_docs_;
  Header h_;
  std::set<std::uint32_t> used_;
};

/// Checkpoints a copy of the database's committed state and verifies it.
inline std::map<std::string, Value> check_integrity(const Database& db) {
  DatabaseImage image{db.main_file(), db.wal_file()};
  Database copy(std::move(image));
  copy.checkpoint();
  return Checker(copy.main_file()).run();
}

}  // namespace testing_util
