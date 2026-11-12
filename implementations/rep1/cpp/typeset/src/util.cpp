#include "typeset/util.hpp"

namespace typeset {

std::string toRoman(i64 n) {
    static const struct { int v; const char* s; } table[] = {
        {1000, "m"}, {900, "cm"}, {500, "d"}, {400, "cd"}, {100, "c"}, {90, "xc"}, {50, "l"},
        {40, "xl"},  {10, "x"},   {9, "ix"},  {5, "v"},    {4, "iv"},  {1, "i"}};
    std::string out;
    for (const auto& e : table) {
        while (n >= e.v) {
            out += e.s;
            n -= e.v;
        }
    }
    return out;
}

std::string toLetters(i64 n) {
    std::string out;
    while (n > 0) {
        --n;
        out.insert(out.begin(), static_cast<char>('a' + n % 26));
        n /= 26;
    }
    return out;
}

std::u32string utf8ToU32(std::string_view s) {
    std::u32string out;
    out.reserve(s.size());
    std::size_t i = 0;
    while (i < s.size()) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        char32_t cp;
        int extra;
        if (c < 0x80) { cp = c; extra = 0; }
        else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; extra = 1; }
        else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; extra = 2; }
        else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; extra = 3; }
        else { out.push_back(0xFFFD); ++i; continue; }
        if (i + extra >= s.size() && extra > 0) { out.push_back(0xFFFD); break; }
        ++i;
        for (int k = 0; k < extra; ++k, ++i) cp = (cp << 6) | (static_cast<unsigned char>(s[i]) & 0x3F);
        out.push_back(cp);
    }
    return out;
}

void appendUtf8(std::string& out, char32_t cp) {
    if (cp < 0x80) {
        out += static_cast<char>(cp);
    } else if (cp < 0x800) {
        out += static_cast<char>(0xC0 | (cp >> 6));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += static_cast<char>(0xE0 | (cp >> 12));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (cp >> 18));
        out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    }
}

std::string u32ToUtf8(std::u32string_view s) {
    std::string out;
    out.reserve(s.size());
    for (char32_t c : s) appendUtf8(out, c);
    return out;
}

std::size_t utf8Length(std::string_view s) {
    std::size_t n = 0;
    for (unsigned char c : s)
        if ((c & 0xC0) != 0x80) ++n;
    return n;
}

std::string_view trim(std::string_view s, std::string_view chars) {
    std::size_t b = s.find_first_not_of(chars);
    if (b == std::string_view::npos) return {};
    std::size_t e = s.find_last_not_of(chars);
    return s.substr(b, e - b + 1);
}

}  // namespace typeset
