#include "jsonschema/json.hpp"

#include <algorithm>
#include <functional>
#include <numeric>

#include "jsonschema/utf8.hpp"

namespace jsonschema {

// ---------------------------------------------------------------- Value

Value Value::boolean(bool b) {
  Value v;
  v.type_ = Type::Bool;
  v.bool_ = b;
  return v;
}

Value Value::number(Decimal d) {
  Value v;
  v.type_ = Type::Number;
  v.number_ = std::move(d);
  return v;
}

Value Value::string(std::string s) {
  Value v;
  v.type_ = Type::String;
  v.string_ = std::move(s);
  return v;
}

Value Value::array(std::vector<Value> items) {
  Value v;
  v.type_ = Type::Array;
  v.items_ = std::move(items);
  return v;
}

Value Value::object() {
  Value v;
  v.type_ = Type::Object;
  return v;
}

const Value* Value::find(std::string_view key) const {
  if (type_ != Type::Object) return nullptr;
  if (index_) {
    auto it = index_->find(std::string(key));
    return it == index_->end() ? nullptr : &items_[it->second];
  }
  for (std::size_t i = 0; i < keys_.size(); ++i) {
    if (keys_[i] == key) return &items_[i];
  }
  return nullptr;
}

void Value::push_back(Value v) { items_.push_back(std::move(v)); }

void Value::add_member(std::string key, Value v) {
  keys_.push_back(std::move(key));
  items_.push_back(std::move(v));
  if (keys_.size() <= kIndexThreshold) return;
  if (!index_) {
    index_ = std::make_shared<Index>();
    for (std::size_t i = 0; i < keys_.size(); ++i) index_->emplace(keys_[i], static_cast<std::uint32_t>(i));
  } else {
    if (index_.use_count() > 1) index_ = std::make_shared<Index>(*index_);
    index_->emplace(keys_.back(), static_cast<std::uint32_t>(keys_.size() - 1));
  }
}

namespace {

void dump_string(const std::string& s, std::string& out) {
  out += '"';
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      default:
        if (c < 0x20) {
          static const char* hex = "0123456789abcdef";
          out += "\\u00";
          out += hex[c >> 4];
          out += hex[c & 15];
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  out += '"';
}

void dump_value(const Value& v, std::string& out) {
  switch (v.type()) {
    case Value::Type::Null: out += "null"; break;
    case Value::Type::Bool: out += v.as_bool() ? "true" : "false"; break;
    case Value::Type::Number: out += v.as_number().to_string(); break;
    case Value::Type::String: dump_string(v.as_string(), out); break;
    case Value::Type::Array: {
      out += '[';
      for (std::size_t i = 0; i < v.size(); ++i) {
        if (i) out += ',';
        dump_value(v.items()[i], out);
      }
      out += ']';
      break;
    }
    case Value::Type::Object: {
      out += '{';
      for (std::size_t i = 0; i < v.size(); ++i) {
        if (i) out += ',';
        dump_string(v.keys()[i], out);
        out += ':';
        dump_value(v.items()[i], out);
      }
      out += '}';
      break;
    }
  }
}

}  // namespace

std::string Value::dump() const {
  std::string out;
  dump_value(*this, out);
  return out;
}

// ---------------------------------------------------------------- equality & hashing

bool json_equal(const Value& a, const Value& b) {
  if (a.type() != b.type()) return false;
  switch (a.type()) {
    case Value::Type::Null: return true;
    case Value::Type::Bool: return a.as_bool() == b.as_bool();
    case Value::Type::Number: return a.as_number() == b.as_number();
    case Value::Type::String: return a.as_string() == b.as_string();
    case Value::Type::Array:
      if (a.size() != b.size()) return false;
      for (std::size_t i = 0; i < a.size(); ++i) {
        if (!json_equal(a.items()[i], b.items()[i])) return false;
      }
      return true;
    case Value::Type::Object:
      if (a.size() != b.size()) return false;
      for (std::size_t i = 0; i < a.size(); ++i) {
        const Value* other = b.find(a.keys()[i]);
        if (!other || !json_equal(a.items()[i], *other)) return false;
      }
      return true;
  }
  return false;
}

std::size_t json_hash(const Value& v) {
  auto mix = [](std::size_t h, std::size_t x) { return h ^ (x + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2)); };
  switch (v.type()) {
    case Value::Type::Null: return 0x1234;
    case Value::Type::Bool: return v.as_bool() ? 0x2345 : 0x3456;
    case Value::Type::Number: return mix(0x4567, v.as_number().hash());
    case Value::Type::String: return mix(0x5678, std::hash<std::string>{}(v.as_string()));
    case Value::Type::Array: {
      std::size_t h = 0x6789;
      for (const Value& e : v.items()) h = mix(h, json_hash(e));
      return h;
    }
    case Value::Type::Object: {
      // Order-insensitive: combine member hashes with addition.
      std::size_t sum = 0;
      for (std::size_t i = 0; i < v.size(); ++i) {
        sum += mix(std::hash<std::string>{}(v.keys()[i]), json_hash(v.items()[i]));
      }
      return mix(0x789a, sum);
    }
  }
  return 0;
}

// ---------------------------------------------------------------- parser

namespace {

class Parser {
 public:
  explicit Parser(std::string_view text) : s_(text) {}

  Value parse_document() {
    if (s_.size() >= 3 && s_.substr(0, 3) == "\xEF\xBB\xBF") i_ = 3;
    skip_ws();
    Value v = parse_value();
    skip_ws();
    if (i_ != s_.size()) fail("trailing characters");
    return v;
  }

 private:
  [[noreturn]] void fail(const char* msg) const { throw JsonParseError(msg, i_); }

  void skip_ws() {
    while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) ++i_;
  }

  bool consume(std::string_view lit) {
    if (s_.substr(i_, lit.size()) == lit) {
      i_ += lit.size();
      return true;
    }
    return false;
  }

  Value parse_value() {
    if (i_ >= s_.size()) fail("unexpected end of input");
    char c = s_[i_];
    switch (c) {
      case '{': return parse_object();
      case '[': return parse_array();
      case '"': return Value::string(parse_string());
      case 't':
        if (consume("true")) return Value::boolean(true);
        fail("invalid literal");
      case 'f':
        if (consume("false")) return Value::boolean(false);
        fail("invalid literal");
      case 'n':
        if (consume("null")) return Value();
        fail("invalid literal");
      default:
        if (c == '-' || (c >= '0' && c <= '9')) return parse_number();
        fail("unexpected character");
    }
  }

  Value parse_number() {
    std::size_t start = i_;
    if (s_[i_] == '-') ++i_;
    auto digits = [&] {
      std::size_t b = i_;
      while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') ++i_;
      return i_ - b;
    };
    if (i_ < s_.size() && s_[i_] == '0') {
      ++i_;
    } else if (digits() == 0) {
      fail("invalid number");
    }
    if (i_ < s_.size() && s_[i_] == '.') {
      ++i_;
      if (digits() == 0) fail("invalid number");
    }
    if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
      ++i_;
      if (i_ < s_.size() && (s_[i_] == '+' || s_[i_] == '-')) ++i_;
      if (digits() == 0) fail("invalid number");
    }
    auto d = Decimal::parse(s_.substr(start, i_ - start));
    if (!d) fail("invalid number");
    return Value::number(std::move(*d));
  }

  unsigned parse_hex4() {
    if (i_ + 4 > s_.size()) fail("bad \\u escape");
    unsigned v = 0;
    for (int k = 0; k < 4; ++k) {
      char c = s_[i_++];
      v <<= 4;
      if (c >= '0' && c <= '9') v |= c - '0';
      else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
      else fail("bad \\u escape");
    }
    return v;
  }

  std::string parse_string() {
    ++i_;  // opening quote
    std::string out;
    while (true) {
      if (i_ >= s_.size()) fail("unterminated string");
      unsigned char c = static_cast<unsigned char>(s_[i_]);
      if (c == '"') {
        ++i_;
        return out;
      }
      if (c < 0x20) fail("control character in string");
      if (c != '\\') {
        out.push_back(static_cast<char>(c));
        ++i_;
        continue;
      }
      ++i_;
      if (i_ >= s_.size()) fail("unterminated string");
      char e = s_[i_++];
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
          char32_t cp = parse_hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF && s_.substr(i_, 2) == "\\u") {
            std::size_t save = i_;
            i_ += 2;
            char32_t lo = parse_hex4();
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else {
              i_ = save;
            }
          }
          utf8::append(out, cp);
          break;
        }
        default: fail("invalid escape");
      }
    }
  }

  Value parse_array() {
    ++i_;
    Value arr = Value::array();
    skip_ws();
    if (i_ < s_.size() && s_[i_] == ']') {
      ++i_;
      return arr;
    }
    while (true) {
      skip_ws();
      arr.push_back(parse_value());
      skip_ws();
      if (i_ >= s_.size()) fail("unterminated array");
      if (s_[i_] == ',') {
        ++i_;
      } else if (s_[i_] == ']') {
        ++i_;
        return arr;
      } else {
        fail("expected ',' or ']'");
      }
    }
  }

  Value parse_object() {
    ++i_;
    Value obj = Value::object();
    skip_ws();
    if (i_ < s_.size() && s_[i_] == '}') {
      ++i_;
      return obj;
    }
    while (true) {
      skip_ws();
      if (i_ >= s_.size() || s_[i_] != '"') fail("expected member name");
      std::string key = parse_string();
      skip_ws();
      if (i_ >= s_.size() || s_[i_] != ':') fail("expected ':'");
      ++i_;
      skip_ws();
      obj.add_member(std::move(key), parse_value());
      skip_ws();
      if (i_ >= s_.size()) fail("unterminated object");
      if (s_[i_] == ',') {
        ++i_;
      } else if (s_[i_] == '}') {
        ++i_;
        return obj;
      } else {
        fail("expected ',' or '}'");
      }
    }
  }

  std::string_view s_;
  std::size_t i_ = 0;
};

}  // namespace

Value parse_json(std::string_view text) { return Parser(text).parse_document(); }

}  // namespace jsonschema
