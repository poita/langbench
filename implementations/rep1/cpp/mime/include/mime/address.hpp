// Address-list parsing for From/To/Cc/...
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace mime {

struct Address {
  std::string display;  ///< decoded display name, possibly empty
  std::string spec;     ///< addr-spec, or the glued tokens of a malformed one
};

/// Parses an unfolded raw header value into addresses, in order.
std::vector<Address> parse_address_list(std::string_view value);

}  // namespace mime
