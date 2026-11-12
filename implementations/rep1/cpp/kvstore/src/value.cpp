#include "tessera/value.hpp"

#include <algorithm>
#include <cstdio>

#include "tessera/error.hpp"

namespace tessera {

std::string path_text(const Path& path) {
  std::string out;
  for (std::size_t i = 0; i < path.size(); ++i) {
    if (i) out += '.';
    out += path[i];
  }
  return out;
}

Path split_path_text(std::string_view text) {
  Path out;
  std::size_t start = 0;
  while (true) {
    std::size_t dot = text.find('.', start);
    if (dot == std::string_view::npos) {
      out.emplace_back(text.substr(start));
      break;
    }
    out.emplace_back(text.substr(start, dot - start));
    start = dot + 1;
  }
  return out;
}

Value Value::boolean(bool b) {
  Value v;
  v.kind_ = Kind::Bool;
  v.bool_ = b;
  return v;
}

Value Value::integer(std::int64_t i) {
  Value v;
  v.kind_ = Kind::Int;
  v.int_ = i;
  return v;
}

Value Value::string(std::string s) {
  Value v;
  v.kind_ = Kind::String;
  v.str_ = std::move(s);
  return v;
}

Value Value::list(std::vector<Value> items) {
  Value v;
  v.kind_ = Kind::List;
  v.items_ = std::move(items);
  return v;
}

Value Value::object(std::vector<Field> fields) {
  std::sort(fields.begin(), fields.end(),
            [](const Field& a, const Field& b) { return a.first < b.first; });
  for (std::size_t i = 1; i < fields.size(); ++i)
    if (fields[i - 1].first == fields[i].first) throw Error(ErrorKind::DupField);
  Value v;
  v.kind_ = Kind::Object;
  v.fields_ = std::move(fields);
  return v;
}

static std::vector<Value::Field>::const_iterator lower(const std::vector<Value::Field>& f,
                                                        std::string_view name) {
  return std::lower_bound(f.begin(), f.end(), name,
                          [](const Value::Field& a, std::string_view n) {
                            return std::string_view(a.first) < n;
                          });
}

const Value* Value::field(std::string_view name) const {
  if (kind_ != Kind::Object) return nullptr;
  auto it = lower(fields_, name);
  return (it != fields_.end() && it->first == name) ? &it->second : nullptr;
}

Value* Value::field(std::string_view name) {
  return const_cast<Value*>(static_cast<const Value*>(this)->field(name));
}

void Value::set_field(std::string_view name, Value v) {
  auto it = lower(fields_, name);
  std::size_t pos = static_cast<std::size_t>(it - fields_.begin());
  if (it != fields_.end() && it->first == name) {
    fields_[pos].second = std::move(v);
  } else {
    fields_.insert(fields_.begin() + static_cast<std::ptrdiff_t>(pos),
                   Field(std::string(name), std::move(v)));
  }
}

bool Value::erase_field(std::string_view name) {
  auto it = lower(fields_, name);
  if (it == fields_.end() || it->first != name) return false;
  fields_.erase(fields_.begin() + (it - fields_.begin()));
  return true;
}

bool operator==(const Value& a, const Value& b) {
  if (a.kind_ != b.kind_) return false;
  switch (a.kind_) {
    case Value::Kind::Null: return true;
    case Value::Kind::Bool: return a.bool_ == b.bool_;
    case Value::Kind::Int: return a.int_ == b.int_;
    case Value::Kind::String: return a.str_ == b.str_;
    case Value::Kind::List: return a.items_ == b.items_;
    case Value::Kind::Object: return a.fields_ == b.fields_;
  }
  return false;
}

int depth(const Value& v) {
  int deepest = 0;
  if (v.kind() == Value::Kind::List) {
    for (const auto& x : v.items()) deepest = std::max(deepest, depth(x));
  } else if (v.kind() == Value::Kind::Object) {
    for (const auto& f : v.fields()) deepest = std::max(deepest, depth(f.second));
  }
  return 1 + deepest;
}

// ---- serialisation -------------------------------------------------------

static void put_be(std::string& out, std::uint64_t v, int bytes) {
  for (int i = bytes - 1; i >= 0; --i) out.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
}

static void ser(const Value& v, std::string& out) {
  switch (v.kind()) {
    case Value::Kind::Null: out.push_back(0); break;
    case Value::Kind::Bool: out.push_back(v.as_bool() ? 2 : 1); break;
    case Value::Kind::Int:
      out.push_back(3);
      put_be(out, static_cast<std::uint64_t>(v.as_int()), 8);
      break;
    case Value::Kind::String:
      out.push_back(4);
      put_be(out, v.as_string().size(), 4);
      out += v.as_string();
      break;
    case Value::Kind::List:
      out.push_back(5);
      put_be(out, v.items().size(), 4);
      for (const auto& x : v.items()) ser(x, out);
      break;
    case Value::Kind::Object:
      out.push_back(6);
      put_be(out, v.fields().size(), 4);
      for (const auto& f : v.fields()) {
        put_be(out, f.first.size(), 4);
        out += f.first;
        ser(f.second, out);
      }
      break;
  }
}

std::string serialize(const Value& v) {
  std::string out;
  ser(v, out);
  return out;
}

namespace {

class Reader {
 public:
  explicit Reader(std::string_view b) : b_(b) {}
  std::uint64_t be(int bytes) {
    std::uint64_t v = 0;
    for (int i = 0; i < bytes; ++i) v = (v << 8) | static_cast<std::uint8_t>(b_[pos_++]);
    return v;
  }
  std::string take(std::size_t n) {
    std::string s(b_.substr(pos_, n));
    pos_ += n;
    return s;
  }
  std::uint8_t byte() { return static_cast<std::uint8_t>(b_[pos_++]); }

 private:
  std::string_view b_;
  std::size_t pos_ = 0;
};

Value de(Reader& r) {
  switch (r.byte()) {
    case 0: return Value::null();
    case 1: return Value::boolean(false);
    case 2: return Value::boolean(true);
    case 3: return Value::integer(static_cast<std::int64_t>(r.be(8)));
    case 4: {
      std::size_t n = static_cast<std::size_t>(r.be(4));
      return Value::string(r.take(n));
    }
    case 5: {
      std::size_t n = static_cast<std::size_t>(r.be(4));
      std::vector<Value> items;
      items.reserve(n);
      for (std::size_t i = 0; i < n; ++i) items.push_back(de(r));
      return Value::list(std::move(items));
    }
    default: {
      std::size_t n = static_cast<std::size_t>(r.be(4));
      std::vector<Value::Field> fields;
      fields.reserve(n);
      for (std::size_t i = 0; i < n; ++i) {
        std::size_t len = static_cast<std::size_t>(r.be(4));
        std::string name = r.take(len);
        fields.emplace_back(std::move(name), de(r));
      }
      return Value::object(std::move(fields));
    }
  }
}

}  // namespace

Value deserialize(std::string_view bytes) {
  Reader r(bytes);
  return de(r);
}

// ---- rendering -----------------------------------------------------------

std::string render_string(std::string_view s) {
  std::string out = "\"";
  for (unsigned char c : s) {
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
          char buf[8];
          std::snprintf(buf, sizeof buf, "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
    }
  }
  out += '"';
  return out;
}

static void rend(const Value& v, std::string& out) {
  switch (v.kind()) {
    case Value::Kind::Null: out += "null"; break;
    case Value::Kind::Bool: out += v.as_bool() ? "true" : "false"; break;
    case Value::Kind::Int: out += std::to_string(v.as_int()); break;
    case Value::Kind::String: out += render_string(v.as_string()); break;
    case Value::Kind::List: {
      out += '[';
      bool first = true;
      for (const auto& x : v.items()) {
        if (!first) out += ',';
        first = false;
        rend(x, out);
      }
      out += ']';
      break;
    }
    case Value::Kind::Object: {
      out += '{';
      bool first = true;
      for (const auto& f : v.fields()) {
        if (!first) out += ',';
        first = false;
        out += render_string(f.first);
        out += ':';
        rend(f.second, out);
      }
      out += '}';
      break;
    }
  }
}

std::string render(const Value& v) {
  std::string out;
  rend(v, out);
  return out;
}

int compare_scalars(const Value& a, const Value& b) {
  switch (a.kind()) {
    case Value::Kind::Bool: return int(a.as_bool()) - int(b.as_bool());
    case Value::Kind::Int: return a.as_int() < b.as_int() ? -1 : (a.as_int() > b.as_int() ? 1 : 0);
    case Value::Kind::String: {
      int c = a.as_string().compare(b.as_string());
      return c < 0 ? -1 : (c > 0 ? 1 : 0);
    }
    default: return 0;
  }
}

// ---- paths ---------------------------------------------------------------

const Value* resolve_path(const Value& doc, const Path& path) {
  const Value* cur = &doc;
  for (const auto& seg : path) {
    cur = cur->field(seg);
    if (!cur) return nullptr;
  }
  return cur;
}

void set_path(Value& doc, const Path& path, Value v) {
  Value* cur = &doc;
  for (std::size_t i = 0; i < path.size(); ++i) {
    if (cur->kind() != Value::Kind::Object) throw Error(ErrorKind::NotObject);
    if (i + 1 == path.size()) {
      cur->set_field(path[i], std::move(v));
      return;
    }
    Value* next = cur->field(path[i]);
    if (!next) {
      cur->set_field(path[i], Value::object({}));
      next = cur->field(path[i]);
    }
    cur = next;
  }
}

void unset_path(Value& doc, const Path& path) {
  Value* cur = &doc;
  for (std::size_t i = 0; i < path.size(); ++i) {
    if (cur->kind() != Value::Kind::Object) throw Error(ErrorKind::NotObject);
    Value* next = cur->field(path[i]);
    if (!next) throw Error(ErrorKind::NoField);
    if (i + 1 == path.size()) {
      cur->erase_field(path[i]);
      return;
    }
    cur = next;
  }
}

}  // namespace tessera
