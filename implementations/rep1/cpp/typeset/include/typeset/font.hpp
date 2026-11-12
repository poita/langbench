// Font metrics (`.cfm` files) and face resolution.
#pragma once

#include <array>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "typeset/util.hpp"

namespace typeset {

enum class Family { Serif, Sans, Mono };

/// Number of faces shipped with the engine.
constexpr int kFaceCount = 9;

/// Index (0..8) of the face for a style; mono ignores bold and italic.
int faceIndex(Family family, bool bold, bool italic);

/// Face file name for an index, e.g. "serif-bold-italic".
const char* faceName(int index);

/// Metrics of one face. All numbers are in thousandths of an em.
class Face {
public:
    std::string name;
    int ascent = 0, descent = 0;
    int space = 0, stretch = 0, shrink = 0;
    int extra = 0;
    int defaultAdvance = 0;

    /// Parse the text of a `.cfm` file. Throws std::runtime_error when malformed.
    static Face parse(std::string_view text);

    int advance(char32_t c) const;
    int kern(char32_t a, char32_t b) const;

    /// Width of a run of characters in millipoints: advances and kerns are
    /// summed in glyph space and scaled once.
    i64 width(std::u32string_view text, i64 size) const;

    void setGlyph(char32_t c, int adv) { glyphs_[c] = adv; }
    void setKern(char32_t a, char32_t b, int k) { kerns_[(static_cast<std::uint64_t>(a) << 32) | b] = k; }

private:
    std::unordered_map<char32_t, int> glyphs_;
    std::unordered_map<std::uint64_t, int> kerns_;
};

/// The nine faces, loaded from `<dataDir>/faces/<face>.cfm`.
class FontSet {
public:
    /// Load all faces; throws std::runtime_error if a file is missing or malformed.
    static FontSet load(const std::string& dataDir);

    const Face& face(int index) const { return faces_[index]; }
    Face& face(int index) { return faces_[index]; }

private:
    std::array<Face, kFaceCount> faces_;
};

}  // namespace typeset
