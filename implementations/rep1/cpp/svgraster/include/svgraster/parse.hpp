// Parsing of SVG attribute micro-syntaxes: numbers, lengths, colours,
// opacities, transform lists and style declarations.
#pragma once

#include <map>
#include <optional>
#include <string>
#include <vector>

#include "svgraster/geometry.hpp"

namespace svgraster {

/// An 8-bit sRGB colour.
struct Rgb {
    int r = 0, g = 0, b = 0;
    bool operator==(const Rgb& o) const { return r == o.r && g == o.g && b == o.b; }
};

/// A scanner over a string, used for number lists and path data.
class Scanner {
public:
    explicit Scanner(const std::string& s, size_t pos = 0) : s_(s), pos_(pos) {}

    bool at_end() const { return pos_ >= s_.size(); }
    size_t pos() const { return pos_; }
    char peek() const { return pos_ < s_.size() ? s_[pos_] : '\0'; }
    void advance() { ++pos_; }
    void skip_space();
    void skip_space_and_commas();

    /// Parses a number at the current position (no leading whitespace skipped).
    /// On failure returns nullopt and leaves the position unchanged.
    std::optional<double> number();

private:
    const std::string& s_;
    size_t pos_;
};

/// Parses a leading SVG number from `s` (after optional whitespace). `end`
/// receives the index just past it.
std::optional<double> parse_number_prefix(const std::string& s, size_t* end = nullptr);

/// Parses a list of numbers separated by whitespace and/or commas, stopping at
/// the first token that is not a number.
std::vector<double> parse_number_list(const std::string& s);

/// A length: a number optionally followed by `px`. Returns nullopt when the
/// value does not start with a number.
std::optional<double> parse_length(const std::string& s);

/// An opacity: a number or percentage clamped to [0, 1]; nullopt if malformed.
std::optional<double> parse_opacity(const std::string& s);

/// Parses `#rgb`, `#rrggbb`, `rgb(...)` or a colour keyword. `none` and
/// `currentColor` are not handled here. Returns nullopt for anything else.
std::optional<Rgb> parse_color(const std::string& s);

/// Looks up one of the 147 SVG 1.1 colour keywords (case-insensitive).
std::optional<Rgb> named_color(const std::string& name);

/// Parses a transform list into a single matrix. Unknown functions are skipped.
Matrix parse_transform(const std::string& s);

/// Parses a `style` attribute into lower-cased property names and trimmed
/// values. Declarations with empty values are dropped; later ones win.
std::map<std::string, std::string> parse_style(const std::string& s);

std::string trim(const std::string& s);
std::string to_lower(const std::string& s);

}  // namespace svgraster
