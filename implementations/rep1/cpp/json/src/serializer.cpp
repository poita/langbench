#include "jsoncanon/serializer.hpp"

#include <algorithm>
#include <cstddef>
#include <vector>

#include "jsoncanon/utf8.hpp"

namespace jsoncanon {

void write_string(std::string_view s, std::string& out) {
  static constexpr char kHex[] = "0123456789abcdef";
  out.push_back('"');
  std::size_t run = 0;  // start of the pending unescaped run
  for (std::size_t i = 0; i < s.size(); ++i) {
    const auto c = static_cast<unsigned char>(s[i]);
    if (c >= 0x20 && c != '"' && c != '\\') continue;
    out.append(s.data() + run, i - run);
    run = i + 1;
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        out += "\\u00";
        out.push_back(kHex[c >> 4]);
        out.push_back(kHex[c & 0xF]);
    }
  }
  out.append(s.data() + run, s.size() - run);
  out.push_back('"');
}

namespace {

void write_value(const Value& v, std::string& out);

void write_object(const Value::Object& members, std::string& out) {
  // Stable sort of member indices by key, so that of each run of equal keys
  // the last (in input order) comes last; only that one is written.
  std::vector<const Member*> order;
  order.reserve(members.size());
  for (const Member& m : members) order.push_back(&m);
  std::stable_sort(order.begin(), order.end(), [](const Member* a, const Member* b) {
    return utf8::compare_utf16(a->key, b->key) < 0;
  });
  out.push_back('{');
  bool first = true;
  for (std::size_t i = 0; i < order.size(); ++i) {
    if (i + 1 < order.size() && order[i]->key == order[i + 1]->key) continue;
    if (!first) out.push_back(',');
    first = false;
    write_string(order[i]->key, out);
    out.push_back(':');
    write_value(order[i]->value, out);
  }
  out.push_back('}');
}

void write_value(const Value& v, std::string& out) {
  switch (v.type()) {
    case Type::Null: out += "null"; break;
    case Type::Bool: out += v.as_bool() ? "true" : "false"; break;
    case Type::Number: out += v.as_number_text(); break;
    case Type::String: write_string(v.as_string(), out); break;
    case Type::Array: {
      out.push_back('[');
      bool first = true;
      for (const Value& e : v.as_array()) {
        if (!first) out.push_back(',');
        first = false;
        write_value(e, out);
      }
      out.push_back(']');
      break;
    }
    case Type::Object: write_object(v.as_object(), out); break;
  }
}

}  // namespace

void serialize(const Value& value, std::string& out) { write_value(value, out); }

std::string serialize(const Value& value) {
  std::string out;
  serialize(value, out);
  return out;
}

}  // namespace jsoncanon
