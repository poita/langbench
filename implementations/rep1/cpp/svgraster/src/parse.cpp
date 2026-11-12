#include "svgraster/parse.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>

namespace svgraster {

namespace {

struct NamedColor {
    const char* name;
    unsigned value;
};

const NamedColor kNamedColors[] = {
#include "color_names.inc"
};

bool is_space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'; }
bool is_digit(char c) { return c >= '0' && c <= '9'; }

int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Round half away from zero.
int round_half_away(double v) { return static_cast<int>(std::floor(v + 0.5)); }

}  // namespace

std::string trim(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && is_space(s[b])) ++b;
    while (e > b && is_space(s[e - 1])) --e;
    return s.substr(b, e - b);
}

std::string to_lower(const std::string& s) {
    std::string r = s;
    for (char& c : r) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return r;
}

void Scanner::skip_space() {
    while (pos_ < s_.size() && is_space(s_[pos_])) ++pos_;
}

void Scanner::skip_space_and_commas() {
    while (pos_ < s_.size() && (is_space(s_[pos_]) || s_[pos_] == ',')) ++pos_;
}

std::optional<double> Scanner::number() {
    size_t p = pos_;
    size_t n = s_.size();
    if (p < n && (s_[p] == '+' || s_[p] == '-')) ++p;
    size_t int_digits = 0, frac_digits = 0;
    while (p < n && is_digit(s_[p])) { ++p; ++int_digits; }
    if (p < n && s_[p] == '.') {
        size_t q = p + 1;
        while (q < n && is_digit(s_[q])) { ++q; ++frac_digits; }
        if (int_digits + frac_digits > 0) p = q;
    }
    if (int_digits + frac_digits == 0) return std::nullopt;
    if (p < n && (s_[p] == 'e' || s_[p] == 'E')) {
        size_t q = p + 1;
        if (q < n && (s_[q] == '+' || s_[q] == '-')) ++q;
        if (q < n && is_digit(s_[q])) {
            while (q < n && is_digit(s_[q])) ++q;
            p = q;
        }
    }
    double v = std::strtod(s_.substr(pos_, p - pos_).c_str(), nullptr);
    pos_ = p;
    return v;
}

std::optional<double> parse_number_prefix(const std::string& s, size_t* end) {
    Scanner sc(s);
    sc.skip_space();
    auto v = sc.number();
    if (end) *end = sc.pos();
    return v;
}

std::vector<double> parse_number_list(const std::string& s) {
    std::vector<double> out;
    Scanner sc(s);
    for (;;) {
        sc.skip_space_and_commas();
        auto v = sc.number();
        if (!v) break;
        out.push_back(*v);
    }
    return out;
}

std::optional<double> parse_length(const std::string& s) {
    return parse_number_prefix(s);
}

std::optional<double> parse_opacity(const std::string& s) {
    size_t end = 0;
    auto v = parse_number_prefix(s, &end);
    if (!v) return std::nullopt;
    std::string rest = trim(s.substr(end));
    if (rest == "%") *v /= 100.0;
    else if (!rest.empty()) return std::nullopt;
    return std::clamp(*v, 0.0, 1.0);
}

std::optional<Rgb> named_color(const std::string& name) {
    std::string l = to_lower(name);
    for (const auto& nc : kNamedColors) {
        if (l == nc.name) return Rgb{int(nc.value >> 16 & 255), int(nc.value >> 8 & 255), int(nc.value & 255)};
    }
    return std::nullopt;
}

std::optional<Rgb> parse_color(const std::string& text) {
    std::string s = trim(text);
    if (s.empty()) return std::nullopt;
    if (s[0] == '#') {
        std::string h = s.substr(1);
        for (char c : h) if (hex_value(c) < 0) return std::nullopt;
        if (h.size() == 3) {
            return Rgb{hex_value(h[0]) * 17, hex_value(h[1]) * 17, hex_value(h[2]) * 17};
        }
        if (h.size() == 6) {
            auto b = [&](int i) { return hex_value(h[i]) * 16 + hex_value(h[i + 1]); };
            return Rgb{b(0), b(2), b(4)};
        }
        return std::nullopt;
    }
    std::string l = to_lower(s);
    if (l.compare(0, 4, "rgb(") == 0 && l.back() == ')') {
        std::string inner = l.substr(4, l.size() - 5);
        Scanner sc(inner);
        int comps[3];
        for (int i = 0; i < 3; ++i) {
            sc.skip_space_and_commas();
            auto v = sc.number();
            if (!v) return std::nullopt;
            if (sc.peek() == '%') {
                sc.advance();
                comps[i] = round_half_away(std::clamp(*v, 0.0, 100.0) * 255.0 / 100.0);
            } else {
                comps[i] = round_half_away(std::clamp(*v, 0.0, 255.0));
            }
        }
        return Rgb{comps[0], comps[1], comps[2]};
    }
    return named_color(s);
}

Matrix parse_transform(const std::string& s) {
    Matrix m;
    Scanner sc(s);
    for (;;) {
        sc.skip_space_and_commas();
        if (sc.at_end()) break;
        std::string name;
        while (std::isalpha(static_cast<unsigned char>(sc.peek()))) { name += sc.peek(); sc.advance(); }
        sc.skip_space();
        if (name.empty() || sc.peek() != '(') break;
        sc.advance();
        std::vector<double> args;
        for (;;) {
            sc.skip_space_and_commas();
            auto v = sc.number();
            if (!v) break;
            args.push_back(*v);
        }
        sc.skip_space();
        if (sc.peek() != ')') break;
        sc.advance();
        const size_t n = args.size();
        Matrix t;
        bool ok = true;
        if (name == "matrix" && n >= 6) {
            t = {args[0], args[1], args[2], args[3], args[4], args[5]};
        } else if (name == "translate" && n >= 1) {
            t = Matrix::translate(args[0], n >= 2 ? args[1] : 0);
        } else if (name == "scale" && n >= 1) {
            t = Matrix::scale(args[0], n >= 2 ? args[1] : args[0]);
        } else if (name == "rotate" && n >= 1) {
            double a = args[0] * M_PI / 180.0;
            Matrix r{std::cos(a), std::sin(a), -std::sin(a), std::cos(a), 0, 0};
            if (n >= 3) t = Matrix::translate(args[1], args[2]) * r * Matrix::translate(-args[1], -args[2]);
            else t = r;
        } else if (name == "skewX" && n >= 1) {
            t = {1, 0, std::tan(args[0] * M_PI / 180.0), 1, 0, 0};
        } else if (name == "skewY" && n >= 1) {
            t = {1, std::tan(args[0] * M_PI / 180.0), 0, 1, 0, 0};
        } else {
            ok = false;
        }
        if (ok) m = m * t;
    }
    return m;
}

std::map<std::string, std::string> parse_style(const std::string& s) {
    std::map<std::string, std::string> out;
    size_t pos = 0;
    while (pos <= s.size()) {
        size_t semi = s.find(';', pos);
        if (semi == std::string::npos) semi = s.size();
        std::string decl = s.substr(pos, semi - pos);
        pos = semi + 1;
        size_t colon = decl.find(':');
        if (colon == std::string::npos) continue;
        std::string name = to_lower(trim(decl.substr(0, colon)));
        std::string value = trim(decl.substr(colon + 1));
        if (name.empty() || value.empty()) continue;
        out[name] = value;
    }
    return out;
}

}  // namespace svgraster
