/// @file arguments.hpp
/// Validation of the argument kinds of the command language (SPEC.md §3.1, §4.1).
#pragma once

#include <optional>
#include <string_view>
#include <vector>

#include "webhooks/bytes.hpp"
#include "webhooks/simulator.hpp"

namespace webhooks {

/// Splits @p line on single spaces; adjacent, leading or trailing spaces yield
/// empty fields.
std::vector<std::string_view> split_fields(std::string_view line);

/// `<hex>` / `<text-hex>`: `-` is the empty string, otherwise an even run of
/// lowercase hex digits.
std::optional<Bytes> parse_hex_argument(std::string_view field);

/// `<secret>`: 1..512 characters in 0x21..0x7e excluding `,`, and a valid
/// secret per parse_secret(). Yields the raw key.
std::optional<Bytes> parse_secret_argument(std::string_view field);

/// `<secrets>`: 1..16 comma-separated `<secret>`s. Yields the raw keys in order.
std::optional<std::vector<Bytes>> parse_secrets_argument(std::string_view field);

/// `<id>`: 1..256 characters in 0x21..0x7e.
bool is_valid_id(std::string_view field);

/// A verify-command timestamp field: 1..64 characters in 0x21..0x7e.
bool is_valid_timestamp_text(std::string_view field);

/// `<ep-id>`, `<ev-id>`, `<type>`: 1..64 characters from `[A-Za-z0-9_.-]`.
bool is_valid_name(std::string_view field);

/// `<filter>`: `*` or 1..16 comma-separated types. Fills @p endpoint's
/// `match_all` and `types`.
bool parse_filter_argument(std::string_view field, Endpoint& endpoint);

/// `<script>`: 1..64 comma-separated responses, each `100`..`599` or `timeout`.
std::optional<std::vector<Response>> parse_script_argument(std::string_view field);

}  // namespace webhooks
