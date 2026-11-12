// Splitting an mbox file or reading a directory of .eml files.
#pragma once

#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace mime {

struct RawMessage {
  std::string source_id;  ///< file name, or "mbox:<n>"
  std::string bytes;
};

/// Splits mbox contents into messages.
std::vector<RawMessage> split_mbox(std::string_view data);

/// Reads every regular `*.eml` file directly inside `dir`, ordered by name.
std::vector<RawMessage> read_eml_directory(const std::filesystem::path& dir);

/// Reads `path`: a directory of .eml files or an mbox file.
std::vector<RawMessage> read_mailbox(const std::filesystem::path& path);

}  // namespace mime
