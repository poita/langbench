// Liang hyphenation patterns (`.chp` files).
#pragma once

#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace typeset {

/// A set of Liang patterns and exceptions.
class PatternSet {
public:
    int left = 2;   ///< minimum letters before the first break
    int right = 3;  ///< minimum letters after the last break

    /// Parse the text of a `.chp` file. Throws std::runtime_error when malformed.
    static PatternSet parse(std::string_view text);

    /// Load `<dataDir>/hyphen/<name>.chp`.
    static PatternSet load(const std::string& dataDir, const std::string& name);

    void addPattern(std::string_view text);
    void addException(std::string_view text);

    /// Break positions `q` ("after q letters") of a lowercase a-z word, already
    /// filtered by `left`/`right`, in ascending order.
    std::vector<int> breaks(std::string_view word) const;

private:
    std::unordered_map<std::string, std::vector<unsigned char>> patterns_;
    std::unordered_map<std::string, std::vector<int>> exceptions_;
    std::size_t maxKey_ = 0;
};

}  // namespace typeset
