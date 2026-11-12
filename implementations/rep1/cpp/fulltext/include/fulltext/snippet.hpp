/// @file snippet.hpp
/// Best-window search and snippet rendering.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "fulltext/analyzer.hpp"

namespace fulltext {

/// Window width in tokens.
inline constexpr std::size_t kSnippetWindow = 30;

/// Occurrences of one positive atom in one document.
struct AtomOccurrences {
  std::size_t length;                        ///< Number of terms in the atom.
  std::span<const std::uint32_t> starts;     ///< Ascending start positions.
};

/// Finds the best window start `s` for a document of `doc_len` tokens:
/// most distinct atoms inside, then most occurrences inside, then smallest
/// `s`. Runs in O(doc_len + total occurrences) using difference arrays.
std::size_t best_window_start(std::size_t doc_len, std::span<const AtomOccurrences> atoms,
                              std::size_t window = kSnippetWindow);

/// Renders the snippet for the window starting at token `start`: the original
/// text from the first token of the window to the last, with every run of
/// whitespace collapsed to one space. `tokens` are the byte spans of all the
/// document's tokens (see `tokenize`). Empty for a document without tokens.
std::string render_snippet(std::string_view text, std::span<const Span> tokens,
                           std::size_t start, std::size_t window = kSnippetWindow);

}  // namespace fulltext
