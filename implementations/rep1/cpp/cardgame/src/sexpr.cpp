#include "spiremark/sexpr.hpp"

#include <cerrno>
#include <cstdlib>

namespace spiremark {

bool Sexpr::is_form(const char* head) const {
    return kind == Kind::List && !items.empty() && items[0].kind == Kind::Symbol &&
           items[0].text == head;
}

static void print_to(const Sexpr& e, std::string& out) {
    switch (e.kind) {
        case Sexpr::Kind::Symbol: out += e.text; break;
        case Sexpr::Kind::Integer: out += std::to_string(e.value); break;
        case Sexpr::Kind::String:
            out += '"';
            out += e.text;
            out += '"';
            break;
        case Sexpr::Kind::List:
            out += '(';
            for (std::size_t i = 0; i < e.items.size(); ++i) {
                if (i) out += ' ';
                print_to(e.items[i], out);
            }
            out += ')';
            break;
    }
}

std::string Sexpr::print() const {
    std::string out;
    print_to(*this, out);
    return out;
}

namespace {

bool is_space(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

bool is_atom_char(char c) {
    return !is_space(c) && c != '(' && c != ')' && c != ';' && c != '"';
}

bool is_integer_atom(const std::string& a) {
    std::size_t i = (!a.empty() && a[0] == '-') ? 1 : 0;
    if (i >= a.size()) return false;
    for (; i < a.size(); ++i)
        if (a[i] < '0' || a[i] > '9') return false;
    return true;
}

class Reader {
public:
    explicit Reader(const std::string& s) : s_(s) {}

    std::vector<Sexpr> read_all() {
        std::vector<Sexpr> out;
        std::vector<Sexpr> stack;  // open lists
        for (;;) {
            skip_trivia();
            if (pos_ >= s_.size()) break;
            char c = s_[pos_];
            if (c == '(') {
                ++pos_;
                stack.emplace_back();
            } else if (c == ')') {
                ++pos_;
                if (stack.empty()) throw DatabaseError("unbalanced ')'");
                Sexpr done = std::move(stack.back());
                stack.pop_back();
                emit(std::move(done), stack, out);
            } else if (c == '"') {
                ++pos_;
                std::size_t start = pos_;
                while (pos_ < s_.size() && s_[pos_] != '"' && s_[pos_] != '\n') ++pos_;
                if (pos_ >= s_.size() || s_[pos_] != '"')
                    throw DatabaseError("unterminated string");
                Sexpr str;
                str.kind = Sexpr::Kind::String;
                str.text = s_.substr(start, pos_ - start);
                ++pos_;
                emit(std::move(str), stack, out);
            } else {
                std::size_t start = pos_;
                while (pos_ < s_.size() && is_atom_char(s_[pos_])) ++pos_;
                std::string atom = s_.substr(start, pos_ - start);
                Sexpr a;
                if (is_integer_atom(atom)) {
                    errno = 0;
                    char* end = nullptr;
                    long long v = std::strtoll(atom.c_str(), &end, 10);
                    if (errno == ERANGE) throw DatabaseError("integer out of range");
                    a.kind = Sexpr::Kind::Integer;
                    a.value = v;
                } else {
                    a.kind = Sexpr::Kind::Symbol;
                }
                a.text = std::move(atom);
                emit(std::move(a), stack, out);
            }
        }
        if (!stack.empty()) throw DatabaseError("unbalanced '('");
        return out;
    }

private:
    static void emit(Sexpr e, std::vector<Sexpr>& stack, std::vector<Sexpr>& out) {
        if (stack.empty())
            out.push_back(std::move(e));
        else
            stack.back().items.push_back(std::move(e));
    }

    void skip_trivia() {
        while (pos_ < s_.size()) {
            char c = s_[pos_];
            if (is_space(c)) {
                ++pos_;
            } else if (c == ';') {
                while (pos_ < s_.size() && s_[pos_] != '\n') ++pos_;
            } else {
                break;
            }
        }
    }

    const std::string& s_;
    std::size_t pos_ = 0;
};

}  // namespace

std::vector<Sexpr> parse_sexprs(const std::string& source) {
    Reader r(source);
    return r.read_all();
}

}  // namespace spiremark
