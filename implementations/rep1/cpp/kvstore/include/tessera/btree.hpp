#pragma once
/// \file btree.hpp
/// The B+tree used for both the primary tree and secondary index trees
/// (spec section 12). Pages are canonical; splits, borrows and merges follow
/// the specification exactly so that page numbers and bytes are reproducible.

#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "tessera/node.hpp"
#include "tessera/pager.hpp"

namespace tessera {

/// A view of one tree. The tree's root page number lives in `root`, a reference
/// into the header (`primary_root` or a directory slot's `root`).
class BTree {
 public:
  enum class Kind { Primary, Index };

  BTree(Pager& pager, std::uint32_t& root, Kind kind);

  /// The cell whose key equals `key`, if any.
  std::optional<Cell> find(std::string_view key) const;

  /// Inserts a cell, or replaces the cell with the same key in place (12.2).
  void insert(Cell cell);

  /// Deletes `key` with underflow handling (12.4, 12.5). Returns false if absent.
  bool erase(std::string_view key);

  /// Visits cells with key >= `lower` in ascending order via the leaf chain;
  /// stops as soon as the visitor returns false.
  void scan_from(std::string_view lower, const std::function<bool(const Cell&)>& visit) const;

  /// Visits cells in descending key order, starting below `upper_exclusive`
  /// when given; stops as soon as the visitor returns false.
  void scan_reverse(const std::optional<std::string>& upper_exclusive,
                    const std::function<bool(const Cell&)>& visit) const;

  /// Frees every page of the tree in post-order (12.6); returns the page count.
  std::size_t free_all();

  /// 0 for an empty tree, 1 for a single leaf, and so on (12.7).
  std::size_t height() const;

 private:
  struct Frame {
    std::uint32_t page;
    Node node;
    std::size_t index;  ///< child index taken (n for the link)
  };

  PageType leaf_type() const {
    return kind_ == Kind::Primary ? PageType::PrimaryLeaf : PageType::IndexLeaf;
  }
  Node load(std::uint32_t page) const { return decode_node(pager_.read(page)); }
  void store(std::vector<Frame>& path, std::uint32_t page, Node node);
  void rebalance(std::vector<Frame>& path, std::uint32_t page, Node node);
  std::uint32_t descend(std::string_view key, std::vector<Frame>& path, Node& leaf) const;
  bool reverse_visit(std::uint32_t page, const std::optional<std::string>& upper,
                     const std::function<bool(const Cell&)>& visit) const;
  void free_subtree(std::uint32_t page, std::size_t& count);

  Pager& pager_;
  std::uint32_t& root_;
  Kind kind_;
};

}  // namespace tessera
