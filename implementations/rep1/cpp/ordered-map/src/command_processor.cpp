#include "ordered_map/command_processor.hpp"

#include <charconv>
#include <cstdint>

namespace ordered_map {
namespace {

void append_int(std::string& out, std::int64_t v) {
    char buf[24];
    auto r = std::to_chars(buf, buf + sizeof buf, v);
    out.append(buf, r.ptr);
}

void append_key_or(std::string& out, const std::optional<std::int64_t>& k,
                   std::string_view none) {
    if (k) append_int(out, *k);
    else out.append(none);
    out.push_back('\n');
}

template <class T>
bool parse_int(std::string_view s, T& v) {
    if (s.empty()) return false;
    auto r = std::from_chars(s.data(), s.data() + s.size(), v);
    return r.ec == std::errc() && r.ptr == s.data() + s.size();
}

// Splits off the next space-separated token from `rest`.
std::string_view next_token(std::string_view& rest) {
    std::size_t sp = rest.find(' ');
    std::string_view tok = rest.substr(0, sp);
    rest = sp == std::string_view::npos ? std::string_view() : rest.substr(sp + 1);
    return tok;
}

}  // namespace

bool execute_command(OrderedMap& map, std::string_view line, std::string& out) {
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    std::string_view rest = line;
    const std::string_view cmd = next_token(rest);
    std::int64_t a = 0, b = 0;

    if (cmd == "size") {
        append_int(out, static_cast<std::int64_t>(map.size()));
        out.push_back('\n');
    } else if (cmd == "min") {
        append_key_or(out, map.min(), "empty");
    } else if (cmd == "max") {
        append_key_or(out, map.max(), "empty");
    } else if (cmd == "insert") {
        if (!parse_int(next_token(rest), a) || rest.empty()) return false;
        out.append(map.insert(a, rest) ? "ok\n" : "updated\n");
    } else if (cmd == "delete") {
        if (!parse_int(rest, a)) return false;
        out.append(map.erase(a) ? "ok\n" : "missing\n");
    } else if (cmd == "get") {
        if (!parse_int(rest, a)) return false;
        const std::string* v = map.find(a);
        if (v) out.append(*v);
        else out.append("missing");
        out.push_back('\n');
    } else if (cmd == "floor") {
        if (!parse_int(rest, a)) return false;
        append_key_or(out, map.floor(a), "missing");
    } else if (cmd == "ceil") {
        if (!parse_int(rest, a)) return false;
        append_key_or(out, map.ceil(a), "missing");
    } else if (cmd == "succ") {
        if (!parse_int(rest, a)) return false;
        append_key_or(out, map.successor(a), "missing");
    } else if (cmd == "pred") {
        if (!parse_int(rest, a)) return false;
        append_key_or(out, map.predecessor(a), "missing");
    } else if (cmd == "rank") {
        if (!parse_int(rest, a)) return false;
        append_int(out, static_cast<std::int64_t>(map.rank(a)));
        out.push_back('\n');
    } else if (cmd == "select") {
        std::uint64_t k = 0;
        if (!parse_int(rest, k)) return false;
        append_key_or(out, map.select(k), "missing");
    } else if (cmd == "range") {
        if (!parse_int(next_token(rest), a) || !parse_int(rest, b)) return false;
        const std::size_t start = out.size();
        map.for_each_in_range(a, b, [&](std::int64_t k, const std::string&) {
            if (out.size() != start) out.push_back(' ');
            append_int(out, k);
        });
        if (out.size() == start) out.append("empty");
        out.push_back('\n');
    } else {
        return false;
    }
    return true;
}

bool run_script(std::string_view input, std::string& out) {
    auto next_line = [&input]() {
        std::size_t nl = input.find('\n');
        std::string_view line = input.substr(0, nl);
        input = nl == std::string_view::npos ? std::string_view() : input.substr(nl + 1);
        return line;
    };
    if (input.empty()) return true;  // treat missing header as zero commands
    std::string_view header = next_line();
    if (!header.empty() && header.back() == '\r') header.remove_suffix(1);
    std::uint64_t q = 0;
    if (!parse_int(header, q)) return false;

    OrderedMap map;
    for (std::uint64_t i = 0; i < q; ++i) {
        if (input.empty()) return false;  // fewer lines than announced
        if (!execute_command(map, next_line(), out)) return false;
    }
    return true;
}

}  // namespace ordered_map
