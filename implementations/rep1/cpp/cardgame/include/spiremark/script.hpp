// Parsing of match files: the setup block and the script lines.
#pragma once

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "spiremark/types.hpp"

namespace spiremark {

/// Raised for any violation of the setup block (SPEC.md 4.1): `FATAL bad-setup`.
struct SetupError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

struct SetupEntry {
    std::string card_id;
    int count = 1;
};

enum class TraceMode { None, Legal, State };

/// Everything the setup block of a match file specifies.
struct MatchSetup {
    std::string cards_path;
    std::uint64_t seed = 0;
    int spire = 25;
    int opening = 5;
    int maxcap = 10;
    int handmax = 7;
    int turnlimit = 200;
    int first = 0;
    bool shuffle = true;
    TraceMode trace = TraceMode::None;
    int cap[2] = {0, 0};
    /// zones[z][player]: 0 DECK, 1 HAND, 2 FIELD, 3 ASH, 4 RIFT.
    std::vector<SetupEntry> zones[5][2];
};

/// Splits input into lines: '\n'-terminated, a '\r' before '\n' is stripped.
/// A final unterminated line is a line too.
std::vector<std::string> split_lines(const std::string& input);

/// Parses setup lines [0, start_line) where lines[start_line] is `START`.
/// Throws SetupError. On success `start_line` is the index of the START line.
MatchSetup parse_setup(const std::vector<std::string>& lines, std::size_t& start_line);

enum class DirectiveType { Dump, Legal, Vault, Card };

/// The result of classifying one script line.
struct ScriptLine {
    enum class Kind { Comment, Action, Directive, BadSyntax };
    Kind kind = Kind::Comment;
    Action action;
    DirectiveType directive = DirectiveType::Dump;
    std::string card_id;  ///< for CARD
};

ScriptLine parse_script_line(const std::string& line);

/// True for blank lines and lines whose first non-space character is '#'.
bool is_comment_line(const std::string& line);

}  // namespace spiremark
