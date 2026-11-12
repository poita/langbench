// Adler-32 checksum.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace mime {

std::uint32_t adler32(std::string_view data);

/// Eight lower-case hex digits.
std::string adler32_hex(std::string_view data);

}  // namespace mime
