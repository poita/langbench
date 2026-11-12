#include "toml/tagged_json.hpp"

#include <cstdio>

#include "toml/utf8.hpp"

namespace toml {

namespace {

void write_json_string(std::string& out, std::string_view s) {
  out.push_back('"');
  for (char ch : s) {
    unsigned char c = static_cast<unsigned char>(ch);
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          static const char hex[] = "0123456789abcdef";
          out += "\\u00";
          out.push_back(hex[c >> 4]);
          out.push_back(hex[c & 15]);
        } else {
          out.push_back(ch);
        }
    }
  }
  out.push_back('"');
}

void write_node(std::string& out, const Value& v) {
  switch (v.kind()) {
    case Value::Kind::Scalar:
      out += "{\"type\":";
      write_json_string(out, type_name(v.type()));
      out += ",\"value\":";
      write_json_string(out, v.text());
      out.push_back('}');
      break;
    case Value::Kind::Array: {
      out.push_back('[');
      bool first = true;
      for (const Value& e : v.items()) {
        if (!first) out.push_back(',');
        first = false;
        write_node(out, e);
      }
      out.push_back(']');
      break;
    }
    case Value::Kind::Table: {
      out.push_back('{');
      bool first = true;
      for (const auto& [k, e] : v.members()) {  // std::map: sorted by code point
        if (!first) out.push_back(',');
        first = false;
        write_json_string(out, k);
        out.push_back(':');
        write_node(out, e);
      }
      out.push_back('}');
      break;
    }
  }
}

// ---- reader ----------------------------------------------------------------

// Minimal JSON DOM: only objects, arrays and strings occur in tagged JSON.
struct Json {
  enum class Kind { Object, Array, String } kind = Kind::String;
  std::string str;
  std::vector<Json> items;
  std::vector<std::pair<std::string, Json>> members;
};

constexpr int kMaxJsonDepth = 4000;

class JsonReader {
 public:
  explicit JsonReader(std::string_view s) : s_(s) {}

  Json read_document() {
    Json j = read_value(0);
    skip_ws();
    if (pos_ != s_.size()) fail("trailing characters");
    return j;
  }

 private:
  std::string_view s_;
  std::size_t pos_ = 0;

  [[noreturn]] void fail(const char* msg) const {
    throw JsonError(std::string(msg) + " at offset " + std::to_string(pos_));
  }
  void skip_ws() {
    while (pos_ < s_.size() &&
           (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r'))
      ++pos_;
  }
  void expect(char c) {
    skip_ws();
    if (pos_ >= s_.size() || s_[pos_] != c) fail("unexpected character");
    ++pos_;
  }

  Json read_value(int depth) {
    if (depth > kMaxJsonDepth) fail("nesting too deep");
    skip_ws();
    if (pos_ >= s_.size()) fail("unexpected end of input");
    Json j;
    char c = s_[pos_];
    if (c == '{') {
      ++pos_;
      j.kind = Json::Kind::Object;
      skip_ws();
      if (pos_ < s_.size() && s_[pos_] == '}') {
        ++pos_;
        return j;
      }
      for (;;) {
        skip_ws();
        std::string key = read_string();
        expect(':');
        j.members.emplace_back(std::move(key), read_value(depth + 1));
        skip_ws();
        if (pos_ < s_.size() && s_[pos_] == ',') {
          ++pos_;
        } else {
          expect('}');
          return j;
        }
      }
    }
    if (c == '[') {
      ++pos_;
      j.kind = Json::Kind::Array;
      skip_ws();
      if (pos_ < s_.size() && s_[pos_] == ']') {
        ++pos_;
        return j;
      }
      for (;;) {
        j.items.push_back(read_value(depth + 1));
        skip_ws();
        if (pos_ < s_.size() && s_[pos_] == ',') {
          ++pos_;
        } else {
          expect(']');
          return j;
        }
      }
    }
    if (c == '"') {
      j.kind = Json::Kind::String;
      j.str = read_string();
      return j;
    }
    fail("unexpected token");
  }

  unsigned read_hex4() {
    if (pos_ + 4 > s_.size()) fail("truncated \\u escape");
    unsigned v = 0;
    for (int k = 0; k < 4; ++k) {
      char c = s_[pos_++];
      v <<= 4;
      if (c >= '0' && c <= '9') v |= static_cast<unsigned>(c - '0');
      else if (c >= 'a' && c <= 'f') v |= static_cast<unsigned>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') v |= static_cast<unsigned>(c - 'A' + 10);
      else fail("bad hex digit");
    }
    return v;
  }

  std::string read_string() {
    skip_ws();
    if (pos_ >= s_.size() || s_[pos_] != '"') fail("expected string");
    ++pos_;
    std::string out;
    for (;;) {
      if (pos_ >= s_.size()) fail("unterminated string");
      char c = s_[pos_++];
      if (c == '"') return out;
      if (c != '\\') {
        out.push_back(c);
        continue;
      }
      if (pos_ >= s_.size()) fail("unterminated escape");
      char e = s_[pos_++];
      switch (e) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u': {
          char32_t cp = read_hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF && pos_ + 1 < s_.size() && s_[pos_] == '\\' &&
              s_[pos_ + 1] == 'u') {
            std::size_t save = pos_;
            pos_ += 2;
            unsigned lo = read_hex4();
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else {
              pos_ = save;
            }
          }
          if (cp >= 0xD800 && cp <= 0xDFFF) fail("lone surrogate");
          append_utf8(out, cp);
          break;
        }
        default: fail("bad escape");
      }
    }
  }
};

Value convert(Json&& j) {
  switch (j.kind) {
    case Json::Kind::Array: {
      Value::Array items;
      items.reserve(j.items.size());
      for (Json& e : j.items) items.push_back(convert(std::move(e)));
      return Value::array(std::move(items));
    }
    case Json::Kind::Object: {
      if (j.members.size() == 2) {
        Json* type = nullptr;
        Json* value = nullptr;
        for (auto& [k, v] : j.members) {
          if (k == "type") type = &v;
          else if (k == "value") value = &v;
        }
        Type t;
        if (type && value && type->kind == Json::Kind::String && value->kind == Json::Kind::String &&
            type_from_name(type->str, t))
          return Value::scalar(t, std::move(value->str));
      }
      Value::Table table;
      for (auto& [k, v] : j.members) table.insert_or_assign(std::move(k), convert(std::move(v)));
      return Value::table(std::move(table));
    }
    case Json::Kind::String:
      break;
  }
  throw JsonError("a bare string is not a valid node");
}

}  // namespace

std::string to_tagged_json(const Value& root) {
  std::string out;
  write_node(out, root);
  return out;
}

Value from_tagged_json(std::string_view json) {
  Json doc = JsonReader(json).read_document();
  if (doc.kind != Json::Kind::Object) throw JsonError("root must be an object");
  return convert(std::move(doc));
}

}  // namespace toml
