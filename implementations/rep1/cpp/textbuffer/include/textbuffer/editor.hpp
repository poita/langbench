#pragma once

/// \file editor.hpp
/// The editing core: a document, a set of cursors and an undo/redo history.

#include <cstdint>
#include <iosfwd>
#include <string>
#include <string_view>
#include <vector>

#include "textbuffer/cursor.hpp"
#include "textbuffer/document.hpp"
#include "textbuffer/movement.hpp"

namespace textbuffer {

/// One change to the document: \p removed was replaced by \p inserted at
/// \p start. \p start is expressed in the document as it was immediately
/// before this replacement was applied.
struct Replacement {
    Position start;
    std::string removed;
    std::string inserted;
};

/// One undoable edit command: its replacements in application order and the
/// cursor sets before and after it.
struct UndoEntry {
    std::vector<Cursor> before;
    std::vector<Cursor> after;
    std::vector<Replacement> replacements;
};

/// A document edited through multiple cursors, with undo and redo.
///
/// Every public mutating operation leaves the cursor set normalized (see
/// normalize()) and, except for vertical movement, resets every cursor's goal
/// column to the column of its head.
class Editor {
public:
    /// An editor on \p doc with one primary cursor at (0, 0).
    explicit Editor(Document doc = Document());

    const Document& document() const noexcept { return doc_; }
    /// The cursors in cursor order (ascending range start).
    const std::vector<Cursor>& cursors() const noexcept { return cursors_; }
    std::size_t undoDepth() const noexcept { return undo_.size(); }
    std::size_t redoDepth() const noexcept { return redo_.size(); }

    /// Replaces every selection (or inserts at every caret) with \p text,
    /// which may contain '\n'. Empty text does nothing.
    void insert(std::string_view text);
    /// Backspace: deletes each selection or the character before each caret.
    void deleteBackward();
    /// Deletes each selection or the character after each caret.
    void deleteForward();

    /// Moves every cursor; see moveCursor().
    void move(Direction direction, bool select = false);
    /// Replaces all cursors with one primary cursor at the clamped position.
    void goTo(std::uint64_t line, std::uint64_t col);
    /// Adds a non-primary cursor at the clamped position (merging if needed).
    void addCursor(std::uint64_t line, std::uint64_t col);
    /// Removes every cursor except the primary one.
    void clearCursors();

    /// Reverts the latest edit; returns false when there is nothing to undo.
    bool undo();
    /// Re-applies the latest undone edit; returns false when there is none.
    bool redo();

    /// Writes the document lines, one `cursor <line> <col>` line per cursor
    /// and a terminating `--` line.
    void print(std::ostream& out) const;

private:
    enum class EditKind { Insert, DeleteBackward, DeleteForward };

    void edit(EditKind kind, std::string_view text);
    void resetGoalColumns() noexcept;
    void applyForward(const UndoEntry& entry);
    void applyBackward(const UndoEntry& entry);

    Document doc_;
    std::vector<Cursor> cursors_;
    std::vector<UndoEntry> undo_;
    std::vector<UndoEntry> redo_;
};

}  // namespace textbuffer
