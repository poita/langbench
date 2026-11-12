// The MIME part tree.
#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "mime/header.hpp"

namespace mime {

enum class PartKind { Leaf, Multipart, Message };
enum class Role { None, Text, Html, Attachment };

/// One MIME part (the whole message is part 0).
struct Part {
  int index = 0;  ///< pre-order number
  int depth = 0;
  std::vector<HeaderField> headers;

  std::string type;     ///< effective, lower case
  std::string subtype;
  std::string charset;  ///< normalised; meaningful for text/* only
  std::string cte;      ///< encoding token
  std::optional<std::string> disposition;  ///< present iff the header is
  std::optional<std::string> filename;
  PartKind kind = PartKind::Leaf;

  // Multipart containers.
  std::string boundary;
  std::size_t preamble_size = 0;
  std::optional<std::size_t> epilogue_size;

  std::vector<Part> children;

  // Leaves.
  std::string content;  ///< transfer-decoded bytes
  std::uint32_t checksum = 0;
  Role role = Role::None;

  bool is_text() const { return type == "text"; }
  bool is_container() const { return kind != PartKind::Leaf; }
};

/// A parsed message and the result of body selection.
struct Message {
  std::string source_id;
  std::size_t byte_length = 0;  ///< bytes as extracted from the mailbox
  Part root;
  int part_count = 0;
  std::optional<int> text_index;
  std::optional<int> html_index;
  std::vector<int> attachment_indices;  ///< ascending
};

/// Parses a message (any line endings) and selects bodies and attachments.
Message parse_message(std::string_view bytes, std::string source_id);

/// All parts in pre-order (index == position).
std::vector<const Part*> flatten(const Message& m);

/// Decoded text of a text/* leaf: decode(content, charset).
std::string part_text(const Part& p);

}  // namespace mime
