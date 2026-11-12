#pragma once
/// \file node.hpp
/// In-memory B+tree pages and their canonical encoding (spec section 11).

#include <cstdint>
#include <string>
#include <vector>

#include "tessera/page.hpp"

namespace tessera {

/// One cell of a B+tree page. Which fields are meaningful depends on the page type:
///  - primary leaf: key, doc_len, overflow, inline_data
///  - interior:     key (a high-key separator), child
///  - index leaf:   key only
struct Cell {
  std::string key;
  std::uint32_t child = 0;
  std::uint32_t doc_len = 0;
  std::uint32_t overflow = 0;
  std::string inline_data;
};

/// The logical content of a B+tree page.
struct Node {
  PageType type = PageType::PrimaryLeaf;
  std::vector<Cell> cells;
  /// Interior: rightmost child. Leaf: next leaf (0 for the last).
  std::uint32_t link = 0;

  bool is_leaf() const { return type != PageType::Interior; }
};

/// Encoded size of a cell on a page of the given type.
std::size_t cell_size(PageType type, const Cell& cell);
/// Cell size plus its 2-byte pointer.
inline std::size_t cell_cost(PageType type, const Cell& cell) { return cell_size(type, cell) + 2; }
/// Payload size of a page: 2n + the sum of cell sizes.
std::size_t used(const Node& node);

/// Canonical encoding; `used(node)` must not exceed the capacity.
Page encode_node(const Node& node);
Node decode_node(const Page& page);

}  // namespace tessera
