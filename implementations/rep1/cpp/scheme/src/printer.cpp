#include "scheme/printer.hpp"

#include "scheme/numeric.hpp"

namespace scheme {

namespace {

void print_string_literal(std::string& out, const std::string& s) {
  out.push_back('"');
  for (char c : s) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\n': out += "\\n"; break;
      case '\t': out += "\\t"; break;
      default: out.push_back(c);
    }
  }
  out.push_back('"');
}

}  // namespace

void print_value(std::string& out, const Value& v, bool display) {
  switch (v.tag()) {
    case Value::Tag::Void: out += "#<void>"; return;
    case Value::Tag::Null: out += "()"; return;
    case Value::Tag::True: out += "#t"; return;
    case Value::Tag::False: out += "#f"; return;
    case Value::Tag::Int: out += std::to_string(v.as_fixnum()); return;
    case Value::Tag::Object: break;
  }
  switch (v.object()->kind()) {
    case ObjectKind::BigInt: out += num::to_string(v); return;
    case ObjectKind::String:
      if (display)
        out += v.as<String>()->value;
      else
        print_string_literal(out, v.as<String>()->value);
      return;
    case ObjectKind::Symbol: out += v.as<Symbol>()->name; return;
    case ObjectKind::Closure:
    case ObjectKind::Primitive: out += "#<procedure>"; return;
    case ObjectKind::Frame: out += "#<environment>"; return;
    case ObjectKind::Pair: {
      out.push_back('(');
      const Value* cur = &v;
      bool first = true;
      while (cur->is_pair()) {
        if (!first) out.push_back(' ');
        first = false;
        Pair* p = cur->as<Pair>();
        print_value(out, p->car, display);
        cur = &p->cdr;
      }
      if (!cur->is_null()) {
        out += " . ";
        print_value(out, *cur, display);
      }
      out.push_back(')');
      return;
    }
  }
}

std::string write_string(const Value& v) {
  std::string s;
  print_value(s, v, false);
  return s;
}

std::string display_string(const Value& v) {
  std::string s;
  print_value(s, v, true);
  return s;
}

}  // namespace scheme
