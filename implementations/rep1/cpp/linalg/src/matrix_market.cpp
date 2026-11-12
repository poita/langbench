#include "linalg/matrix_market.hpp"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <vector>

namespace linalg {
namespace {

bool is_blank_char(char c) { return c == ' ' || c == '\t' || c == '\r'; }

std::string lower(std::string_view s) {
    std::string r(s);
    for (char& c : r) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return r;
}

/// Splits text into whitespace-separated tokens.
std::vector<std::string_view> tokens(std::string_view s) {
    std::vector<std::string_view> out;
    std::size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
        const std::size_t b = i;
        while (i < s.size() && !std::isspace(static_cast<unsigned char>(s[i]))) ++i;
        if (i > b) out.push_back(s.substr(b, i - b));
    }
    return out;
}

double to_double(std::string_view t) {
    const std::string s(t);  // strtod needs a terminated string
    char* end = nullptr;
    const double v = std::strtod(s.c_str(), &end);
    if (end == s.c_str() || *end != '\0') throw ParseError("bad number: " + s);
    return v;
}

std::size_t to_size(std::string_view t) {
    const std::string s(t);
    char* end = nullptr;
    const long long v = std::strtoll(s.c_str(), &end, 10);
    if (end == s.c_str() || *end != '\0' || v < 0) throw ParseError("bad integer: " + s);
    return static_cast<std::size_t>(v);
}

bool blank_or_comment_line(std::string_view line, bool allow_comment) {
    std::size_t i = 0;
    while (i < line.size() && is_blank_char(line[i])) ++i;
    return i == line.size() || (allow_comment && line[i] == '%');
}

}  // namespace

Matrix parse_matrix_market(std::string_view text) {
    // --- banner ---
    std::size_t pos = text.find('\n');
    const std::string_view banner = text.substr(0, pos);
    const auto bt = tokens(banner);
    if (bt.size() < 5 || lower(bt[0]) != "%%matrixmarket" || lower(bt[1]) != "matrix")
        throw ParseError("bad Matrix Market banner");
    const std::string format = lower(bt[2]), field = lower(bt[3]), symmetry = lower(bt[4]);
    const bool coordinate = format == "coordinate";
    if (!coordinate && format != "array") throw ParseError("unknown format: " + format);
    if (field != "real" && field != "integer" && field != "pattern")
        throw ParseError("unsupported field: " + field);
    const bool pattern = field == "pattern";
    const bool symmetric = symmetry == "symmetric";
    const bool skew = symmetry == "skew-symmetric";
    if (!symmetric && !skew && symmetry != "general") throw ParseError("unsupported symmetry: " + symmetry);

    // --- skip comments / blank lines up to the size line ---
    std::string_view rest = pos == std::string_view::npos ? std::string_view{} : text.substr(pos + 1);
    std::string_view size_line;
    while (!rest.empty()) {
        const std::size_t nl = rest.find('\n');
        const std::string_view line = rest.substr(0, nl);
        rest = nl == std::string_view::npos ? std::string_view{} : rest.substr(nl + 1);
        if (blank_or_comment_line(line, true)) continue;
        size_line = line;
        break;
    }
    const auto st = tokens(size_line);
    const auto data = tokens(rest);  // everything after the size line
    if (st.size() < (coordinate ? 3u : 2u)) throw ParseError("bad size line");
    const std::size_t rows = to_size(st[0]), cols = to_size(st[1]);
    if ((symmetric || skew) && rows != cols) throw ParseError("symmetric matrix must be square");
    Matrix m(rows, cols);

    if (coordinate) {
        const std::size_t nnz = to_size(st[2]);
        const std::size_t stride = pattern ? 2 : 3;
        if (data.size() < nnz * stride) throw ParseError("too few coordinate entries");
        for (std::size_t e = 0; e < nnz; ++e) {
            const std::size_t i = to_size(data[e * stride]), j = to_size(data[e * stride + 1]);
            if (i < 1 || j < 1 || i > rows || j > cols) throw ParseError("coordinate index out of range");
            const double v = pattern ? 1.0 : to_double(data[e * stride + 2]);
            m(i - 1, j - 1) = v;
            if ((symmetric || skew) && i != j) m(j - 1, i - 1) = skew ? -v : v;
        }
    } else {
        std::size_t next = 0;
        auto take = [&]() {
            if (next >= data.size()) throw ParseError("too few array entries");
            return to_double(data[next++]);
        };
        if (!symmetric && !skew) {
            for (std::size_t j = 0; j < cols; ++j)
                for (std::size_t i = 0; i < rows; ++i) m(i, j) = take();
        } else {
            for (std::size_t j = 0; j < cols; ++j)
                for (std::size_t i = skew ? j + 1 : j; i < rows; ++i) {
                    const double v = take();
                    m(i, j) = v;
                    if (i != j) m(j, i) = skew ? -v : v;
                }
        }
    }
    return m;
}

Matrix read_matrix_market_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw ParseError("cannot open " + path);
    std::ostringstream ss;
    ss << in.rdbuf();
    return parse_matrix_market(ss.str());
}

std::string format_value(double v) {
    if (v == 0.0) v = 0.0;  // -0.0 == 0.0, so this normalises negative zero
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.10e", v);
    return buf;
}

std::string to_matrix_market(const Matrix& m) {
    std::string out = "%%MatrixMarket matrix array real general\n";
    out += std::to_string(m.rows()) + " " + std::to_string(m.cols()) + "\n";
    out.reserve(out.size() + m.rows() * m.cols() * 19);
    for (std::size_t j = 0; j < m.cols(); ++j)
        for (std::size_t i = 0; i < m.rows(); ++i) {
            out += format_value(m(i, j));
            out += '\n';
        }
    return out;
}

void write_matrix_market_file(const std::string& path, const Matrix& m) {
    std::ofstream out(path, std::ios::binary);
    if (!out) throw std::runtime_error("cannot write " + path);
    out << to_matrix_market(m);
    if (!out) throw std::runtime_error("write failed: " + path);
}

}  // namespace linalg
