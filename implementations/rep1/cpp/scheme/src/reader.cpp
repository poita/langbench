#include "scheme/reader.hpp"

#include "scheme/errors.hpp"
#include "scheme/numeric.hpp"

namespace scheme {

bool Reader::is_delimiter(char c) {
  switch (c) {
    case ' ': case '\t': case '\r': case '\n':
    case '(': case ')': case '\'': case '"': case ';':
      return true;
    default:
      return false;
  }
}

void Reader::skip_space() {
  while (pos_ < src_.size()) {
    char c = src_[pos_];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      ++pos_;
    } else if (c == ';') {
      while (pos_ < src_.size() && src_[pos_] != '\n') ++pos_;
    } else {
      break;
    }
  }
}

std::optional<Value> Reader::read() {
  skip_space();
  if (at_end()) return std::nullopt;
  return read_datum();
}

Value Reader::read_datum() {
  skip_space();
  if (at_end()) throw SchemeError(ErrorKind::SyntaxError, "unexpected end of input");
  char c = src_[pos_];
  switch (c) {
    case '(':
      ++pos_;
      return read_list();
    case ')':
      throw SchemeError(ErrorKind::SyntaxError, "unexpected ')'");
    case '\'': {
      ++pos_;
      Value d = read_datum();
      return make_list({make_symbol_value(symbols_.intern("quote")), std::move(d)});
    }
    case '"':
      ++pos_;
      return read_string();
    default:
      return read_atom();
  }
}

Value Reader::read_list() {
  Value head = Value::null();
  Pair* tail = nullptr;
  for (;;) {
    skip_space();
    if (at_end()) throw SchemeError(ErrorKind::SyntaxError, "unterminated list");
    char c = src_[pos_];
    if (c == ')') {
      ++pos_;
      return head;
    }
    if (c == '.' && tail != nullptr && (pos_ + 1 >= src_.size() || is_delimiter(src_[pos_ + 1]))) {
      ++pos_;
      tail->cdr = read_datum();
      skip_space();
      if (at_end() || src_[pos_] != ')') throw SchemeError(ErrorKind::SyntaxError, "bad dotted list");
      ++pos_;
      return head;
    }
    Value cell = make_pair(read_datum(), Value::null());
    Pair* p = cell.as<Pair>();
    if (tail)
      tail->cdr = std::move(cell);
    else
      head = std::move(cell);
    tail = p;
  }
}

Value Reader::read_string() {
  std::string out;
  while (pos_ < src_.size()) {
    char c = src_[pos_++];
    if (c == '"') return make_string(std::move(out));
    if (c == '\\' && pos_ < src_.size()) {
      char e = src_[pos_++];
      switch (e) {
        case 'n': out.push_back('\n'); break;
        case 't': out.push_back('\t'); break;
        default: out.push_back(e); break;  // \" and \\ (and anything else)
      }
    } else {
      out.push_back(c);
    }
  }
  throw SchemeError(ErrorKind::SyntaxError, "unterminated string");
}

Value Reader::read_atom() {
  size_t start = pos_;
  while (pos_ < src_.size() && !is_delimiter(src_[pos_])) ++pos_;
  std::string_view tok = src_.substr(start, pos_ - start);
  if (tok == "#t") return Value::boolean(true);
  if (tok == "#f") return Value::boolean(false);
  size_t i = (tok[0] == '+' || tok[0] == '-') ? 1 : 0;
  if (i < tok.size()) {
    bool digits = true;
    for (size_t k = i; k < tok.size(); ++k) {
      if (tok[k] < '0' || tok[k] > '9') {
        digits = false;
        break;
      }
    }
    if (digits) return num::parse(tok);
  }
  return make_symbol_value(symbols_.intern(tok));
}

}  // namespace scheme
