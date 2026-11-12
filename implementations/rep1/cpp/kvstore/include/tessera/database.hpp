#pragma once
/// \file database.hpp
/// The embedded document store: documents keyed by byte strings, secondary
/// indexes on field paths, transactions, a write-ahead log, checkpointing and
/// crash recovery.
///
/// All failures are reported by throwing `tessera::Error`; a failing operation
/// leaves the database untouched.

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "tessera/btree.hpp"
#include "tessera/error.hpp"
#include "tessera/pager.hpp"
#include "tessera/query.hpp"
#include "tessera/scan_options.hpp"
#include "tessera/value.hpp"
#include "tessera/wal.hpp"

namespace tessera {

/// The two files that make up a database.
struct DatabaseImage {
  std::vector<std::uint8_t> main;  ///< `main.tdb`; empty means a fresh database
  std::vector<std::uint8_t> wal;   ///< `main.twal`; empty or damaged means no log
};

struct CommitInfo {
  std::uint64_t txn_id = 0;
  std::uint32_t frames = 0;  ///< page images appended to the log
};

/// A key and, unless the scan was keys-only, its document.
struct Entry {
  std::string key;
  std::optional<Value> doc;
};

struct FindResult {
  Plan plan;
  std::vector<Entry> entries;
};

struct IndexInfo {
  std::uint32_t slot = 0;
  std::string path;
  std::uint32_t root = 0;
  std::uint32_t entries = 0;
};

struct Stats {
  std::uint32_t pages = 0;
  std::uint32_t free_pages = 0;
  std::uint32_t free_head = 0;
  std::uint32_t docs = 0;
  std::uint32_t root = 0;
  std::size_t height = 0;
  std::uint64_t commits = 0;
  std::uint32_t indexes = 0;
  std::size_t wal_size = 0;
};

class Database {
 public:
  /// Opens a database, replaying the committed transactions of the log and
  /// trimming the rest (spec section 16). Does not modify the main file.
  explicit Database(DatabaseImage image = {});

  // ---- transactions ----
  void begin();
  CommitInfo commit();
  void rollback();
  /// Copies the log into the main file; returns the number of pages copied.
  std::size_t checkpoint();
  bool in_transaction() const { return in_txn_; }

  // ---- documents ----
  /// Stores `doc` under `key`; returns true if the key was new.
  bool put(std::string_view key, const Value& doc);
  std::optional<Value> get(std::string_view key) const;
  void erase(std::string_view key);
  void update(std::string_view key, const Path& path, Value value);
  void unset(std::string_view key, const Path& path);

  // ---- queries ----
  std::vector<Entry> scan(const ScanOptions& options) const;
  FindResult find(const Predicate& pred, std::optional<std::int64_t> limit) const;

  // ---- indexes ----
  /// Builds an index; returns the number of entries.
  std::uint32_t create_index(const Path& path);
  /// Drops an index; returns the number of pages freed.
  std::size_t drop_index(const Path& path);
  std::vector<IndexInfo> indexes() const;

  Stats stats() const;

  /// The files as they would be written now (uncommitted changes excluded).
  const std::vector<std::uint8_t>& main_file() const { return pager_.main_file(); }
  const std::vector<std::uint8_t>& wal_file() const { return wal_.bytes(); }

 private:
  BTree primary() const;
  BTree index_tree(std::size_t slot) const;
  Value read_document(const Cell& cell) const;
  Cell make_cell(std::string_view key, const std::string& bytes);
  void check_index_keys(std::string_view key, const Value& doc) const;
  bool store_document(std::string_view key, const Value& doc, const std::string& bytes);
  void update_indexes(std::string_view key, const Value* old_doc, const Value* new_doc);
  void index_insert(std::size_t slot, const std::string& entry);
  void index_erase(std::size_t slot, const std::string& entry);
  CommitInfo commit_internal();
  std::size_t checkpoint_internal();

  template <typename F>
  auto write_txn(F&& body);

  mutable Pager pager_;
  Wal wal_;
  bool in_txn_ = false;
};

}  // namespace tessera
