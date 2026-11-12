#include "textbuffer/document.hpp"

#include <algorithm>
#include <cassert>
#include <utility>

namespace textbuffer {

Document::Document() : lines_(1) {}

Document::Document(std::vector<std::string> lines) : lines_(std::move(lines)) {
    if (lines_.empty()) lines_.emplace_back();
}

Document Document::fromText(std::string_view text) {
    std::vector<std::string> lines;
    std::size_t from = 0;
    for (;;) {
        const auto nl = text.find('\n', from);
        if (nl == std::string_view::npos) {
            lines.emplace_back(text.substr(from));
            break;
        }
        lines.emplace_back(text.substr(from, nl - from));
        from = nl + 1;
    }
    return Document(std::move(lines));
}

std::string Document::text() const {
    std::string out;
    for (std::size_t i = 0; i < lines_.size(); ++i) {
        if (i) out += '\n';
        out += lines_[i];
    }
    return out;
}

Position Document::endPosition() const noexcept {
    return {static_cast<std::uint32_t>(lines_.size() - 1),
            static_cast<std::uint32_t>(lines_.back().size())};
}

Position Document::clamp(std::uint64_t line, std::uint64_t col) const noexcept {
    const std::uint64_t l = std::min<std::uint64_t>(line, lines_.size() - 1);
    const std::uint64_t c = std::min<std::uint64_t>(col, lines_[l].size());
    return {static_cast<std::uint32_t>(l), static_cast<std::uint32_t>(c)};
}

std::string Document::textBetween(Position a, Position b) const {
    assert(a <= b && b.line < lines_.size());
    if (a.line == b.line) return lines_[a.line].substr(a.col, b.col - a.col);
    std::string out = lines_[a.line].substr(a.col);
    for (std::uint32_t i = a.line + 1; i < b.line; ++i) {
        out += '\n';
        out += lines_[i];
    }
    out += '\n';
    out.append(lines_[b.line], 0, b.col);
    return out;
}

void Document::replace(Position start, Position end, std::string_view text) {
    assert(start <= end && end.line < lines_.size());
    assert(end.col <= lines_[end.line].size());

    const bool multiLineText = text.find('\n') != std::string_view::npos;
    if (start.line == end.line && !multiLineText) {
        lines_[start.line].replace(start.col, end.col - start.col, text);
        return;
    }

    // Split `text` into the parts that land on consecutive lines.
    std::string tail = lines_[end.line].substr(end.col);
    std::string_view rest = text;
    std::string_view first = rest.substr(0, rest.find('\n'));
    rest = first.size() < rest.size() ? rest.substr(first.size() + 1) : std::string_view{};
    std::vector<std::string_view> more;
    if (multiLineText) {
        for (;;) {
            const auto nl = rest.find('\n');
            more.push_back(rest.substr(0, nl));
            if (nl == std::string_view::npos) break;
            rest.remove_prefix(nl + 1);
        }
    }

    const std::size_t removedLines = end.line - start.line;
    const std::size_t addedLines = more.size();
    auto at = lines_.begin() + start.line + 1;
    if (addedLines > removedLines) {
        lines_.insert(at, addedLines - removedLines, std::string());
    } else if (addedLines < removedLines) {
        lines_.erase(at, at + (removedLines - addedLines));
    }

    std::string& head = lines_[start.line];
    head.resize(start.col);
    head.append(first);
    for (std::size_t i = 0; i < addedLines; ++i) {
        lines_[start.line + 1 + i].assign(more[i]);
    }
    lines_[start.line + addedLines].append(tail);
}

}  // namespace textbuffer
