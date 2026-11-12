#include "toml/writer.hpp"

namespace toml {

namespace {

bool is_bare_key(std::string_view k) {
  if (k.empty()) return false;
  for (char c : k) {
    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '_' || c == '-';
    if (!ok) return false;
  }
  return true;
}

void write_inline(std::string& out, const Value& v) {
  switch (v.kind()) {
    case Value::Kind::Scalar:
      if (v.type() == Type::String)
        out += quote_basic_string(v.text());
      else
        out += v.text();
      break;
    case Value::Kind::Array: {
      out.push_back('[');
      bool first = true;
      for (const Value& e : v.items()) {
        if (!first) out += ", ";
        first = false;
        write_inline(out, e);
      }
      out.push_back(']');
      break;
    }
    case Value::Kind::Table: {
      out.push_back('{');
      bool first = true;
      for (const auto& [k, e] : v.members()) {
        if (!first) out += ", ";
        first = false;
        out += format_key(k);
        out += " = ";
        write_inline(out, e);
      }
      out.push_back('}');
      break;
    }
  }
}

bool is_array_of_tables(const Value& v) {
  if (!v.is_array() || v.items().empty()) return false;
  for (const Value& e : v.items())
    if (!e.is_table()) return false;
  return true;
}

void write_header(std::string& out, const std::string& path, bool array) {
  if (!out.empty()) out.push_back('\n');
  out += array ? "[[" : "[";
  out += path;
  out += array ? "]]\n" : "]\n";
}

void write_table(std::string& out, const Value& table, const std::string& path) {
  for (const auto& [k, v] : table.members()) {
    if (v.is_table() || is_array_of_tables(v)) continue;
    out += format_key(k);
    out += " = ";
    write_inline(out, v);
    out.push_back('\n');
  }
  for (const auto& [k, v] : table.members()) {
    bool sub = v.is_table();
    if (!sub && !is_array_of_tables(v)) continue;
    std::string child = path.empty() ? format_key(k) : path + "." + format_key(k);
    if (sub) {
      write_header(out, child, false);
      write_table(out, v, child);
    } else {
      for (const Value& e : v.items()) {
        write_header(out, child, true);
        write_table(out, e, child);
      }
    }
  }
}

}  // namespace

std::string quote_basic_string(std::string_view s) {
  static const char hex[] = "0123456789abcdef";
  std::string out;
  out.reserve(s.size() + 2);
  out.push_back('"');
  for (char ch : s) {
    unsigned char c = static_cast<unsigned char>(ch);
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\t': out += "\\t"; break;
      case '\n': out += "\\n"; break;
      case '\f': out += "\\f"; break;
      case '\r': out += "\\r"; break;
      default:
        if (c < 0x20 || c == 0x7F) {
          out += "\\u00";
          out.push_back(hex[c >> 4]);
          out.push_back(hex[c & 15]);
        } else {
          out.push_back(ch);
        }
    }
  }
  out.push_back('"');
  return out;
}

std::string format_key(std::string_view key) {
  return is_bare_key(key) ? std::string(key) : quote_basic_string(key);
}

std::string to_toml(const Value& root) {
  std::string out;
  write_table(out, root, "");
  if (out.empty()) out = "\n";
  return out;
}

}  // namespace toml
