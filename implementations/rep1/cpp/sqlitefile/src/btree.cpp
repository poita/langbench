#include "sqlitefile/btree.hpp"

#include <algorithm>

#include "sqlitefile/error.hpp"

namespace sqlitefile {

namespace {

constexpr int kMaxDepth = 64;

std::uint32_t be32(ByteView d, std::size_t pos) {
  if (pos + 4 > d.size()) throw FormatError("read past end of page");
  return (std::uint32_t{d[pos]} << 24) | (std::uint32_t{d[pos + 1]} << 16) |
         (std::uint32_t{d[pos + 2]} << 8) | d[pos + 3];
}

std::uint32_t be16(ByteView d, std::size_t pos) {
  if (pos + 2 > d.size()) throw FormatError("read past end of page");
  return (std::uint32_t{d[pos]} << 8) | d[pos + 1];
}

enum PageType : std::uint8_t {
  kInteriorIndex = 0x02,
  kInteriorTable = 0x05,
  kLeafIndex = 0x0a,
  kLeafTable = 0x0d,
};

/// A parsed B-tree page header.
struct Page {
  ByteView data;
  std::uint8_t type = 0;
  std::size_t cell_count = 0;
  std::uint32_t right_child = 0;
  std::size_t pointer_array = 0;

  bool interior() const { return type == kInteriorIndex || type == kInteriorTable; }
  bool index() const { return type == kInteriorIndex || type == kLeafIndex; }

  std::size_t cellOffset(std::size_t i) const {
    std::size_t off = be16(data, pointer_array + 2 * i);
    if (off >= data.size()) throw FormatError("cell offset out of page");
    return off;
  }
};

Page loadPage(const Pager& pager, std::uint32_t number) {
  Page p;
  p.data = pager.page(number);
  std::size_t base = number == 1 ? 100 : 0;
  if (base + 8 > p.data.size()) throw FormatError("page too small");
  p.type = p.data[base];
  if (p.type != kInteriorIndex && p.type != kInteriorTable && p.type != kLeafIndex &&
      p.type != kLeafTable)
    throw FormatError("bad B-tree page type");
  p.cell_count = be16(p.data, base + 3);
  std::size_t header = p.interior() ? 12 : 8;
  if (p.interior()) p.right_child = be32(p.data, base + 8);
  p.pointer_array = base + header;
  if (p.pointer_array + 2 * p.cell_count > p.data.size())
    throw FormatError("cell pointer array out of page");
  return p;
}

/// Reads the payload that starts at `pos` in `page`, following overflow pages.
Payload readPayload(const Pager& pager, ByteView page, std::size_t pos, std::int64_t psize,
                    CellKind kind) {
  if (psize < 0) throw FormatError("negative payload size");
  std::uint64_t total = static_cast<std::uint64_t>(psize);
  std::uint64_t file_bytes = static_cast<std::uint64_t>(pager.pageCount()) * pager.pageSize();
  if (total > file_bytes) throw FormatError("payload larger than file");
  std::uint32_t usable = pager.usableSize();
  std::uint32_t local = localPayloadSize(total, usable, kind);
  if (pos + local > page.size()) throw FormatError("payload runs past page");
  if (local == total) return Payload::view(page.subspan(pos, local));

  std::uint32_t next = be32(page, pos + local);
  std::vector<std::uint8_t> buf;
  buf.reserve(static_cast<std::size_t>(total));
  buf.insert(buf.end(), page.begin() + pos, page.begin() + pos + local);
  std::uint64_t remaining = total - local;
  std::uint32_t hops = 0;
  while (remaining > 0) {
    if (next == 0 || ++hops > pager.pageCount()) throw FormatError("bad overflow chain");
    ByteView ov = pager.page(next);
    std::uint32_t after = be32(ov, 0);
    std::uint64_t chunk = std::min<std::uint64_t>(remaining, usable - 4);
    if (4 + chunk > ov.size()) throw FormatError("overflow chunk out of page");
    buf.insert(buf.end(), ov.begin() + 4, ov.begin() + 4 + static_cast<std::size_t>(chunk));
    remaining -= chunk;
    next = after;
  }
  return Payload::owned(std::move(buf));
}

/// A table-leaf cell.
struct TableLeafCell {
  std::int64_t rowid;
  std::size_t payload_pos;
  std::int64_t payload_size;
};

TableLeafCell parseTableLeafCell(const Page& page, std::size_t i) {
  TableLeafCell c{};
  std::size_t pos = page.cellOffset(i);
  pos = readVarint(page.data, pos, c.payload_size);
  pos = readVarint(page.data, pos, c.rowid);
  c.payload_pos = pos;
  return c;
}

/// Interior table cell: child page and key.
void parseTableInteriorCell(const Page& page, std::size_t i, std::uint32_t& child,
                            std::int64_t& key) {
  std::size_t pos = page.cellOffset(i);
  child = be32(page.data, pos);
  readVarint(page.data, pos + 4, key);
}

/// Index cell (leaf or interior).
struct IndexCell {
  std::uint32_t child = 0;  // interior only
  Payload payload;
};

IndexCell parseIndexCell(const Pager& pager, const Page& page, std::size_t i) {
  IndexCell c;
  std::size_t pos = page.cellOffset(i);
  if (page.interior()) {
    c.child = be32(page.data, pos);
    pos += 4;
  }
  std::int64_t psize = 0;
  pos = readVarint(page.data, pos, psize);
  c.payload = readPayload(pager, page.data, pos, psize, CellKind::Index);
  return c;
}

void scanTableNode(const Pager& pager, std::uint32_t pageno, int depth,
                   const BTreeReader::RowCallback& cb, bool& go) {
  if (depth > kMaxDepth) throw FormatError("B-tree too deep (cycle?)");
  Page page = loadPage(pager, pageno);
  if (page.type == kLeafTable) {
    for (std::size_t i = 0; i < page.cell_count && go; ++i) {
      TableLeafCell c = parseTableLeafCell(page, i);
      Payload p = readPayload(pager, page.data, c.payload_pos, c.payload_size,
                              CellKind::TableLeaf);
      if (!cb(c.rowid, p)) go = false;
    }
  } else if (page.type == kInteriorTable) {
    for (std::size_t i = 0; i < page.cell_count && go; ++i) {
      std::uint32_t child;
      std::int64_t key;
      parseTableInteriorCell(page, i, child, key);
      scanTableNode(pager, child, depth + 1, cb, go);
    }
    if (go) scanTableNode(pager, page.right_child, depth + 1, cb, go);
  } else {
    throw FormatError("expected a table B-tree page");
  }
}

std::uint64_t countNode(const Pager& pager, std::uint32_t pageno, int depth) {
  if (depth > kMaxDepth) throw FormatError("B-tree too deep (cycle?)");
  Page page = loadPage(pager, pageno);
  if (page.type == kLeafTable) return page.cell_count;
  if (page.type != kInteriorTable) throw FormatError("expected a table B-tree page");
  std::uint64_t n = 0;
  for (std::size_t i = 0; i < page.cell_count; ++i) {
    std::uint32_t child = be32(page.data, page.cellOffset(i));
    n += countNode(pager, child, depth + 1);
  }
  return n + countNode(pager, page.right_child, depth + 1);
}

int indexKeyCompare(const Payload& payload, const Value& key, bool descending,
                    std::vector<Value>* entry_out) {
  std::vector<Value> entry = decodeRecord(payload.bytes());
  if (entry.empty()) throw FormatError("empty index record");
  int c = compare(entry[0], key);
  if (descending) c = -c;
  if (entry_out) *entry_out = std::move(entry);
  return c;
}

void scanIndexNode(const Pager& pager, std::uint32_t pageno, int depth, const Value& key,
                   bool descending, const BTreeReader::EntryCallback& cb) {
  if (depth > kMaxDepth) throw FormatError("B-tree too deep (cycle?)");
  Page page = loadPage(pager, pageno);
  if (!page.index()) throw FormatError("expected an index B-tree page");

  // Binary search for the first cell whose key is >= the target.
  std::size_t lo = 0, hi = page.cell_count;
  while (lo < hi) {
    std::size_t mid = lo + (hi - lo) / 2;
    IndexCell c = parseIndexCell(pager, page, mid);
    if (indexKeyCompare(c.payload, key, descending, nullptr) < 0)
      lo = mid + 1;
    else
      hi = mid;
  }

  if (!page.interior()) {
    for (std::size_t i = lo; i < page.cell_count; ++i) {
      IndexCell c = parseIndexCell(pager, page, i);
      std::vector<Value> entry;
      if (indexKeyCompare(c.payload, key, descending, &entry) > 0) break;
      cb(entry);
    }
    return;
  }
  for (std::size_t i = lo; i < page.cell_count; ++i) {
    IndexCell c = parseIndexCell(pager, page, i);
    // The left subtree holds entries up to this cell's key, which is >= target.
    scanIndexNode(pager, c.child, depth + 1, key, descending, cb);
    std::vector<Value> entry;
    int cmp = indexKeyCompare(c.payload, key, descending, &entry);
    if (cmp > 0) return;
    cb(entry);
  }
  scanIndexNode(pager, page.right_child, depth + 1, key, descending, cb);
}

}  // namespace

std::uint32_t localPayloadSize(std::uint64_t p, std::uint32_t u, CellKind kind) {
  std::uint64_t m = (static_cast<std::uint64_t>(u - 12) * 32 / 255) - 23;
  std::uint64_t x = kind == CellKind::TableLeaf
                        ? u - 35
                        : (static_cast<std::uint64_t>(u - 12) * 64 / 255) - 23;
  if (p <= x) return static_cast<std::uint32_t>(p);
  std::uint64_t k = m + ((p - m) % (u - 4));
  return static_cast<std::uint32_t>(k <= x ? k : m);
}

Payload Payload::view(ByteView v) {
  Payload p;
  p.view_ = v;
  return p;
}

Payload Payload::owned(std::vector<std::uint8_t> bytes) {
  Payload p;
  p.owned_ = std::move(bytes);
  p.is_owned_ = true;
  return p;
}

void BTreeReader::scanTable(std::uint32_t root, const RowCallback& cb) const {
  bool go = true;
  scanTableNode(pager_, root, 0, cb, go);
}

std::uint64_t BTreeReader::countTableRows(std::uint32_t root) const {
  return countNode(pager_, root, 0);
}

std::optional<Payload> BTreeReader::findTableRow(std::uint32_t root, std::int64_t rowid) const {
  std::uint32_t pageno = root;
  for (int depth = 0; depth <= kMaxDepth; ++depth) {
    Page page = loadPage(pager_, pageno);
    if (page.type == kLeafTable) {
      std::size_t lo = 0, hi = page.cell_count;
      while (lo < hi) {
        std::size_t mid = lo + (hi - lo) / 2;
        TableLeafCell c = parseTableLeafCell(page, mid);
        if (c.rowid < rowid) lo = mid + 1; else hi = mid;
      }
      if (lo == page.cell_count) return std::nullopt;
      TableLeafCell c = parseTableLeafCell(page, lo);
      if (c.rowid != rowid) return std::nullopt;
      return readPayload(pager_, page.data, c.payload_pos, c.payload_size, CellKind::TableLeaf);
    }
    if (page.type != kInteriorTable) throw FormatError("expected a table B-tree page");
    std::size_t lo = 0, hi = page.cell_count;
    while (lo < hi) {
      std::size_t mid = lo + (hi - lo) / 2;
      std::uint32_t child;
      std::int64_t key;
      parseTableInteriorCell(page, mid, child, key);
      if (key < rowid) lo = mid + 1; else hi = mid;
    }
    if (lo == page.cell_count) {
      pageno = page.right_child;
    } else {
      std::int64_t key;
      parseTableInteriorCell(page, lo, pageno, key);
    }
  }
  throw FormatError("B-tree too deep (cycle?)");
}

void BTreeReader::scanIndexEqual(std::uint32_t root, const Value& key, bool descending,
                                 const EntryCallback& cb) const {
  scanIndexNode(pager_, root, 0, key, descending, cb);
}

}  // namespace sqlitefile
