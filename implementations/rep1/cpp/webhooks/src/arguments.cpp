#include "webhooks/arguments.hpp"

#include "webhooks/hex.hpp"
#include "webhooks/secret.hpp"

namespace webhooks {

namespace {

bool is_printable(char c) { return c >= 0x21 && c <= 0x7e; }

bool is_name_char(char c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
         c == '_' || c == '.' || c == '-';
}

std::vector<std::string_view> split_on(std::string_view s, char sep) {
  std::vector<std::string_view> parts;
  std::size_t start = 0;
  for (;;) {
    std::size_t end = s.find(sep, start);
    if (end == std::string_view::npos) {
      parts.push_back(s.substr(start));
      return parts;
    }
    parts.push_back(s.substr(start, end - start));
    start = end + 1;
  }
}

}  // namespace

std::vector<std::string_view> split_fields(std::string_view line) { return split_on(line, ' '); }

std::optional<Bytes> parse_hex_argument(std::string_view field) {
  if (field == "-") return Bytes{};
  if (field.empty()) return std::nullopt;
  return from_hex(field);
}

std::optional<Bytes> parse_secret_argument(std::string_view field) {
  if (field.empty() || field.size() > 512) return std::nullopt;
  for (char c : field) {
    if (!is_printable(c) || c == ',') return std::nullopt;
  }
  return parse_secret(field);
}

std::optional<std::vector<Bytes>> parse_secrets_argument(std::string_view field) {
  std::vector<std::string_view> parts = split_on(field, ',');
  if (parts.size() > 16) return std::nullopt;
  std::vector<Bytes> keys;
  for (std::string_view part : parts) {
    std::optional<Bytes> key = parse_secret_argument(part);
    if (!key) return std::nullopt;
    keys.push_back(std::move(*key));
  }
  return keys;
}

bool is_valid_id(std::string_view field) {
  if (field.empty() || field.size() > 256) return false;
  for (char c : field) {
    if (!is_printable(c)) return false;
  }
  return true;
}

bool is_valid_timestamp_text(std::string_view field) {
  if (field.empty() || field.size() > 64) return false;
  for (char c : field) {
    if (!is_printable(c)) return false;
  }
  return true;
}

bool is_valid_name(std::string_view field) {
  if (field.empty() || field.size() > 64) return false;
  for (char c : field) {
    if (!is_name_char(c)) return false;
  }
  return true;
}

bool parse_filter_argument(std::string_view field, Endpoint& endpoint) {
  if (field == "*") {
    endpoint.match_all = true;
    endpoint.types.clear();
    return true;
  }
  std::vector<std::string_view> parts = split_on(field, ',');
  if (parts.size() > 16) return false;
  std::vector<std::string> types;
  for (std::string_view part : parts) {
    if (!is_valid_name(part)) return false;
    types.emplace_back(part);
  }
  endpoint.match_all = false;
  endpoint.types = std::move(types);
  return true;
}

std::optional<std::vector<Response>> parse_script_argument(std::string_view field) {
  std::vector<std::string_view> parts = split_on(field, ',');
  if (parts.size() > 64) return std::nullopt;
  std::vector<Response> script;
  for (std::string_view part : parts) {
    if (part == "timeout") {
      script.push_back(Response::timed_out());
    } else if (part.size() == 3 && part[0] >= '1' && part[0] <= '5' && part[1] >= '0' &&
               part[1] <= '9' && part[2] >= '0' && part[2] <= '9') {
      script.push_back(Response::status((part[0] - '0') * 100 + (part[1] - '0') * 10 + (part[2] - '0')));
    } else {
      return std::nullopt;
    }
  }
  return script;
}

}  // namespace webhooks
