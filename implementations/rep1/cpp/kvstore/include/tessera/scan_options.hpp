#pragma once
/// \file scan_options.hpp
#include <cstdint>
#include <optional>
#include <string>

namespace tessera {

/// Options of the `scan` command (spec 6.5).
struct ScanOptions {
  std::optional<std::string> from;  ///< inclusive lower bound
  std::optional<std::string> to;    ///< exclusive upper bound
  std::optional<std::int64_t> limit;
  bool reverse = false;
  bool keys_only = false;
};

}  // namespace tessera
