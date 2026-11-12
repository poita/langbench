#include "protowire/value.hpp"

#include <algorithm>

namespace protowire {

FieldValue& Message::touch(std::uint32_t index) {
  if (slots_.empty() || slots_.back().index < index) {
    slots_.push_back(Slot{index, {}});
    return slots_.back().value;
  }
  auto it = std::lower_bound(slots_.begin(), slots_.end(), index,
                             [](const Slot& s, std::uint32_t i) { return s.index < i; });
  if (it == slots_.end() || it->index != index) it = slots_.insert(it, Slot{index, {}});
  return it->value;
}

const FieldValue* Message::find(std::uint32_t index) const {
  auto it = std::lower_bound(slots_.begin(), slots_.end(), index,
                             [](const Slot& s, std::uint32_t i) { return s.index < i; });
  return (it != slots_.end() && it->index == index) ? &it->value : nullptr;
}

bool hasOutput(const FieldDescriptor& field, const FieldValue& value) {
  switch (field.type) {
    case FieldType::String:
    case FieldType::Bytes:
      if (field.repeated) return !value.blobs.empty();
      return !value.blobs.empty() && !value.blobs[0].empty();
    case FieldType::Message:
      return !value.messages.empty();
    default:
      if (field.repeated) return !value.numbers.empty();
      return !value.numbers.empty() && value.numbers[0] != 0;
  }
}

}  // namespace protowire
