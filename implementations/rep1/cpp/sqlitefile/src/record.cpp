#include "sqlitefile/record.hpp"

#include <cstring>

#include "sqlitefile/error.hpp"

namespace sqlitefile {

std::size_t readVarint(ByteView data, std::size_t pos, std::int64_t& out) {
  std::uint64_t v = 0;
  for (int i = 0; i < 8; ++i) {
    if (pos >= data.size()) throw FormatError("truncated varint");
    std::uint8_t b = data[pos++];
    v = (v << 7) | (b & 0x7f);
    if (!(b & 0x80)) {
      out = static_cast<std::int64_t>(v);
      return pos;
    }
  }
  if (pos >= data.size()) throw FormatError("truncated varint");
  v = (v << 8) | data[pos++];
  out = static_cast<std::int64_t>(v);
  return pos;
}

namespace {

std::int64_t readSigned(const std::uint8_t* p, int n) {
  std::uint64_t v = (p[0] & 0x80) ? ~std::uint64_t{0} : 0;
  for (int i = 0; i < n; ++i) v = (v << 8) | p[i];
  return static_cast<std::int64_t>(v);
}

}  // namespace

std::vector<Value> decodeRecord(ByteView rec, std::size_t max_columns) {
  std::int64_t header_size = 0;
  std::size_t pos = readVarint(rec, 0, header_size);
  if (header_size < static_cast<std::int64_t>(pos) ||
      static_cast<std::uint64_t>(header_size) > rec.size())
    throw FormatError("bad record header size");
  ByteView header = rec.first(static_cast<std::size_t>(header_size));
  std::size_t body = header.size();

  std::vector<Value> out;
  while (pos < header.size() && out.size() < max_columns) {
    std::int64_t st = 0;
    pos = readVarint(header, pos, st);
    if (st < 0) throw FormatError("bad serial type");
    std::uint64_t size = 0;
    switch (st) {
      case 0: case 8: case 9: size = 0; break;
      case 1: size = 1; break;
      case 2: size = 2; break;
      case 3: size = 3; break;
      case 4: size = 4; break;
      case 5: size = 6; break;
      case 6: case 7: size = 8; break;
      case 10: case 11: throw FormatError("reserved serial type");
      default: size = static_cast<std::uint64_t>(st - 12 - (st & 1)) / 2; break;
    }
    if (size > rec.size() - body) throw FormatError("record body truncated");
    const std::uint8_t* p = rec.data() + body;
    switch (st) {
      case 0: out.push_back(Value::null()); break;
      case 1: case 2: case 3: case 4: case 5: case 6:
        out.push_back(Value::integer(readSigned(p, static_cast<int>(size))));
        break;
      case 7: {
        std::uint64_t bits = 0;
        for (int i = 0; i < 8; ++i) bits = (bits << 8) | p[i];
        double d;
        std::memcpy(&d, &bits, sizeof d);
        out.push_back(Value::real(d));
        break;
      }
      case 8: out.push_back(Value::integer(0)); break;
      case 9: out.push_back(Value::integer(1)); break;
      default: {
        std::string s(reinterpret_cast<const char*>(p), static_cast<std::size_t>(size));
        out.push_back(st % 2 == 0 ? Value::blob(std::move(s)) : Value::text(std::move(s)));
      }
    }
    body += static_cast<std::size_t>(size);
  }
  return out;
}

}  // namespace sqlitefile
