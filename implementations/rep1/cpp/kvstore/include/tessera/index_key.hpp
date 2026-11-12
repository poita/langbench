#pragma once
/// \file index_key.hpp
/// Secondary index key encoding (spec section 14.1).

#include <optional>
#include <string>
#include <string_view>

#include "tessera/value.hpp"

namespace tessera {

/// Order-preserving, self-delimiting encoding of a scalar value. Lists and
/// objects have none.
std::optional<std::string> value_key(const Value& v);

/// The index entry key for a document: `value_key(value at path) + doc_key`,
/// or nullopt if the path is missing or resolves to a list or an object.
std::optional<std::string> index_entry_key(const Value& doc, const Path& path,
                                           std::string_view doc_key);

/// Length of the `value_key` prefix of an index entry key.
std::size_t value_key_length(std::string_view entry_key);

}  // namespace tessera
