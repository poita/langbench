#include "typeset/font.hpp"

#include <fstream>
#include <sstream>
#include <stdexcept>

namespace typeset {

namespace {
const char* const kFaceNames[kFaceCount] = {"serif",        "serif-bold", "serif-italic",
                                            "serif-bold-italic", "sans",       "sans-bold",
                                            "sans-italic", "sans-bold-italic", "mono"};
}

int faceIndex(Family family, bool bold, bool italic) {
    if (family == Family::Mono) return 8;
    return (family == Family::Serif ? 0 : 4) + (bold ? 1 : 0) + (italic ? 2 : 0);
}

const char* faceName(int index) { return kFaceNames[index]; }

namespace {
std::vector<std::string> fields(std::string_view line) {
    std::vector<std::string> out;
    std::size_t i = 0;
    while (i < line.size()) {
        while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) ++i;
        std::size_t j = i;
        while (j < line.size() && line[j] != ' ' && line[j] != '\t') ++j;
        if (j > i) out.emplace_back(line.substr(i, j - i));
        i = j;
    }
    return out;
}
}  // namespace

Face Face::parse(std::string_view text) {
    Face f;
    std::size_t pos = 0;
    while (pos <= text.size()) {
        std::size_t nl = text.find('\n', pos);
        if (nl == std::string_view::npos) nl = text.size();
        std::string_view line = text.substr(pos, nl - pos);
        pos = nl + 1;
        std::size_t hash = line.find('#');
        if (hash != std::string_view::npos) line = line.substr(0, hash);
        auto v = fields(line);
        if (v.empty()) continue;
        const std::string& r = v[0];
        auto num = [&](std::size_t k) { return std::stoi(v.at(k)); };
        if (r == "face") f.name = v.at(1);
        else if (r == "ascent") f.ascent = num(1);
        else if (r == "descent") f.descent = num(1);
        else if (r == "space") { f.space = num(1); f.stretch = num(2); f.shrink = num(3); }
        else if (r == "extra") f.extra = num(1);
        else if (r == "default") f.defaultAdvance = num(1);
        else if (r == "glyph") f.setGlyph(static_cast<char32_t>(num(1)), num(2));
        else if (r == "kern") f.setKern(static_cast<char32_t>(num(1)), static_cast<char32_t>(num(2)), num(3));
        else if (r == "cfm") {}
        else throw std::runtime_error("unknown record in font metrics: " + r);
    }
    return f;
}

int Face::advance(char32_t c) const {
    auto it = glyphs_.find(c);
    return it == glyphs_.end() ? defaultAdvance : it->second;
}

int Face::kern(char32_t a, char32_t b) const {
    if (kerns_.empty()) return 0;
    auto it = kerns_.find((static_cast<std::uint64_t>(a) << 32) | b);
    return it == kerns_.end() ? 0 : it->second;
}

i64 Face::width(std::u32string_view text, i64 size) const {
    i64 units = 0;
    for (std::size_t i = 0; i < text.size(); ++i) {
        units += advance(text[i]);
        if (i + 1 < text.size()) units += kern(text[i], text[i + 1]);
    }
    return scaleUnits(units, size);
}

FontSet FontSet::load(const std::string& dataDir) {
    FontSet fs;
    for (int i = 0; i < kFaceCount; ++i) {
        std::string path = dataDir + "/faces/" + kFaceNames[i] + ".cfm";
        std::ifstream in(path, std::ios::binary);
        if (!in) throw std::runtime_error("cannot open " + path);
        std::stringstream ss;
        ss << in.rdbuf();
        fs.faces_[i] = Face::parse(ss.str());
    }
    return fs;
}

}  // namespace typeset
