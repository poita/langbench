// Schema model: message descriptors with resolved field types.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace protowire {

/// Maximum nesting depth of messages the codec will accept (the specification
/// promises at most 64; the extra headroom only protects the stack).
inline constexpr int kMaxNestingDepth = 1000;

/// The declared type of a field.
enum class FieldType {
  Int32, Int64, UInt32, UInt64, SInt32, SInt64, Bool,
  Fixed32, Fixed64, SFixed32, SFixed64,
  String, Bytes, Message,
};

/// Protocol Buffers wire types.
enum class WireType : std::uint8_t {
  Varint = 0, Fixed64 = 1, LengthDelimited = 2,
  StartGroup = 3, EndGroup = 4, Fixed32 = 5,
};

/// The wire type a (non-packed) value of `type` is encoded with.
WireType wireTypeOf(FieldType type);

/// True for every type that may be packed (all but string, bytes, message).
bool isNumeric(FieldType type);

class MessageDescriptor;

/// One field of a message.
struct FieldDescriptor {
  std::string name;
  std::uint32_t number = 0;
  FieldType type = FieldType::Int32;
  bool repeated = false;
  /// Position of this field within MessageDescriptor::fields() (field-number order).
  std::uint32_t index = 0;
  /// The message type, when `type == FieldType::Message`; otherwise null.
  const MessageDescriptor* message = nullptr;
};

/// A message type: its fields, sorted by field number.
class MessageDescriptor {
 public:
  const std::string& name() const { return name_; }
  const std::vector<FieldDescriptor>& fields() const { return fields_; }

  /// O(log F) lookup by field number; null when absent.
  const FieldDescriptor* findByNumber(std::uint32_t number) const;
  /// O(1) expected lookup by field name; null when absent.
  const FieldDescriptor* findByName(std::string_view name) const;

 private:
  friend class Schema;
  std::string name_;
  std::vector<FieldDescriptor> fields_;
  std::unordered_map<std::string, std::uint32_t> byName_;
};

/// A set of message definitions. Descriptor addresses are stable for the
/// lifetime of the Schema, so descriptors may be held by pointer.
class Schema {
 public:
  /// Parses schema text (see SPEC.md). Throws SchemaError on malformed input.
  static Schema parse(std::string_view text);

  /// Looks up a message by name; null when absent.
  const MessageDescriptor* findMessage(std::string_view name) const;

  const std::vector<std::unique_ptr<MessageDescriptor>>& messages() const { return messages_; }

 private:
  std::vector<std::unique_ptr<MessageDescriptor>> messages_;
  std::unordered_map<std::string, const MessageDescriptor*> byName_;
};

}  // namespace protowire
