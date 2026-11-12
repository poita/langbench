#include "protowire/decoder.hpp"

#include <cstring>

#include "protowire/error.hpp"
#include "protowire/scalar.hpp"
#include "protowire/utf8.hpp"
#include "protowire/wire.hpp"

namespace protowire {
namespace {

constexpr std::size_t kMaxVarintBytes = 10;
constexpr std::size_t kMaxTagBytes = 5;
constexpr std::size_t kMaxLengthBytes = 5;

[[noreturn]] void fail(const char* what) { throw WireError(what); }

struct Tag {
  std::uint32_t number;
  std::uint32_t wireType;
};

/// Reads and validates a tag. End-group tags (wire type 4) are returned to the
/// caller, which decides whether one is legal at this point.
Tag readTag(Reader& r) {
  std::uint64_t v;
  if (!r.readVarint(kMaxTagBytes, v)) fail("bad tag");
  if (v >> 32) fail("tag out of range");
  const std::uint32_t number = static_cast<std::uint32_t>(v >> 3);
  const std::uint32_t wt = static_cast<std::uint32_t>(v & 7);
  if (number == 0) fail("field number 0");
  if (wt == 6 || wt == 7) fail("invalid wire type");
  return {number, wt};
}

/// Reads a length prefix and splits off that many bytes.
Reader readLengthDelimited(Reader& r) {
  std::uint64_t len;
  if (!r.readVarint(kMaxLengthBytes, len)) fail("bad length prefix");
  Reader sub(nullptr, nullptr);
  if (len > r.remaining() || !r.take(static_cast<std::size_t>(len), sub)) fail("length exceeds data");
  return sub;
}

/// Skips the group whose start tag (field `number`) was just read. Iterative:
/// no recursion regardless of group nesting.
void skipGroup(Reader& r, std::uint32_t number);

void skipValue(Reader& r, const Tag& tag) {
  switch (tag.wireType) {
    case 0: {
      std::uint64_t v;
      if (!r.readVarint(kMaxVarintBytes, v)) fail("bad varint");
      break;
    }
    case 1: {
      std::uint64_t v;
      if (!r.readFixed64(v)) fail("truncated fixed64");
      break;
    }
    case 2: readLengthDelimited(r); break;
    case 3: skipGroup(r, tag.number); break;
    case 5: {
      std::uint32_t v;
      if (!r.readFixed32(v)) fail("truncated fixed32");
      break;
    }
    default: fail("unexpected end-group tag");
  }
}

void skipGroup(Reader& r, std::uint32_t number) {
  std::vector<std::uint32_t> open{number};
  while (!open.empty()) {
    if (r.empty()) fail("unterminated group");
    const Tag tag = readTag(r);
    if (tag.wireType == 4) {
      if (tag.number != open.back()) fail("mismatched end-group");
      open.pop_back();
    } else if (tag.wireType == 3) {
      open.push_back(tag.number);
    } else {
      skipValue(r, tag);
    }
  }
}

void decodeInto(Message& msg, Reader r, int depth);

void storeNumber(FieldValue& fv, bool repeated, std::uint64_t x) {
  if (repeated) {
    fv.numbers.push_back(x);
  } else if (fv.numbers.empty()) {
    fv.numbers.push_back(x);
  } else {
    fv.numbers[0] = x;
  }
}

std::uint64_t readScalar(FieldType type, Reader& r) {
  switch (wireTypeOf(type)) {
    case WireType::Varint: {
      std::uint64_t v;
      if (!r.readVarint(kMaxVarintBytes, v)) fail("bad varint");
      return fromVarint(type, v);
    }
    case WireType::Fixed32: {
      std::uint32_t v;
      if (!r.readFixed32(v)) fail("truncated fixed32");
      return fromFixed32(type, v);
    }
    default: {
      std::uint64_t v;
      if (!r.readFixed64(v)) fail("truncated fixed64");
      return v;  // fixed64 / sfixed64: raw bits are the stored form
    }
  }
}

void decodeField(Message& msg, const FieldDescriptor& f, const Tag& tag, Reader& r, int depth) {
  const FieldType type = f.type;
  if (tag.wireType == static_cast<std::uint32_t>(wireTypeOf(type))) {
    if (isNumeric(type)) {
      storeNumber(msg.touch(f.index), f.repeated, readScalar(type, r));
    } else if (type == FieldType::Message) {
      Reader sub = readLengthDelimited(r);
      FieldValue& fv = msg.touch(f.index);
      if (f.repeated || fv.messages.empty())
        fv.messages.push_back(std::make_unique<Message>(*f.message));
      decodeInto(*fv.messages.back(), sub, depth + 1);
    } else {
      Reader sub = readLengthDelimited(r);
      std::string_view payload(reinterpret_cast<const char*>(sub.data()), sub.remaining());
      if (type == FieldType::String && !isValidUtf8(payload)) fail("invalid UTF-8");
      FieldValue& fv = msg.touch(f.index);
      if (f.repeated || fv.blobs.empty()) fv.blobs.emplace_back(payload);
      else fv.blobs[0].assign(payload);
    }
  } else if (tag.wireType == 2 && f.repeated && isNumeric(type)) {
    Reader payload = readLengthDelimited(r);
    FieldValue& fv = msg.touch(f.index);
    const WireType wt = wireTypeOf(type);
    if (wt == WireType::Fixed32 || wt == WireType::Fixed64) {
      const std::size_t size = wt == WireType::Fixed32 ? 4 : 8;
      if (payload.remaining() % size != 0) fail("packed fixed payload not a multiple of element size");
      fv.numbers.reserve(fv.numbers.size() + payload.remaining() / size);
    }
    while (!payload.empty()) fv.numbers.push_back(readScalar(type, payload));
  } else {
    skipValue(r, tag);
  }
}

void decodeInto(Message& msg, Reader r, int depth) {
  if (depth > kMaxNestingDepth) fail("nesting too deep");
  const MessageDescriptor& desc = msg.descriptor();
  while (!r.empty()) {
    const Tag tag = readTag(r);
    if (tag.wireType == 4) fail("end-group outside group");
    const FieldDescriptor* f = desc.findByNumber(tag.number);
    if (f) decodeField(msg, *f, tag, r, depth);
    else skipValue(r, tag);
  }
}

}  // namespace

Message decode(const MessageDescriptor& descriptor, std::span<const std::uint8_t> bytes) {
  Message msg(descriptor);
  decodeInto(msg, Reader(bytes.data(), bytes.data() + bytes.size()), 0);
  return msg;
}

}  // namespace protowire
