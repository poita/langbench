// Rendering of the text dump and writing of the output tree.
#pragma once

#include <filesystem>
#include <string>
#include <vector>

#include "mime/message.hpp"

namespace mime {

/// `NNNN` zero-padded message number.
std::string format_number(int n, int width);

/// Contents of messages/NNNN.txt.
std::string render_message(const Message& m, int number);

/// Contents of summary.txt.
std::string render_summary(const std::vector<Message>& messages);

/// Relative path of an attachment file, e.g. `parts/0001/002.bin`.
std::string attachment_path(int message_number, int part_index);

/// Writes summary.txt, messages/ and parts/ below `out_dir` (created if
/// missing). Throws std::runtime_error on I/O failure.
void write_output(const std::vector<Message>& messages, const std::filesystem::path& out_dir);

/// Convenience: read the mailbox at `input`, parse it, write `out_dir`.
void process_mailbox(const std::filesystem::path& input, const std::filesystem::path& out_dir);

}  // namespace mime
