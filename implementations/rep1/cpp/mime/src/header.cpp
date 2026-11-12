#include "mime/header.hpp"

#include "mime/charset.hpp"
#include "mime/rfc2047.hpp"
#include "mime/text.hpp"

namespace mime {
namespace {

// A field line has a ':' and a non-empty name of printable, non-blank,
// non-colon ASCII before it. Returns the colon position or npos.
std::size_t field_colon(std::string_view line) {
  std::size_t colon = line.find(':');
  if (colon == std::string_view::npos || colon == 0) return std::string_view::npos;
  for (std::size_t i = 0; i < colon; ++i) {
    unsigned char c = static_cast<unsigned char>(line[i]);
    if (c < 0x21 || c > 0x7E) return std::string_view::npos;
  }
  return colon;
}

bool collapsed_field(const std::string& key) {
  static const char* const names[] = {
      "content-disposition", "content-id",  "content-transfer-encoding",
      "content-type",        "date",        "in-reply-to",
      "message-id",          "mime-version", "received",
      "references",          "return-path"};
  for (const char* n : names)
    if (key == n) return true;
  return false;
}

}  // namespace

std::string HeaderField::key() const { return ascii_lower(strip_blanks(name)); }

HeaderBlock parse_headers(std::string_view message) {
  HeaderBlock block;
  struct Pending {
    std::string name;
    std::string value;  // raw bytes, unfolded
  };
  std::vector<Pending> pending;

  std::size_t pos = 0;
  const std::size_t n = message.size();
  block.body_offset = n;
  while (pos < n) {
    std::size_t nl = message.find('\n', pos);
    std::size_t end = nl == std::string_view::npos ? n : nl;
    std::size_t next = nl == std::string_view::npos ? n : nl + 1;
    std::string_view line = message.substr(pos, end - pos);
    if (line.empty()) {
      block.body_offset = next;
      break;
    }
    if (!pending.empty() && is_blank(line[0])) {
      pending.back().value.append(line);
    } else {
      std::size_t colon = field_colon(line);
      if (colon == std::string_view::npos) {
        block.body_offset = pos;
        break;
      }
      pending.push_back({std::string(line.substr(0, colon)), std::string(line.substr(colon + 1))});
    }
    pos = next;
  }

  block.fields.reserve(pending.size());
  for (Pending& p : pending)
    block.fields.push_back({decode_utf8(p.name), decode_utf8(p.value)});
  return block;
}

const HeaderField* find_field(const std::vector<HeaderField>& fields, std::string_view key) {
  for (const HeaderField& f : fields)
    if (f.key() == key) return &f;
  return nullptr;
}

std::string display_value(const HeaderField& field) {
  if (collapsed_field(field.key())) return collapse(field.raw_value);
  return decode_unstructured(field.raw_value);
}

}  // namespace mime
