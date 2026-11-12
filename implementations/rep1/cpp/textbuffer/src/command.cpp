#include "textbuffer/command.hpp"

#include <charconv>
#include <ostream>

namespace textbuffer {

std::string decodeInsertText(std::string_view encoded) {
    std::string out;
    out.reserve(encoded.size());
    for (std::size_t i = 0; i < encoded.size(); ++i) {
        if (encoded[i] == '\\' && i + 1 < encoded.size()) {
            if (encoded[i + 1] == 'n') {
                out += '\n';
                ++i;
                continue;
            }
            if (encoded[i + 1] == '\\') {
                out += '\\';
                ++i;
                continue;
            }
        }
        out += encoded[i];
    }
    return out;
}

namespace {

bool parseNumber(std::string_view s, std::uint64_t& value) {
    if (s.empty()) return false;
    const auto [ptr, ec] = std::from_chars(s.data(), s.data() + s.size(), value);
    return ec == std::errc() && ptr == s.data() + s.size();
}

// Splits "a b c" into words on single spaces.
bool parseTwoNumbers(std::string_view args, Command& cmd) {
    const auto space = args.find(' ');
    if (space == std::string_view::npos) return false;
    return parseNumber(args.substr(0, space), cmd.line) && parseNumber(args.substr(space + 1), cmd.col);
}

bool parseDirection(std::string_view s, Direction& d) {
    if (s == "left") d = Direction::Left;
    else if (s == "right") d = Direction::Right;
    else if (s == "up") d = Direction::Up;
    else if (s == "down") d = Direction::Down;
    else if (s == "home") d = Direction::Home;
    else if (s == "end") d = Direction::End;
    else return false;
    return true;
}

}  // namespace

std::optional<Command> parseCommand(std::string_view line) {
    using Kind = Command::Kind;
    Command cmd;
    const auto space = line.find(' ');
    const std::string_view word = line.substr(0, space);
    const std::string_view args = space == std::string_view::npos ? std::string_view{} : line.substr(space + 1);
    const bool hasArgs = space != std::string_view::npos;

    if (word == "insert") {
        if (!hasArgs || args.empty()) return std::nullopt;
        cmd.kind = Kind::Insert;
        cmd.text = decodeInsertText(args);
        return cmd;
    }
    if (word == "move") {
        if (!hasArgs) return std::nullopt;
        std::string_view dir = args;
        if (args.size() > 7 && args.substr(args.size() - 7) == " select") {
            cmd.select = true;
            dir = args.substr(0, args.size() - 7);
        }
        if (!parseDirection(dir, cmd.direction)) return std::nullopt;
        cmd.kind = Kind::Move;
        return cmd;
    }
    if (word == "goto" || word == "add-cursor") {
        if (!hasArgs || !parseTwoNumbers(args, cmd)) return std::nullopt;
        cmd.kind = word == "goto" ? Kind::Goto : Kind::AddCursor;
        return cmd;
    }
    if (hasArgs) return std::nullopt;
    if (word == "delete") cmd.kind = Kind::Delete;
    else if (word == "delete-forward") cmd.kind = Kind::DeleteForward;
    else if (word == "clear-cursors") cmd.kind = Kind::ClearCursors;
    else if (word == "undo") cmd.kind = Kind::Undo;
    else if (word == "redo") cmd.kind = Kind::Redo;
    else if (word == "print") cmd.kind = Kind::Print;
    else return std::nullopt;
    return cmd;
}

void execute(Editor& editor, const Command& command, std::ostream& out) {
    using Kind = Command::Kind;
    switch (command.kind) {
        case Kind::Insert: editor.insert(command.text); break;
        case Kind::Delete: editor.deleteBackward(); break;
        case Kind::DeleteForward: editor.deleteForward(); break;
        case Kind::Move: editor.move(command.direction, command.select); break;
        case Kind::Goto: editor.goTo(command.line, command.col); break;
        case Kind::AddCursor: editor.addCursor(command.line, command.col); break;
        case Kind::ClearCursors: editor.clearCursors(); break;
        case Kind::Undo: editor.undo(); break;
        case Kind::Redo: editor.redo(); break;
        case Kind::Print: editor.print(out); break;
    }
}

}  // namespace textbuffer
