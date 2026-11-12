#include "sat/dimacs.hpp"

#include <cstddef>
#include <iterator>

#include "sat/solver.hpp"

namespace sat {

namespace {

bool is_blank(char c) { return c == ' ' || c == '\t' || c == '\r'; }

/// Tokenises one line into whitespace-separated pieces.
class LineTokens {
public:
    explicit LineTokens(std::string_view line) : s_(line) {}
    bool next(std::string_view& tok) {
        while (pos_ < s_.size() && is_blank(s_[pos_])) ++pos_;
        if (pos_ >= s_.size()) return false;
        std::size_t start = pos_;
        while (pos_ < s_.size() && !is_blank(s_[pos_])) ++pos_;
        tok = s_.substr(start, pos_ - start);
        return true;
    }

private:
    std::string_view s_;
    std::size_t pos_ = 0;
};

long long parse_int(std::string_view tok) {
    std::size_t i = 0;
    bool neg = false;
    if (i < tok.size() && (tok[i] == '-' || tok[i] == '+')) {
        neg = tok[i] == '-';
        ++i;
    }
    if (i >= tok.size()) throw ParseError("invalid integer '" + std::string(tok) + "'");
    long long v = 0;
    for (; i < tok.size(); ++i) {
        if (tok[i] < '0' || tok[i] > '9') throw ParseError("invalid integer '" + std::string(tok) + "'");
        v = v * 10 + (tok[i] - '0');
        if (v > 2000000000LL) throw ParseError("integer too large");
    }
    return neg ? -v : v;
}

}  // namespace

Cnf parse_dimacs(std::string_view text) {
    Cnf cnf;
    bool have_header = false;
    long long declared_clauses = 0;
    std::vector<int> current;

    std::size_t pos = 0;
    while (pos < text.size()) {
        std::size_t eol = text.find('\n', pos);
        if (eol == std::string_view::npos) eol = text.size();
        std::string_view line = text.substr(pos, eol - pos);
        pos = eol + 1;

        LineTokens toks(line);
        std::string_view tok;
        if (!toks.next(tok)) continue;  // blank line
        if (tok[0] == 'c') continue;    // comment

        if (tok[0] == 'p') {
            if (have_header) throw ParseError("duplicate header");
            std::string_view a, b, c;
            if (tok != "p" || !toks.next(a) || a != "cnf" || !toks.next(b) || !toks.next(c))
                throw ParseError("malformed header");
            long long v = parse_int(b);
            declared_clauses = parse_int(c);
            if (v < 0 || declared_clauses < 0) throw ParseError("negative count in header");
            cnf.num_vars = static_cast<int>(v);
            have_header = true;
            continue;
        }

        if (!have_header) throw ParseError("clause data before header");
        do {
            long long v = parse_int(tok);
            if (v == 0) {
                cnf.clauses.push_back(std::move(current));
                current.clear();
            } else {
                long long mag = v < 0 ? -v : v;
                if (mag > cnf.num_vars) throw ParseError("literal out of range: " + std::string(tok));
                current.push_back(static_cast<int>(v));
            }
        } while (toks.next(tok));
    }

    if (!have_header) throw ParseError("missing header");
    if (!current.empty()) throw ParseError("last clause is not terminated by 0");
    if (static_cast<long long>(cnf.clauses.size()) != declared_clauses)
        throw ParseError("clause count does not match header");
    return cnf;
}

Cnf parse_dimacs(std::istream& in) {
    std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return parse_dimacs(std::string_view(text));
}

bool load(Solver& solver, const Cnf& cnf) {
    while (solver.num_vars() < cnf.num_vars) solver.new_var();
    std::vector<Lit> lits;
    for (const auto& clause : cnf.clauses) {
        lits.clear();
        for (int d : clause) lits.push_back(Lit::from_dimacs(d));
        if (!solver.add_clause(lits)) return false;
    }
    return true;
}

bool satisfies(const Cnf& cnf, const std::vector<bool>& model) {
    for (const auto& clause : cnf.clauses) {
        bool sat = false;
        for (int d : clause) {
            Lit l = Lit::from_dimacs(d);
            if (model[l.var()] != l.negative()) {
                sat = true;
                break;
            }
        }
        if (!sat) return false;
    }
    return true;
}

void write_result(std::ostream& out, Result result, const std::vector<bool>& model) {
    if (result == Result::Unsat) {
        out << "UNSAT\n";
        return;
    }
    std::string line;
    for (std::size_t v = 0; v < model.size(); ++v) {
        if (!model[v]) line += '-';
        line += std::to_string(v + 1);
        line += ' ';
    }
    line += "0\n";
    out << "SAT\n" << line;
}

}  // namespace sat
