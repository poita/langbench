#include "protowire/batch.hpp"

#include <cstdint>
#include <exception>
#include <vector>

#include "protowire/codec.hpp"
#include "protowire/error.hpp"

namespace protowire {

namespace {

constexpr std::string_view kError = "error";

std::string handle(const Schema& schema, std::string_view line) {
  const std::size_t sp1 = line.find(' ');
  if (sp1 == std::string_view::npos) return std::string(kError);
  const std::string_view cmd = line.substr(0, sp1);
  const std::string_view rest = line.substr(sp1 + 1);
  const std::size_t sp2 = rest.find(' ');
  const std::string_view name = rest.substr(0, sp2);
  const MessageDescriptor* desc = schema.findMessage(name);
  if (!desc) return std::string(kError);

  if (cmd == "decode") {
    std::vector<std::uint8_t> bytes;
    if (sp2 != std::string_view::npos) {
      const std::string_view hex = rest.substr(sp2 + 1);
      if (hex.empty()) return std::string(kError);  // trailing space
      bytes = fromHex(hex);
    }
    return decodeToText(*desc, bytes);
  }
  if (cmd == "encode") {
    if (sp2 == std::string_view::npos) return std::string(kError);
    return toHex(encodeFromText(*desc, rest.substr(sp2 + 1)));
  }
  return std::string(kError);
}

}  // namespace

std::string handleRequest(const Schema& schema, std::string_view line) {
  try {
    return handle(schema, line);
  } catch (const std::exception&) {
    return std::string(kError);
  }
}

std::string processInput(std::string_view input) {
  // The schema is everything before the first line that is exactly "--".
  std::size_t pos = 0;
  std::size_t schemaEnd = std::string_view::npos;
  while (pos <= input.size()) {
    std::size_t nl = input.find('\n', pos);
    const std::size_t end = nl == std::string_view::npos ? input.size() : nl;
    if (input.substr(pos, end - pos) == "--") { schemaEnd = pos; pos = end + 1; break; }
    if (nl == std::string_view::npos) break;
    pos = nl + 1;
  }
  if (schemaEnd == std::string_view::npos) return {};

  std::string out;
  Schema schema;
  bool schemaOk = true;
  try {
    schema = Schema::parse(input.substr(0, schemaEnd));
  } catch (const std::exception&) {
    schemaOk = false;
  }

  while (pos < input.size()) {
    const std::size_t nl = input.find('\n', pos);
    const std::size_t end = nl == std::string_view::npos ? input.size() : nl;
    const std::string_view line = input.substr(pos, end - pos);
    out += schemaOk ? handleRequest(schema, line) : std::string(kError);
    out += '\n';
    pos = end + 1;
  }
  return out;
}

}  // namespace protowire
