#include "sqlitefile/pager.hpp"

#include <cstring>
#include <fstream>
#include <iterator>

#include "sqlitefile/error.hpp"

namespace sqlitefile {

namespace {
std::uint32_t be32(const std::uint8_t* p) {
  return (std::uint32_t{p[0]} << 24) | (std::uint32_t{p[1]} << 16) |
         (std::uint32_t{p[2]} << 8) | p[3];
}
}  // namespace

Pager Pager::open(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw Error("cannot open " + path.string());
  in.seekg(0, std::ios::end);
  std::streamoff size = in.tellg();
  in.seekg(0, std::ios::beg);
  if (size < 0) throw Error("cannot read " + path.string());
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
  if (size > 0 && !in.read(reinterpret_cast<char*>(bytes.data()), size))
    throw Error("cannot read " + path.string());
  return fromBytes(std::move(bytes));
}

Pager Pager::fromBytes(std::vector<std::uint8_t> bytes) {
  static const char magic[16] = {'S', 'Q', 'L', 'i', 't', 'e', ' ', 'f',
                                 'o', 'r', 'm', 'a', 't', ' ', '3', 0};
  if (bytes.size() < 100 || std::memcmp(bytes.data(), magic, 16) != 0)
    throw FormatError("not a SQLite 3 database");
  Pager p;
  p.bytes_ = std::move(bytes);
  const std::uint8_t* b = p.bytes_.data();
  DatabaseHeader& h = p.header_;
  std::uint32_t ps = (std::uint32_t{b[16]} << 8) | b[17];
  if (ps == 1) ps = 65536;
  if (ps < 512 || (ps & (ps - 1)) != 0) throw FormatError("bad page size");
  h.page_size = ps;
  h.reserved_bytes = b[20];
  h.declared_page_count = be32(b + 28);
  h.freelist_trunk = be32(b + 32);
  h.freelist_count = be32(b + 36);
  h.largest_root_page = be32(b + 52);
  h.text_encoding = be32(b + 56);
  if (h.reserved_bytes >= ps) throw FormatError("bad reserved size");
  if (h.text_encoding != 1) throw FormatError("only UTF-8 databases are supported");
  p.page_count_ = static_cast<std::uint32_t>(p.bytes_.size() / ps);
  if (p.page_count_ == 0) throw FormatError("file shorter than one page");
  return p;
}

ByteView Pager::page(std::uint32_t number) const {
  if (number == 0 || number > page_count_) throw FormatError("page number out of range");
  std::size_t off = static_cast<std::size_t>(number - 1) * header_.page_size;
  return ByteView(bytes_.data() + off, header_.page_size);
}

}  // namespace sqlitefile
