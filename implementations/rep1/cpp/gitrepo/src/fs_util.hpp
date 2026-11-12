// Small file-system helpers shared by the library's .cpp files (not public).
#pragma once

#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>

namespace gitrepo::detail {

/// Reads a whole regular file; nullopt if it does not exist or cannot be read.
inline std::optional<std::string> read_file(const std::filesystem::path& path) {
  std::error_code ec;
  if (!std::filesystem::is_regular_file(path, ec)) return std::nullopt;
  std::ifstream in(path, std::ios::binary);
  if (!in) return std::nullopt;
  std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  if (in.bad()) return std::nullopt;
  return data;
}

}  // namespace gitrepo::detail
