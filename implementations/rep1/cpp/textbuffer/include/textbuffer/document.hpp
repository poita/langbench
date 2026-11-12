#pragma once

/// \file document.hpp
/// The text of a buffer: a sequence of lines with splice-style editing.

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "textbuffer/position.hpp"

namespace textbuffer {

/// A document is `L >= 1` lines of text. The text of the document is the lines
/// joined by single '\n' characters, without a trailing newline.
///
/// Edits are O(line length + inserted length) inside a line, plus O(L) when
/// lines are added or removed.
class Document {
public:
    /// An empty document: one empty line.
    Document();

    /// A document made of \p lines (none may contain '\n'). An empty vector
    /// yields one empty line.
    explicit Document(std::vector<std::string> lines);

    /// Splits \p text on '\n'. `fromText("a\nb")` has two lines.
    static Document fromText(std::string_view text);

    std::size_t lineCount() const noexcept { return lines_.size(); }
    const std::string& line(std::size_t index) const { return lines_[index]; }
    const std::vector<std::string>& lines() const noexcept { return lines_; }

    /// The whole text, lines joined by '\n'.
    std::string text() const;

    /// The last valid position of the document.
    Position endPosition() const noexcept;

    /// Clamps a (possibly out of range) line and column: the line is clamped
    /// to `[0, L-1]` first, then the column to the length of that line.
    Position clamp(std::uint64_t line, std::uint64_t col) const noexcept;

    /// The text between two valid positions `a <= b` ('\n' joins lines).
    std::string textBetween(Position a, Position b) const;

    /// Replaces the text between the valid positions `start <= end` with
    /// \p text, which may contain '\n'.
    void replace(Position start, Position end, std::string_view text);

private:
    std::vector<std::string> lines_;
};

}  // namespace textbuffer
