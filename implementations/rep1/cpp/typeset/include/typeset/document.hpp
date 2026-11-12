// The Codexa document model and its parser.
#pragma once

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "typeset/error.hpp"
#include "typeset/settings.hpp"

namespace typeset {

/// A node of an inline style tree. Node 0 is the root ("the context's own
/// style"); every other node applies one tag to its parent.
struct StyleNode {
    int parent = 0;
    char op = 0;  ///< 'b', 'i', 'm', '+' or '-'
};

/// One element of the resolved inline stream of a block's text.
struct Unit {
    enum Kind : unsigned char {
        Char,        ///< an ordinary character
        Glue,        ///< a run of spaces (inter-word glue)
        RigidSpace,  ///< `~` or `\ ` : a fixed-width space of the face in force
        RigidFixed,  ///< a fixed gap of `width` millipoints (list builders only)
        Disc,        ///< `\-`, an explicit hyphenation point
        Mark         ///< a footnote reference mark
    };
    Kind kind = Char;
    bool plainGlue = false;  ///< Glue that never takes the sentence-end extra space
    char32_t c = 0;
    int style = 0;      ///< index into InlineText::styles
    int footnote = 0;   ///< Mark: footnote number (1-based)
    i64 width = 0;      ///< RigidFixed
};

/// The inline content of a block: its units and the style tree they refer to.
struct InlineText {
    std::vector<Unit> units;
    std::vector<StyleNode> styles{StyleNode{}};
};

enum class BlockKind {
    Paragraph, Heading, Quote, Group, UList, OList, Item, Table, Pre, Figure, Rule, VSpace, NewPage
};

struct TableElement {
    bool hrule = false;
    std::vector<InlineText> cells;
};

/// A block of the document tree.
struct Block {
    BlockKind kind = BlockKind::Paragraph;

    // Heading
    int level = 0;
    bool numbered = true;  ///< false for `@hN*`
    std::string plain;     ///< heading's plain text

    InlineText text;  ///< paragraph, heading, item text, figure caption
    std::vector<std::unique_ptr<Block>> children;

    // @block
    std::optional<Align> align;
    std::optional<Family> font;
    std::optional<i64> indent, rightIndent, size, leading;

    // @ol
    i64 start = 1;

    // @table
    int cols = 0;
    std::string colAlign;
    std::vector<TableElement> elements;

    // @pre
    std::vector<std::string> lines;

    // @fig, @vspace
    i64 height = 0;
    std::optional<i64> width;
};

/// A parsed Codexa document.
struct Document {
    bool hasDoc = false;
    std::string title, author, date;
    bool hasToc = false;
    std::optional<std::string> tocTitle;  ///< `@toc title=...` override
    std::vector<std::unique_ptr<Block>> blocks;
    std::vector<InlineText> footnotes;  ///< footnote n is footnotes[n-1]

    /// Parse the contents of `document.cdx`. Throws `Error` (file
    /// "document.cdx") at the first problem.
    static Document parse(std::string_view source);
};

/// Plain text of a heading's inline content (styles removed, escapes resolved).
std::string plainText(const InlineText& text);

/// Build units for literal text: characters, with each run of spaces a glue
/// (leading and trailing glue dropped).
std::vector<Unit> plainUnits(std::string_view utf8, bool dropEdgeGlue = true);

}  // namespace typeset
