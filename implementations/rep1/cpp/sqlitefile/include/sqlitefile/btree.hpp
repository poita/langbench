#pragma once
/// \file btree.hpp
/// Reading table and index B-trees, including payload overflow chains.

#include <cstdint>
#include <functional>
#include <optional>
#include <vector>

#include "sqlitefile/pager.hpp"
#include "sqlitefile/record.hpp"
#include "sqlitefile/value.hpp"

namespace sqlitefile {

/// Which kind of B-tree page a cell lives on (it decides the overflow limit).
enum class CellKind { TableLeaf, Index };

/// Number of payload bytes stored on the B-tree page itself (SPEC.md §1.5).
/// `payload_size` is P and `usable_size` is U. When the result is smaller
/// than P the rest of the payload is on overflow pages.
std::uint32_t localPayloadSize(std::uint64_t payload_size, std::uint32_t usable_size,
                               CellKind kind);

/// A cell's complete payload, either a view into the page or, when the
/// payload overflowed, a reassembled copy.
class Payload {
 public:
  Payload() = default;
  static Payload view(ByteView v);
  static Payload owned(std::vector<std::uint8_t> bytes);
  ByteView bytes() const { return is_owned_ ? ByteView(owned_) : view_; }

 private:
  ByteView view_;
  std::vector<std::uint8_t> owned_;
  bool is_owned_ = false;
};

/// Walks B-trees stored in a Pager. Stateless apart from the pager reference;
/// nothing is cached between calls.
class BTreeReader {
 public:
  explicit BTreeReader(const Pager& pager) : pager_(pager) {}

  /// Called for each table row in ascending rowid order; return false to stop.
  using RowCallback = std::function<bool(std::int64_t rowid, const Payload&)>;
  /// Called for each matching index entry (all its decoded values, the rowid
  /// last).
  using EntryCallback = std::function<void(const std::vector<Value>& entry)>;

  /// Visits every row of the table B-tree rooted at `root`.
  void scanTable(std::uint32_t root, const RowCallback& cb) const;

  /// Counts rows by summing leaf cell counts; reads no records.
  std::uint64_t countTableRows(std::uint32_t root) const;

  /// Finds one row by rowid with a root-to-leaf search.
  std::optional<Payload> findTableRow(std::uint32_t root, std::int64_t rowid) const;

  /// Visits, in index order, every entry of the index B-tree whose first
  /// column equals `key` (by Part 3 comparison). `descending` says the first
  /// column was declared DESC, which reverses the tree's key order.
  void scanIndexEqual(std::uint32_t root, const Value& key, bool descending,
                      const EntryCallback& cb) const;

 private:
  const Pager& pager_;
};

}  // namespace sqlitefile
