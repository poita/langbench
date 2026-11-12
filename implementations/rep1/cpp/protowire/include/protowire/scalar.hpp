// Conversions between wire representations and the library's stored form.
//
// Every numeric field value is stored in a std::uint64_t holding the
// *semantic* value: signed types are sign-extended to 64 bits, unsigned types
// zero-extended, bool is 0 or 1.
#pragma once

#include <cstdint>

#include "protowire/schema.hpp"
#include "protowire/wire.hpp"

namespace protowire {

/// True for the types printed as signed decimal integers.
inline bool isSignedType(FieldType t) {
  return t == FieldType::Int32 || t == FieldType::Int64 || t == FieldType::SInt32 ||
         t == FieldType::SInt64 || t == FieldType::SFixed32 || t == FieldType::SFixed64;
}

/// Stored value of a varint-encoded field read from the wire.
inline std::uint64_t fromVarint(FieldType t, std::uint64_t v) {
  switch (t) {
    case FieldType::Int32:
      return static_cast<std::uint64_t>(static_cast<std::int64_t>(static_cast<std::int32_t>(static_cast<std::uint32_t>(v))));
    case FieldType::UInt32: return v & 0xffffffffull;
    case FieldType::SInt32:
      return static_cast<std::uint64_t>(static_cast<std::int64_t>(unzigzag32(static_cast<std::uint32_t>(v))));
    case FieldType::SInt64: return static_cast<std::uint64_t>(unzigzag64(v));
    case FieldType::Bool: return v != 0 ? 1 : 0;
    default: return v;  // Int64, UInt64
  }
}

/// Varint wire value of a stored varint-typed value.
inline std::uint64_t toVarint(FieldType t, std::uint64_t x) {
  switch (t) {
    case FieldType::SInt32: return zigzag32(static_cast<std::int32_t>(static_cast<std::uint32_t>(x)));
    case FieldType::SInt64: return zigzag64(static_cast<std::int64_t>(x));
    case FieldType::Bool: return x != 0 ? 1 : 0;
    default: return x;  // Int32 (sign-extended), Int64, UInt32, UInt64
  }
}

/// Stored value of a fixed32-encoded field.
inline std::uint64_t fromFixed32(FieldType t, std::uint32_t v) {
  if (t == FieldType::SFixed32)
    return static_cast<std::uint64_t>(static_cast<std::int64_t>(static_cast<std::int32_t>(v)));
  return v;
}

}  // namespace protowire
