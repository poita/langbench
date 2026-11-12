#include "bigint/query.hpp"

#include <istream>
#include <ostream>
#include <stdexcept>

#include "bigint/bigint.hpp"

namespace bigint {

std::string evaluate_query(std::string_view line) {
  auto first = line.find(' ');
  auto second = first == std::string_view::npos ? first : line.find(' ', first + 1);
  if (second == std::string_view::npos) throw std::invalid_argument("query: expected '<a> <op> <b>'");
  std::string_view op = line.substr(first + 1, second - first - 1);
  BigInt a(line.substr(0, first));
  BigInt b(line.substr(second + 1));

  try {
    if (op == "+") return (a + b).to_string();
    if (op == "-") return (a - b).to_string();
    if (op == "*") return (a * b).to_string();
    if (op == "/") return (a / b).to_string();
    if (op == "%") return (a % b).to_string();
    if (op == "^") return BigInt::pow(a, b).to_string();
    if (op == "cmp") {
      auto c = a <=> b;
      return c < 0 ? "-1" : c > 0 ? "1" : "0";
    }
  } catch (const ArithmeticError&) {
    return "error";
  }
  throw std::invalid_argument("query: unknown operator");
}

void run_queries(std::istream& in, std::ostream& out) {
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    out << evaluate_query(line) << '\n';
  }
}

}  // namespace bigint
