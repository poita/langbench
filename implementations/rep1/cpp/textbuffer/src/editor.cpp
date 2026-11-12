#include "textbuffer/editor.hpp"

#include <algorithm>
#include <cassert>
#include <ostream>
#include <utility>

namespace textbuffer {

namespace {

// The composed effect of the replacements applied so far on the positions that
// have not been visited yet. Every unvisited position is at or after the end
// of the latest replacement, so it suffices to remember where that end was in
// the original document and where it is now: a later position keeps its
// distance from it.
class Shift {
public:
    Position map(Position p) const noexcept {
        if (p.line == originalEnd_.line) {
            return {currentEnd_.line, currentEnd_.col + (p.col - originalEnd_.col)};
        }
        return {p.line - originalEnd_.line + currentEnd_.line, p.col};
    }

    void update(Position originalEnd, Position currentEnd) noexcept {
        originalEnd_ = originalEnd;
        currentEnd_ = currentEnd;
    }

private:
    Position originalEnd_{0, 0};
    Position currentEnd_{0, 0};
};

}  // namespace

Editor::Editor(Document doc) : doc_(std::move(doc)) {
    Cursor c;
    c.primary = true;
    cursors_.push_back(c);
}

void Editor::resetGoalColumns() noexcept {
    for (Cursor& c : cursors_) c.goal = c.head.col;
}

void Editor::insert(std::string_view text) { edit(EditKind::Insert, text); }
void Editor::deleteBackward() { edit(EditKind::DeleteBackward, {}); }
void Editor::deleteForward() { edit(EditKind::DeleteForward, {}); }

void Editor::edit(EditKind kind, std::string_view text) {
    UndoEntry entry;
    entry.before = cursors_;

    Shift shift;
    for (Cursor& c : cursors_) {
        // The cursor's positions in the document as it is now.
        const Position head = shift.map(c.head);
        Position start = shift.map(c.start());
        Position end = shift.map(c.end());
        // Where the replaced range ends in the original document.
        Position originalEnd = c.end();

        if (!c.hasSelection() && kind != EditKind::Insert) {
            if (kind == EditKind::DeleteBackward) {
                if (head.col > 0) {
                    start = {head.line, head.col - 1};
                } else if (head.line > 0) {
                    start = {head.line - 1, static_cast<std::uint32_t>(doc_.line(head.line - 1).size())};
                }
                // else: at (0, 0), the range stays empty.
            } else {
                if (head.col < doc_.line(head.line).size()) {
                    end = {head.line, head.col + 1};
                    originalEnd = {c.head.line, c.head.col + 1};
                } else if (head.line + 1 < doc_.lineCount()) {
                    end = {head.line + 1, 0};
                    originalEnd = {c.head.line + 1, 0};
                }
                // else: at the end of the document, the range stays empty.
            }
        }

        const std::string_view inserted = kind == EditKind::Insert ? text : std::string_view{};
        if (start != end || !inserted.empty()) {
            entry.replacements.push_back({start, doc_.textBetween(start, end), std::string(inserted)});
            doc_.replace(start, end, inserted);
        }
        const Position newHead = advance(start, inserted);
        c.head = newHead;
        c.anchor.reset();
        shift.update(originalEnd, newHead);
    }

    normalize(cursors_);
    resetGoalColumns();
    if (!entry.replacements.empty()) {
        entry.after = cursors_;
        undo_.push_back(std::move(entry));
        redo_.clear();
    }
}

void Editor::move(Direction direction, bool select) {
    for (Cursor& c : cursors_) c = moveCursor(c, doc_, direction, select);
    normalize(cursors_);
    if (direction != Direction::Up && direction != Direction::Down) resetGoalColumns();
}

void Editor::goTo(std::uint64_t line, std::uint64_t col) {
    Cursor c;
    c.primary = true;
    c.head = doc_.clamp(line, col);
    c.goal = c.head.col;
    cursors_.assign(1, c);
}

void Editor::addCursor(std::uint64_t line, std::uint64_t col) {
    Cursor c;
    c.head = doc_.clamp(line, col);
    cursors_.push_back(c);
    normalize(cursors_);
    resetGoalColumns();
}

void Editor::clearCursors() {
    cursors_.erase(std::remove_if(cursors_.begin(), cursors_.end(),
                                  [](const Cursor& c) { return !c.primary; }),
                   cursors_.end());
    resetGoalColumns();
}

void Editor::applyForward(const UndoEntry& entry) {
    for (const Replacement& r : entry.replacements) {
        doc_.replace(r.start, advance(r.start, r.removed), r.inserted);
    }
}

void Editor::applyBackward(const UndoEntry& entry) {
    for (auto it = entry.replacements.rbegin(); it != entry.replacements.rend(); ++it) {
        doc_.replace(it->start, advance(it->start, it->inserted), it->removed);
    }
}

bool Editor::undo() {
    const bool any = !undo_.empty();
    if (any) {
        UndoEntry entry = std::move(undo_.back());
        undo_.pop_back();
        applyBackward(entry);
        cursors_ = entry.before;
        redo_.push_back(std::move(entry));
    }
    resetGoalColumns();
    return any;
}

bool Editor::redo() {
    const bool any = !redo_.empty();
    if (any) {
        UndoEntry entry = std::move(redo_.back());
        redo_.pop_back();
        applyForward(entry);
        cursors_ = entry.after;
        undo_.push_back(std::move(entry));
    }
    resetGoalColumns();
    return any;
}

void Editor::print(std::ostream& out) const {
    for (const std::string& line : doc_.lines()) {
        out.write(line.data(), static_cast<std::streamsize>(line.size()));
        out.put('\n');
    }
    for (const Cursor& c : cursors_) {
        out << "cursor " << c.head.line << ' ' << c.head.col << '\n';
    }
    out << "--\n";
}

}  // namespace textbuffer
