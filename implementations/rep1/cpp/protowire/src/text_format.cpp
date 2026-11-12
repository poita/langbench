#include "protowire/text_format.hpp"

#include <charconv>
#include <cstddef>
#include <cstdint>

#include "protowire/error.hpp"
#include "protowire/hex.hpp"
#include "protowire/scalar.hpp"
#include "protowire/utf8.hpp"

namespace protowire {

// ---------------------------------------------------------------- formatting

namespace {

void formatString(std::string_view s, std::string& out) {
  static constexpr char kHex[] = "0123456789abcdef";
  out += '"';
  for (char ch : s) {
    const auto c = static_cast<unsigned char>(ch);
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20 || c == 0x7f) {
          out += "\\x";
          out += kHex[c >> 4];
          out += kHex[c & 15];
        } else {
          out += ch;
        }
    }
  }
  out += '"';
}

void formatNumber(FieldType t, std::uint64_t x, std::string& out) {
  if (t == FieldType::Bool) {
    out += x ? "true" : "false";
    return;
  }
  char buf[24];
  std::to_chars_result r = isSignedType(t)
      ? std::to_chars(buf, buf + sizeof buf, static_cast<std::int64_t>(x))
      : std::to_chars(buf, buf + sizeof buf, x);
  out.append(buf, r.ptr);
}

void formatElement(const FieldDescriptor& f, const FieldValue& v, std::size_t i, std::string& out) {
  switch (f.type) {
    case FieldType::String: formatString(v.blobs[i], out); break;
    case FieldType::Bytes:
      out += "x\"";
      appendHex(out, {reinterpret_cast<const std::uint8_t*>(v.blobs[i].data()), v.blobs[i].size()});
      out += '"';
      break;
    case FieldType::Message: formatMessage(*v.messages[i], out); break;
    default: formatNumber(f.type, v.numbers[i], out);
  }
}

std::size_t elementCount(const FieldDescriptor& f, const FieldValue& v) {
  if (f.type == FieldType::Message) return v.messages.size();
  if (f.type == FieldType::String || f.type == FieldType::Bytes) return v.blobs.size();
  return v.numbers.size();
}

}  // namespace

void formatMessage(const Message& message, std::string& out) {
  out += '{';
  bool first = true;
  const auto& fields = message.descriptor().fields();
  for (const auto& slot : message.slots()) {
    const FieldDescriptor& f = fields[slot.index];
    if (!hasOutput(f, slot.value)) continue;
    if (!first) out += ", ";
    first = false;
    out += f.name;
    out += ": ";
    if (f.repeated) {
      out += '[';
      const std::size_t n = elementCount(f, slot.value);
      for (std::size_t i = 0; i < n; ++i) {
        if (i) out += ", ";
        formatElement(f, slot.value, i, out);
      }
      out += ']';
    } else {
      formatElement(f, slot.value, 0, out);
    }
  }
  out += '}';
}

std::string formatMessage(const Message& message) {
  std::string out;
  formatMessage(message, out);
  return out;
}

// ------------------------------------------------------------------- parsing

namespace {

[[noreturn]] void fail(const char* what) { throw TextError(what); }

bool isWordChar(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

int hexDigit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

class Parser {
 public:
  explicit Parser(std::string_view text) : s_(text) {}

  Message parseDocument(const MessageDescriptor& desc) {
    Message msg(desc);
    parseMessage(msg, 0);
    skipSpaces();
    if (pos_ != s_.size()) fail("trailing text");
    return msg;
  }

 private:
  void skipSpaces() {
    while (pos_ < s_.size() && s_[pos_] == ' ') ++pos_;
  }
  bool peekIs(char c) const { return pos_ < s_.size() && s_[pos_] == c; }
  void expect(char c) {
    if (!peekIs(c)) fail("unexpected character");
    ++pos_;
  }

  void parseMessage(Message& msg, int depth) {
    if (depth > kMaxNestingDepth) fail("nesting too deep");
    const MessageDescriptor& desc = msg.descriptor();
    skipSpaces();
    expect('{');
    skipSpaces();
    if (peekIs('}')) { ++pos_; return; }
    for (;;) {
      skipSpaces();
      const std::size_t start = pos_;
      while (pos_ < s_.size() && isWordChar(s_[pos_])) ++pos_;
      const FieldDescriptor* f = desc.findByName(s_.substr(start, pos_ - start));
      if (!f) fail("unknown field");
      if (msg.find(f->index)) fail("duplicate field");
      skipSpaces();
      expect(':');
      skipSpaces();
      parseFieldValue(msg, *f, depth);
      skipSpaces();
      if (peekIs(',')) { ++pos_; continue; }
      expect('}');
      return;
    }
  }

  void parseFieldValue(Message& msg, const FieldDescriptor& f, int depth) {
    FieldValue& fv = msg.touch(f.index);
    if (!f.repeated) {
      parseElement(f, fv, depth);
      return;
    }
    expect('[');
    skipSpaces();
    if (peekIs(']')) { ++pos_; return; }
    for (;;) {
      skipSpaces();
      parseElement(f, fv, depth);
      skipSpaces();
      if (peekIs(',')) { ++pos_; continue; }
      expect(']');
      return;
    }
  }

  void parseElement(const FieldDescriptor& f, FieldValue& fv, int depth) {
    switch (f.type) {
      case FieldType::String: fv.blobs.push_back(parseString(true)); break;
      case FieldType::Bytes: fv.blobs.push_back(parseBytes()); break;
      case FieldType::Message: {
        fv.messages.push_back(std::make_unique<Message>(*f.message));
        parseMessage(*fv.messages.back(), depth + 1);
        break;
      }
      case FieldType::Bool: fv.numbers.push_back(parseBool()); break;
      default: fv.numbers.push_back(parseInteger(f.type)); break;
    }
  }

  std::uint64_t parseBool() {
    const std::size_t start = pos_;
    while (pos_ < s_.size() && isWordChar(s_[pos_])) ++pos_;
    const std::string_view tok = s_.substr(start, pos_ - start);
    if (tok == "true") return 1;
    if (tok == "false") return 0;
    fail("expected bool");
  }

  std::uint64_t parseInteger(FieldType t) {
    bool neg = false;
    if (peekIs('-')) { neg = true; ++pos_; }
    const std::size_t start = pos_;
    std::uint64_t mag = 0;
    while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') {
      const std::uint64_t d = static_cast<std::uint64_t>(s_[pos_] - '0');
      if (mag > (UINT64_MAX - d) / 10) fail("integer out of range");
      mag = mag * 10 + d;
      ++pos_;
    }
    const std::size_t digits = pos_ - start;
    if (digits == 0) fail("expected integer");
    if (digits > 1 && s_[start] == '0') fail("leading zero");
    if (neg && mag == 0) fail("negative zero");
    if (pos_ < s_.size() && isWordChar(s_[pos_])) fail("malformed integer");

    const bool is32 = t == FieldType::Int32 || t == FieldType::SInt32 || t == FieldType::SFixed32 ||
                      t == FieldType::UInt32 || t == FieldType::Fixed32;
    if (isSignedType(t)) {
      const std::uint64_t limit = (is32 ? 1ull << 31 : 1ull << 63);
      if (neg ? mag > limit : mag > limit - 1) fail("integer out of range");
      return neg ? 0 - mag : mag;
    }
    if (neg) fail("negative unsigned");
    if (is32 && mag > 0xffffffffull) fail("integer out of range");
    return mag;
  }

  std::string parseString(bool requireUtf8) {
    expect('"');
    std::string out;
    for (;;) {
      if (pos_ >= s_.size()) fail("unterminated string");
      const char c = s_[pos_++];
      if (c == '"') break;
      if (static_cast<unsigned char>(c) < 0x20) fail("control character in string");
      if (c != '\\') { out += c; continue; }
      if (pos_ >= s_.size()) fail("unterminated escape");
      const char e = s_[pos_++];
      switch (e) {
        case '"': out += '"'; break;
        case '\\': out += '\\'; break;
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case 'x': {
          if (pos_ + 2 > s_.size()) fail("bad \\x escape");
          const int hi = hexDigit(s_[pos_]), lo = hexDigit(s_[pos_ + 1]);
          if (hi < 0 || lo < 0) fail("bad \\x escape");
          pos_ += 2;
          out += static_cast<char>(hi << 4 | lo);
          break;
        }
        default: fail("unknown escape");
      }
    }
    if (requireUtf8 && !isValidUtf8(out)) fail("invalid UTF-8");
    return out;
  }

  std::string parseBytes() {
    expect('x');
    expect('"');
    std::string out;
    for (;;) {
      if (pos_ >= s_.size()) fail("unterminated bytes literal");
      const char c = s_[pos_++];
      if (c == '"') break;
      if (pos_ >= s_.size()) fail("unterminated bytes literal");
      const int hi = hexDigit(c), lo = hexDigit(s_[pos_]);
      if (hi < 0 || lo < 0 || (c >= 'A' && c <= 'F') || (s_[pos_] >= 'A' && s_[pos_] <= 'F'))
        fail("bad bytes literal");
      ++pos_;
      out += static_cast<char>(hi << 4 | lo);
    }
    return out;
  }

  std::string_view s_;
  std::size_t pos_ = 0;
};

}  // namespace

Message parseMessage(const MessageDescriptor& descriptor, std::string_view text) {
  return Parser(text).parseDocument(descriptor);
}

}  // namespace protowire
