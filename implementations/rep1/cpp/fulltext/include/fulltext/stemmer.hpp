/// @file stemmer.hpp
/// The Porter stemming algorithm (1980), as in Martin Porter's reference
/// implementation `porter.c` (including its `BLI->BLE` and `LOGI->LOG`
/// departures from the published paper).
#pragma once

#include <string>
#include <string_view>

namespace fulltext {

/// Returns the Porter stem of `word`, which must consist of ASCII lower-case
/// letters only. Words of one or two letters are returned unchanged.
std::string porter_stem(std::string_view word);

}  // namespace fulltext
