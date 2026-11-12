// Value tree -> canonical wire bytes.
#pragma once

#include <cstdint>
#include <vector>

#include "protowire/value.hpp"

namespace protowire {

/// Encodes `message` canonically: fields in field-number order, defaults
/// omitted, repeated numerics packed, minimal varints. A sizing pass computes
/// every node's size once, then a single write pass emits the bytes, so the
/// cost is linear in the output size regardless of nesting depth.
std::vector<std::uint8_t> encode(const Message& message);

}  // namespace protowire
