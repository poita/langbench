#include "protowire/encoder.hpp"

#include <cstring>

#include "protowire/scalar.hpp"
#include "protowire/wire.hpp"

namespace protowire {
namespace {

std::size_t tagSize(const FieldDescriptor& f) { return varintSize(static_cast<std::uint64_t>(f.number) << 3); }

std::size_t numberSize(FieldType t, std::uint64_t x) {
  switch (wireTypeOf(t)) {
    case WireType::Fixed32: return 4;
    case WireType::Fixed64: return 8;
    default: return varintSize(toVarint(t, x));
  }
}

void putNumber(std::vector<std::uint8_t>& out, FieldType t, std::uint64_t x) {
  switch (wireTypeOf(t)) {
    case WireType::Fixed32:
      for (int i = 0; i < 4; ++i) out.push_back(static_cast<std::uint8_t>(x >> (8 * i)));
      break;
    case WireType::Fixed64:
      for (int i = 0; i < 8; ++i) out.push_back(static_cast<std::uint8_t>(x >> (8 * i)));
      break;
    default: appendVarint(out, toVarint(t, x));
  }
}

void putTag(std::vector<std::uint8_t>& out, const FieldDescriptor& f, WireType wt) {
  appendVarint(out, (static_cast<std::uint64_t>(f.number) << 3) | static_cast<std::uint64_t>(wt));
}

std::size_t lengthDelimitedSize(std::size_t len) { return varintSize(len) + len; }

/// Sizing pass: records every message's encoded size (and every packed
/// field's payload size) exactly once, bottom-up.
std::size_t computeSize(const Message& msg) {
  std::size_t total = 0;
  const auto& fields = msg.descriptor().fields();
  for (const auto& slot : msg.slots()) {
    const FieldDescriptor& f = fields[slot.index];
    const FieldValue& v = slot.value;
    if (!hasOutput(f, v)) continue;
    const std::size_t tag = tagSize(f);
    if (f.type == FieldType::Message) {
      for (const auto& child : v.messages) {
        const std::size_t s = computeSize(*child);
        total += tag + lengthDelimitedSize(s);
      }
    } else if (f.type == FieldType::String || f.type == FieldType::Bytes) {
      for (const auto& b : v.blobs) total += tag + lengthDelimitedSize(b.size());
    } else if (f.repeated) {
      std::size_t payload = 0;
      for (std::uint64_t x : v.numbers) payload += numberSize(f.type, x);
      v.packedSize = payload;
      total += tag + lengthDelimitedSize(payload);
    } else {
      total += tag + numberSize(f.type, v.numbers[0]);
    }
  }
  msg.encodedSize = total;
  return total;
}

/// Write pass: uses the sizes recorded by computeSize for length prefixes.
void write(const Message& msg, std::vector<std::uint8_t>& out) {
  const auto& fields = msg.descriptor().fields();
  for (const auto& slot : msg.slots()) {
    const FieldDescriptor& f = fields[slot.index];
    const FieldValue& v = slot.value;
    if (!hasOutput(f, v)) continue;
    if (f.type == FieldType::Message) {
      for (const auto& child : v.messages) {
        putTag(out, f, WireType::LengthDelimited);
        appendVarint(out, child->encodedSize);
        write(*child, out);
      }
    } else if (f.type == FieldType::String || f.type == FieldType::Bytes) {
      for (const auto& b : v.blobs) {
        putTag(out, f, WireType::LengthDelimited);
        appendVarint(out, b.size());
        out.insert(out.end(), b.begin(), b.end());
      }
    } else if (f.repeated) {
      putTag(out, f, WireType::LengthDelimited);
      appendVarint(out, v.packedSize);
      for (std::uint64_t x : v.numbers) putNumber(out, f.type, x);
    } else {
      putTag(out, f, wireTypeOf(f.type));
      putNumber(out, f.type, v.numbers[0]);
    }
  }
}

}  // namespace

std::vector<std::uint8_t> encode(const Message& message) {
  std::vector<std::uint8_t> out;
  out.reserve(computeSize(message));
  write(message, out);
  return out;
}

}  // namespace protowire
