#include "datalog/value.h"

#include <algorithm>

namespace datalog {
namespace {

void collect(const Term& t, std::vector<std::string>& out) {
  if (t.is_constant() && !t.constant_value().is_integer())
    out.push_back(t.constant_value().symbol_value());
}

void collect(const Atom& a, std::vector<std::string>& out) {
  for (const Term& t : a.args) collect(t, out);
}

}  // namespace

ValueEncoder ValueEncoder::of(const Program& program) {
  ValueEncoder e;
  for (const Rule& r : program.rules) {
    collect(r.head, e.symbols_);
    for (const Literal& l : r.body) {
      if (l.kind == Literal::Kind::Comparison) {
        collect(l.lhs, e.symbols_);
        collect(l.rhs, e.symbols_);
      } else {
        collect(l.atom, e.symbols_);
      }
    }
  }
  for (const Atom& q : program.queries) collect(q, e.symbols_);
  std::sort(e.symbols_.begin(), e.symbols_.end());
  e.symbols_.erase(std::unique(e.symbols_.begin(), e.symbols_.end()), e.symbols_.end());
  return e;
}

std::optional<Value> ValueEncoder::encode(const Constant& c) const {
  if (c.is_integer()) return c.integer_value();
  auto it = std::lower_bound(symbols_.begin(), symbols_.end(), c.symbol_value());
  if (it == symbols_.end() || *it != c.symbol_value()) return std::nullopt;
  return kSymbolBase + (it - symbols_.begin());
}

Constant ValueEncoder::decode(Value v) const {
  if (v < kSymbolBase) return Constant::integer(v);
  return Constant::symbol(symbols_[static_cast<std::size_t>(v - kSymbolBase)]);
}

std::string ValueEncoder::text(Value v) const {
  if (v < kSymbolBase) return std::to_string(v);
  return symbols_[static_cast<std::size_t>(v - kSymbolBase)];
}

}  // namespace datalog
