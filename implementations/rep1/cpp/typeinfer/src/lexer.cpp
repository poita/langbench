#include "typeinfer/lexer.hpp"

#include <string>

#include "typeinfer/errors.hpp"

namespace typeinfer {

namespace {

bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_lower(char c) { return c >= 'a' && c <= 'z'; }
bool is_ident_char(char c) {
    return is_lower(c) || (c >= 'A' && c <= 'Z') || is_digit(c) || c == '_';
}

TokenKind keyword_or_ident(std::string_view s) {
    switch (s.size()) {
        case 2:
            if (s == "in") return TokenKind::KwIn;
            if (s == "if") return TokenKind::KwIf;
            break;
        case 3:
            if (s == "let") return TokenKind::KwLet;
            if (s == "rec") return TokenKind::KwRec;
            if (s == "fun") return TokenKind::KwFun;
            break;
        case 4:
            if (s == "then") return TokenKind::KwThen;
            if (s == "else") return TokenKind::KwElse;
            if (s == "true") return TokenKind::KwTrue;
            break;
        case 5:
            if (s == "false") return TokenKind::KwFalse;
            break;
        default:
            break;
    }
    return TokenKind::Ident;
}

}  // namespace

std::vector<Token> tokenize(std::string_view src) {
    std::vector<Token> out;
    out.reserve(src.size() / 3 + 8);
    std::size_t i = 0;
    const std::size_t n = src.size();
    while (i < n) {
        char c = src[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
            ++i;
            continue;
        }
        std::size_t start = i;
        if (is_digit(c)) {
            while (i < n && is_digit(src[i])) ++i;
            out.push_back({TokenKind::Int, src.substr(start, i - start), start});
            continue;
        }
        if (is_lower(c)) {
            while (i < n && is_ident_char(src[i])) ++i;
            std::string_view text = src.substr(start, i - start);
            out.push_back({keyword_or_ident(text), text, start});
            continue;
        }
        char d = i + 1 < n ? src[i + 1] : '\0';
        TokenKind kind;
        std::size_t len = 2;
        if (c == ';' && d == ';') kind = TokenKind::SemiSemi;
        else if (c == '-' && d == '>') kind = TokenKind::Arrow;
        else if (c == ':' && d == ':') kind = TokenKind::ColonColon;
        else if (c == '<' && d == '=') kind = TokenKind::Le;
        else if (c == '>' && d == '=') kind = TokenKind::Ge;
        else if (c == '&' && d == '&') kind = TokenKind::AndAnd;
        else if (c == '|' && d == '|') kind = TokenKind::OrOr;
        else {
            len = 1;
            switch (c) {
                case '(': kind = TokenKind::LParen; break;
                case ')': kind = TokenKind::RParen; break;
                case '[': kind = TokenKind::LBracket; break;
                case ']': kind = TokenKind::RBracket; break;
                case ';': kind = TokenKind::Semi; break;
                case ',': kind = TokenKind::Comma; break;
                case '+': kind = TokenKind::Plus; break;
                case '-': kind = TokenKind::Minus; break;
                case '*': kind = TokenKind::Star; break;
                case '/': kind = TokenKind::Slash; break;
                case '=': kind = TokenKind::Eq; break;
                case '<': kind = TokenKind::Lt; break;
                case '>': kind = TokenKind::Gt; break;
                default:
                    throw ParseError(std::string("unexpected character '") + c + "'", i);
            }
        }
        out.push_back({kind, src.substr(start, len), start});
        i += len;
    }
    out.push_back({TokenKind::End, std::string_view(), n});
    return out;
}

}  // namespace typeinfer
