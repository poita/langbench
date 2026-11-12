#include "svgraster/xml.hpp"

#include <cctype>
#include <cstdlib>

namespace svgraster {

namespace {

void append_utf8(std::string& out, unsigned long cp) {
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

bool is_space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

std::string strip_prefix(const std::string& name) {
    auto pos = name.rfind(':');
    return pos == std::string::npos ? name : name.substr(pos + 1);
}

class Parser {
public:
    explicit Parser(const std::string& t) : s_(t) {}

    std::unique_ptr<Element> run() {
        std::unique_ptr<Element> root;
        std::vector<Element*> stack;
        while (pos_ < s_.size()) {
            size_t lt = s_.find('<', pos_);
            if (lt == std::string::npos) break;
            pos_ = lt;
            if (starts("<?")) {
                skip_past("?>");
            } else if (starts("<!--")) {
                skip_past("-->");
            } else if (starts("<![CDATA[")) {
                skip_past("]]>");
            } else if (starts("<!")) {
                skip_doctype();
            } else if (starts("</")) {
                skip_past(">");
                if (!stack.empty()) stack.pop_back();
            } else {
                std::unique_ptr<Element> el = std::make_unique<Element>();
                bool self_closing = parse_start_tag(*el);
                Element* raw = el.get();
                if (!root) {
                    root = std::move(el);
                } else if (!stack.empty()) {
                    stack.back()->children.push_back(std::move(el));
                } else {
                    continue;  // content after the document element closed
                }
                if (!self_closing) stack.push_back(raw);
                if (stack.empty() && root && self_closing) break;
            }
        }
        return root;
    }

private:
    bool starts(const char* lit) const { return s_.compare(pos_, std::char_traits<char>::length(lit), lit) == 0; }

    void skip_past(const char* terminator) {
        size_t p = s_.find(terminator, pos_);
        pos_ = p == std::string::npos ? s_.size() : p + std::char_traits<char>::length(terminator);
    }

    void skip_doctype() {
        int depth = 0;
        char quote = 0;
        for (; pos_ < s_.size(); ++pos_) {
            char c = s_[pos_];
            if (quote) {
                if (c == quote) quote = 0;
            } else if (c == '"' || c == '\'') {
                quote = c;
            } else if (c == '[') {
                ++depth;
            } else if (c == ']') {
                --depth;
            } else if (c == '>' && depth <= 0) {
                ++pos_;
                return;
            }
        }
    }

    void skip_spaces() {
        while (pos_ < s_.size() && is_space(s_[pos_])) ++pos_;
    }

    // Parses `<name attrs>` or `<name attrs/>`; returns true when self-closing.
    bool parse_start_tag(Element& el) {
        ++pos_;  // '<'
        size_t start = pos_;
        while (pos_ < s_.size() && !is_space(s_[pos_]) && s_[pos_] != '>' && s_[pos_] != '/') ++pos_;
        el.tag = strip_prefix(s_.substr(start, pos_ - start));
        while (pos_ < s_.size()) {
            skip_spaces();
            if (pos_ >= s_.size()) break;
            char c = s_[pos_];
            if (c == '>') { ++pos_; return false; }
            if (c == '/') {
                ++pos_;
                skip_spaces();
                if (pos_ < s_.size() && s_[pos_] == '>') ++pos_;
                return true;
            }
            size_t ns = pos_;
            while (pos_ < s_.size() && !is_space(s_[pos_]) && s_[pos_] != '=' && s_[pos_] != '>' && s_[pos_] != '/') ++pos_;
            std::string name = s_.substr(ns, pos_ - ns);
            skip_spaces();
            std::string value;
            bool has_value = false;
            if (pos_ < s_.size() && s_[pos_] == '=') {
                ++pos_;
                skip_spaces();
                if (pos_ < s_.size() && (s_[pos_] == '"' || s_[pos_] == '\'')) {
                    char q = s_[pos_++];
                    size_t vs = pos_;
                    while (pos_ < s_.size() && s_[pos_] != q) ++pos_;
                    value = decode_entities(s_.substr(vs, pos_ - vs));
                    if (pos_ < s_.size()) ++pos_;
                    has_value = true;
                }
            }
            if (name.empty()) { ++pos_; continue; }
            if (!has_value) continue;
            if (name == "xmlns" || name.compare(0, 6, "xmlns:") == 0) continue;
            el.attrs[strip_prefix(name)] = value;
        }
        return false;
    }

    const std::string& s_;
    size_t pos_ = 0;
};

}  // namespace

std::string decode_entities(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '&') { out += s[i]; continue; }
        size_t semi = s.find(';', i);
        if (semi == std::string::npos || semi - i > 12) { out += s[i]; continue; }
        std::string ent = s.substr(i + 1, semi - i - 1);
        bool ok = true;
        if (ent == "amp") out += '&';
        else if (ent == "lt") out += '<';
        else if (ent == "gt") out += '>';
        else if (ent == "quot") out += '"';
        else if (ent == "apos") out += '\'';
        else if (ent.size() >= 2 && ent[0] == '#') {
            bool hex = ent[1] == 'x' || ent[1] == 'X';
            std::string digits = ent.substr(hex ? 2 : 1);
            if (digits.empty()) ok = false;
            for (char c : digits) {
                if (hex ? !std::isxdigit(static_cast<unsigned char>(c)) : !std::isdigit(static_cast<unsigned char>(c))) ok = false;
            }
            if (ok) append_utf8(out, std::strtoul(digits.c_str(), nullptr, hex ? 16 : 10));
        } else {
            ok = false;
        }
        if (ok) i = semi; else out += s[i];
    }
    return out;
}

std::unique_ptr<Element> parse_xml(const std::string& text) {
    Parser p(text);
    return p.run();
}

}  // namespace svgraster
