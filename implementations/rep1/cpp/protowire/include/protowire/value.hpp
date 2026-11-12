// The value tree: one Message node per message instance.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "protowire/schema.hpp"

namespace protowire {

class Message;

/// The value(s) of one field. Which member is used depends on the field type:
/// numeric types use `numbers`, string/bytes use `blobs`, messages use
/// `messages`. A singular field holds at most one element.
struct FieldValue {
  std::vector<std::uint64_t> numbers;
  std::vector<std::string> blobs;
  std::vector<std::unique_ptr<Message>> messages;
  /// Encoder scratch: byte length of the packed payload of a repeated numeric field.
  mutable std::size_t packedSize = 0;
};

/// A message instance. Only fields that were actually set have a slot; slots
/// are kept sorted by field index (= field-number order).
class Message {
 public:
  struct Slot {
    std::uint32_t index;
    FieldValue value;
  };

  explicit Message(const MessageDescriptor& descriptor) : descriptor_(&descriptor) {}

  const MessageDescriptor& descriptor() const { return *descriptor_; }
  const std::vector<Slot>& slots() const { return slots_; }

  /// Returns the value of field `index`, creating an empty slot if needed.
  FieldValue& touch(std::uint32_t index);
  /// Returns the value of field `index`, or null if it was never set.
  const FieldValue* find(std::uint32_t index) const;

  /// Encoder scratch: byte length of this message's encoding (set by the sizing pass).
  mutable std::size_t encodedSize = 0;

 private:
  const MessageDescriptor* descriptor_;
  std::vector<Slot> slots_;
};

/// Whether a field is emitted by the encoder and the text formatter: repeated
/// fields when non-empty, singular scalars when not the default, singular
/// messages whenever present.
bool hasOutput(const FieldDescriptor& field, const FieldValue& value);

}  // namespace protowire
