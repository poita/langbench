#include "bigint/query.hpp"

#include "bigint/bigint.hpp"

namespace bigint {

namespace {

constexpr const char* kError = "error";

std::string power(const BigInt& a, const BigInt& b) {
    if (b.is_negative()) return kError;
    if (b.is_zero()) return "1";
    if (a.is_zero()) return "0";
    // |a| == 1 needs no work, whatever the exponent.
    if (a.abs() == BigInt(1)) return (a.is_negative() && b.to_uint64() % 2 == 1) ? "-1" : "1";
    return BigInt::pow(a, b.to_uint64()).to_string();
}

}  // namespace

std::string evaluate_query(std::string_view line) {
    const auto first = line.find(' ');
    const auto last = line.rfind(' ');
    if (first == std::string_view::npos || first == last) {
        throw ParseError("query must have the form '<a> <op> <b>'");
    }
    const BigInt a(line.substr(0, first));
    const std::string_view op = line.substr(first + 1, last - first - 1);
    const BigInt b(line.substr(last + 1));

    if (op == "+") return (a + b).to_string();
    if (op == "-") return (a - b).to_string();
    if (op == "*") return (a * b).to_string();
    if (op == "/" || op == "%") {
        if (b.is_zero()) return kError;
        auto qr = BigInt::divmod(a, b);
        return (op == "/" ? qr.first : qr.second).to_string();
    }
    if (op == "^") return power(a, b);
    if (op == "cmp") return std::to_string(BigInt::compare(a, b));
    throw ParseError("unknown operator");
}

std::string evaluate_queries(std::string_view input) {
    std::string out;
    while (!input.empty()) {
        const auto nl = input.find('\n');
        const std::string_view line = input.substr(0, nl);
        input = nl == std::string_view::npos ? std::string_view{} : input.substr(nl + 1);
        out += evaluate_query(line);
        out += '\n';
    }
    return out;
}

}  // namespace bigint
