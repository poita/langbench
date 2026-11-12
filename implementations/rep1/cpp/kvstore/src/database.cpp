#include "tessera/database.hpp"

#include <algorithm>
#include <limits>

#include "tessera/error.hpp"
#include "tessera/index_key.hpp"
#include "tessera/limits.hpp"
#include "tessera/overflow.hpp"

namespace tessera {

Database::Database(DatabaseImage image) : pager_(std::move(image.main)) {
  WalRecovery rec = Wal::recover(image.wal);
  wal_ = std::move(rec.wal);
  pager_.apply_recovered(rec.images);
}

// ---- transactions --------------------------------------------------------

void Database::begin() {
  if (in_txn_) throw Error(ErrorKind::TxnActive);
  in_txn_ = true;
}

CommitInfo Database::commit() {
  if (!in_txn_) throw Error(ErrorKind::NoTxn);
  return commit_internal();
}

void Database::rollback() {
  if (!in_txn_) throw Error(ErrorKind::NoTxn);
  pager_.discard_dirty();
  in_txn_ = false;
}

std::size_t Database::checkpoint() {
  if (in_txn_) throw Error(ErrorKind::TxnActive);
  return checkpoint_internal();
}

CommitInfo Database::commit_internal() {
  Header& h = pager_.header();
  ++h.commit_counter;
  pager_.stage_header();
  CommitInfo info;
  info.txn_id = h.commit_counter;
  info.frames = static_cast<std::uint32_t>(pager_.dirty().size());
  wal_.append_commit(info.txn_id, pager_.dirty());
  pager_.commit_dirty();
  in_txn_ = false;
  if (wal_.size() >= kWalLimit) checkpoint_internal();
  return info;
}

std::size_t Database::checkpoint_internal() {
  std::size_t n = pager_.checkpoint();
  wal_.reset();
  return n;
}

// Runs `body` inside the open transaction, or inside an implicit one that is
// committed on success and discarded on failure.
template <typename F>
auto Database::write_txn(F&& body) {
  bool implicit = !in_txn_;
  if (implicit) in_txn_ = true;
  try {
    if constexpr (std::is_void_v<decltype(body())>) {
      body();
      if (implicit) commit_internal();
    } else {
      auto result = body();
      if (implicit) commit_internal();
      return result;
    }
  } catch (...) {
    if (implicit) {
      pager_.discard_dirty();
      in_txn_ = false;
    }
    throw;
  }
}

// ---- helpers -------------------------------------------------------------

BTree Database::primary() const {
  return BTree(pager_, pager_.header().primary_root, BTree::Kind::Primary);
}

BTree Database::index_tree(std::size_t slot) const {
  return BTree(pager_, pager_.header().slots[slot].root, BTree::Kind::Index);
}

Value Database::read_document(const Cell& cell) const {
  if (cell.overflow == 0) return deserialize(cell.inline_data);
  return deserialize(cell.inline_data + read_overflow_chain(pager_, cell.overflow));
}

Cell Database::make_cell(std::string_view key, const std::string& bytes) {
  Cell c;
  c.key = std::string(key);
  c.doc_len = static_cast<std::uint32_t>(bytes.size());
  std::size_t inline_len = std::min(bytes.size(), kMaxInline);
  c.inline_data = bytes.substr(0, inline_len);
  if (bytes.size() > kMaxInline)
    c.overflow = write_overflow_chain(pager_, std::string_view(bytes).substr(kMaxInline));
  return c;
}

void Database::check_index_keys(std::string_view key, const Value& doc) const {
  for (const auto& slot : pager_.header().slots) {
    if (!slot.live) continue;
    auto entry = index_entry_key(doc, split_path_text(slot.path), key);
    if (entry && entry->size() > kMaxIndexKey) throw Error(ErrorKind::IndexKeyTooLong);
  }
}

static void check_key(std::string_view key) {
  if (key.empty() || key.size() > kMaxKey) throw Error(ErrorKind::BadKey);
}

void Database::index_insert(std::size_t slot, const std::string& entry) {
  Cell c;
  c.key = entry;
  index_tree(slot).insert(std::move(c));
  ++pager_.header().slots[slot].entries;
}

void Database::index_erase(std::size_t slot, const std::string& entry) {
  index_tree(slot).erase(entry);
  --pager_.header().slots[slot].entries;
}

void Database::update_indexes(std::string_view key, const Value* old_doc, const Value* new_doc) {
  for (std::size_t s = 0; s < kMaxIndexes; ++s) {
    const IndexSlot& slot = pager_.header().slots[s];
    if (!slot.live) continue;
    Path path = split_path_text(slot.path);
    std::optional<std::string> o, w;
    if (old_doc) o = index_entry_key(*old_doc, path, key);
    if (new_doc) w = index_entry_key(*new_doc, path, key);
    if (!o && !w) continue;
    if (!o) {
      index_insert(s, *w);
    } else if (!w) {
      index_erase(s, *o);
    } else if (*o != *w) {
      index_erase(s, *o);
      index_insert(s, *w);
    }
  }
}

// Spec 14.3: primary tree first (old chain freed, new chain allocated, cell
// replaced or inserted), then every live index in slot order.
bool Database::store_document(std::string_view key, const Value& doc, const std::string& bytes) {
  BTree tree = primary();
  std::optional<Cell> existing = tree.find(key);
  std::optional<Value> old_doc;
  if (existing) {
    if (pager_.header().index_count() > 0) old_doc = read_document(*existing);
    free_overflow_chain(pager_, existing->overflow);
  }
  tree.insert(make_cell(key, bytes));
  if (!existing) ++pager_.header().primary_count;
  update_indexes(key, old_doc ? &*old_doc : nullptr, &doc);
  return !existing;
}

// ---- documents -----------------------------------------------------------

bool Database::put(std::string_view key, const Value& doc) {
  check_key(key);
  std::string bytes = serialize(doc);
  if (bytes.size() > kMaxDoc) throw Error(ErrorKind::DocTooLarge);
  check_index_keys(key, doc);
  return write_txn([&] { return store_document(key, doc, bytes); });
}

std::optional<Value> Database::get(std::string_view key) const {
  std::optional<Cell> cell = primary().find(key);
  if (!cell) return std::nullopt;
  return read_document(*cell);
}

void Database::erase(std::string_view key) {
  std::optional<Cell> cell = primary().find(key);
  if (!cell) throw Error(ErrorKind::NotFound);
  write_txn([&] {
    std::optional<Value> old_doc;
    if (pager_.header().index_count() > 0) old_doc = read_document(*cell);
    free_overflow_chain(pager_, cell->overflow);
    primary().erase(key);
    --pager_.header().primary_count;
    update_indexes(key, old_doc ? &*old_doc : nullptr, nullptr);
  });
}

void Database::update(std::string_view key, const Path& path, Value value) {
  std::optional<Cell> cell = primary().find(key);
  if (!cell) throw Error(ErrorKind::NotFound);
  Value doc = read_document(*cell);
  set_path(doc, path, std::move(value));
  if (depth(doc) > kMaxDepth) throw Error(ErrorKind::Depth);
  std::string bytes = serialize(doc);
  if (bytes.size() > kMaxDoc) throw Error(ErrorKind::DocTooLarge);
  check_index_keys(key, doc);
  write_txn([&] { store_document(key, doc, bytes); });
}

void Database::unset(std::string_view key, const Path& path) {
  std::optional<Cell> cell = primary().find(key);
  if (!cell) throw Error(ErrorKind::NotFound);
  Value doc = read_document(*cell);
  unset_path(doc, path);
  std::string bytes = serialize(doc);
  write_txn([&] { store_document(key, doc, bytes); });
}

// ---- queries -------------------------------------------------------------

std::vector<Entry> Database::scan(const ScanOptions& opt) const {
  std::vector<Entry> out;
  std::int64_t limit = opt.limit.value_or(std::numeric_limits<std::int64_t>::max());
  if (limit == 0) return out;
  std::string from = opt.from.value_or(std::string());
  if (opt.to && from >= *opt.to) return out;

  auto emit = [&](const Cell& cell) {
    Entry e;
    e.key = cell.key;
    if (!opt.keys_only) e.doc = read_document(cell);
    out.push_back(std::move(e));
    return static_cast<std::int64_t>(out.size()) < limit;
  };
  BTree tree = primary();
  if (!opt.reverse) {
    tree.scan_from(from, [&](const Cell& c) {
      if (opt.to && !(c.key < *opt.to)) return false;
      return emit(c);
    });
  } else {
    tree.scan_reverse(opt.to, [&](const Cell& c) {
      if (c.key < from) return false;
      return emit(c);
    });
  }
  return out;
}

FindResult Database::find(const Predicate& pred, std::optional<std::int64_t> limit_opt) const {
  const Header& h = pager_.header();
  std::vector<std::string> live;
  for (const auto& s : h.slots)
    if (s.live) live.push_back(s.path);

  FindResult result;
  result.plan = choose_plan(pred, live);
  std::int64_t limit = limit_opt.value_or(std::numeric_limits<std::int64_t>::max());
  if (limit == 0) return result;

  BTree tree = primary();
  auto consider = [&](const std::string& key, const Value& doc) {
    if (!evaluate(pred, doc)) return true;
    result.entries.push_back(Entry{key, doc});
    return static_cast<std::int64_t>(result.entries.size()) < limit;
  };

  if (!result.plan.use_index) {
    tree.scan_from("", [&](const Cell& c) { return consider(c.key, read_document(c)); });
    return result;
  }

  // Index plan: collect candidate primary keys, then fetch in key order.
  std::size_t slot = 0;
  for (; slot < kMaxIndexes; ++slot)
    if (h.slots[slot].live && h.slots[slot].path == result.plan.path) break;
  const std::string V = *value_key(result.plan.value);
  const CmpOp op = result.plan.op;
  auto has_prefix = [&](const std::string& k) { return k.compare(0, V.size(), V) == 0; };

  std::vector<std::string> keys;
  auto collect = [&](const Cell& c) {
    const std::string& k = c.key;
    switch (op) {
      case CmpOp::Eq:
        if (!has_prefix(k)) return false;
        break;
      case CmpOp::Lt:
        if (!(k < V)) return false;
        break;
      case CmpOp::Le:
        if (!(k < V) && !has_prefix(k)) return false;
        break;
      case CmpOp::Gt:
        if (has_prefix(k)) return true;  // equal values are skipped
        break;
      default: break;  // Ge: everything from V on
    }
    keys.push_back(k.substr(value_key_length(k)));
    return true;
  };
  bool from_start = op == CmpOp::Lt || op == CmpOp::Le;
  index_tree(slot).scan_from(from_start ? std::string_view() : std::string_view(V), collect);
  std::sort(keys.begin(), keys.end());
  for (const std::string& key : keys) {
    std::optional<Cell> cell = tree.find(key);
    if (!cell) continue;
    if (!consider(key, read_document(*cell))) break;
  }
  return result;
}

// ---- indexes -------------------------------------------------------------

std::uint32_t Database::create_index(const Path& path) {
  const std::string text = path_text(path);
  const Header& h = pager_.header();
  for (const auto& s : h.slots)
    if (s.live && s.path == text) throw Error(ErrorKind::IndexExists);
  if (h.index_count() >= kMaxIndexes) throw Error(ErrorKind::IndexLimit);

  // One walk of the primary tree, in key order; nothing is modified yet.
  std::vector<std::string> entries;
  primary().scan_from("", [&](const Cell& c) {
    auto entry = index_entry_key(read_document(c), path, c.key);
    if (entry) {
      if (entry->size() > kMaxIndexKey) throw Error(ErrorKind::IndexKeyTooLong);
      entries.push_back(std::move(*entry));
    }
    return true;
  });

  return write_txn([&] {
    Header& hdr = pager_.header();
    std::size_t slot = 0;
    while (hdr.slots[slot].live) ++slot;
    hdr.slots[slot] = IndexSlot{true, text, 0, 0};
    for (const auto& e : entries) index_insert(slot, e);
    return hdr.slots[slot].entries;
  });
}

std::size_t Database::drop_index(const Path& path) {
  const std::string text = path_text(path);
  std::size_t slot = kMaxIndexes;
  for (std::size_t s = 0; s < kMaxIndexes; ++s)
    if (pager_.header().slots[s].live && pager_.header().slots[s].path == text) slot = s;
  if (slot == kMaxIndexes) throw Error(ErrorKind::IndexMissing);
  return write_txn([&] {
    std::size_t freed = index_tree(slot).free_all();
    pager_.header().slots[slot] = IndexSlot{};
    return freed;
  });
}

std::vector<IndexInfo> Database::indexes() const {
  std::vector<IndexInfo> out;
  const Header& h = pager_.header();
  for (std::size_t s = 0; s < kMaxIndexes; ++s)
    if (h.slots[s].live)
      out.push_back(IndexInfo{static_cast<std::uint32_t>(s), h.slots[s].path, h.slots[s].root,
                              h.slots[s].entries});
  return out;
}

Stats Database::stats() const {
  const Header& h = pager_.header();
  Stats s;
  s.pages = h.page_count;
  s.free_pages = h.freelist_count;
  s.free_head = h.freelist_head;
  s.docs = h.primary_count;
  s.root = h.primary_root;
  s.height = primary().height();
  s.commits = h.commit_counter;
  s.indexes = h.index_count();
  s.wal_size = wal_.size();
  return s;
}

}  // namespace tessera
