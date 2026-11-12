#include "tessera/index_key.hpp"

namespace tessera {

std::optional<std::string> value_key(const Value& v) {
  std::string out;
  switch (v.kind()) {
    case Value::Kind::Null: out.push_back('\x10'); break;
    case Value::Kind::Bool: out.push_back(v.as_bool() ? '\x21' : '\x20'); break;
    case Value::Kind::Int: {
      out.push_back('\x30');
      std::uint64_t u = static_cast<std::uint64_t>(v.as_int()) ^ (std::uint64_t(1) << 63);
      for (int i = 7; i >= 0; --i) out.push_back(static_cast<char>((u >> (8 * i)) & 0xFF));
      break;
    }
    case Value::Kind::String:
      out.push_back('\x40');
      for (char c : v.as_string()) {
        out.push_back(c);
        if (c == '\0') out.push_back('\xFF');
      }
      out.append("\0\0", 2);
      break;
    default: return std::nullopt;
  }
  return out;
}

std::optional<std::string> index_entry_key(const Value& doc, const Path& path,
                                           std::string_view doc_key) {
  const Value* v = resolve_path(doc, path);
  if (!v) return std::nullopt;
  auto k = value_key(*v);
  if (!k) return std::nullopt;
  k->append(doc_key);
  return k;
}

std::size_t value_key_length(std::string_view k) {
  switch (static_cast<unsigned char>(k[0])) {
    case 0x30: return 9;
    case 0x40: {
      std::size_t i = 1;
      while (true) {
        if (k[i] == '\0') {
          if (static_cast<unsigned char>(k[i + 1]) == 0xFF) {
            i += 2;
            continue;
          }
          return i + 2;
        }
        ++i;
      }
    }
    default: return 1;
  }
}

}  // namespace tessera
