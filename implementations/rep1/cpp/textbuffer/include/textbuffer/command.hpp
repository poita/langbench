#pragma once

/// \file command.hpp
/// The textual command language: parsing and execution.

#include <cstdint>
#include <iosfwd>
#include <optional>
#include <string>
#include <string_view>

#include "textbuffer/editor.hpp"

namespace textbuffer {

/// One parsed command line.
struct Command {
    enum class Kind {
        Insert, Delete, DeleteForward, Move, Goto, AddCursor, ClearCursors, Undo, Redo, Print
    };

    Kind kind = Kind::Print;
    std::string text;               ///< Insert: the decoded text.
    Direction direction = Direction::Left;  ///< Move.
    bool select = false;            ///< Move.
    std::uint64_t line = 0;         ///< Goto, AddCursor.
    std::uint64_t col = 0;          ///< Goto, AddCursor.
};

/// Decodes `\n` to a newline and `\\` to a backslash. Any other backslash is
/// kept literally.
std::string decodeInsertText(std::string_view encoded);

/// Parses one command line (without its terminating newline). Returns
/// nullopt if the line is not a valid command.
std::optional<Command> parseCommand(std::string_view line);

/// Runs \p command on \p editor; `print` writes to \p out.
void execute(Editor& editor, const Command& command, std::ostream& out);

}  // namespace textbuffer
