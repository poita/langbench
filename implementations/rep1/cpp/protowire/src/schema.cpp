#include "protowire/schema.hpp"

#include <algorithm>
#include <cstddef>

#include "protowire/error.hpp"

namespace protowire {

WireType wireTypeOf(FieldType t) {
  switch (t) {
    case FieldType::Fixed32:
    case FieldType::SFixed32: return WireType::Fixed32;
    case FieldType::Fixed64:
    case FieldType::SFixed64: return WireType::Fixed64;
    case FieldType::String:
    case FieldType::Bytes:
    case FieldType::Message: return WireType::LengthDelimited;
    default: return WireType::Varint;
  }
}

bool isNumeric(FieldType t) {
  return t != FieldType::String && t != FieldType::Bytes && t != FieldType::Message;
}

const FieldDescriptor* MessageDescriptor::findByNumber(std::uint32_t number) const {
  auto it = std::lower_bound(fields_.begin(), fields_.end(), number,
                             [](const FieldDescriptor& f, std::uint32_t n) { return f.number < n; });
  return (it != fields_.end() && it->number == number) ? &*it : nullptr;
}

const FieldDescriptor* MessageDescriptor::findByName(std::string_view name) const {
  auto it = byName_.find(std::string(name));
  return it == byName_.end() ? nullptr : &fields_[it->second];
}

const MessageDescriptor* Schema::findMessage(std::string_view name) const {
  auto it = byName_.find(std::string(name));
  return it == byName_.end() ? nullptr : it->second;
}

namespace {

bool isWordChar(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

std::vector<std::string_view> tokenize(std::string_view text) {
  std::vector<std::string_view> tokens;
  std::size_t i = 0;
  while (i < text.size()) {
    const char c = text[i];
    if (c == '{' || c == '}' || c == ';' || c == '=') {
      tokens.push_back(text.substr(i++, 1));
    } else if (isWordChar(c)) {
      std::size_t j = i;
      while (j < text.size() && isWordChar(text[j])) ++j;
      tokens.push_back(text.substr(i, j - i));
      i = j;
    } else if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      ++i;
    } else {
      throw SchemaError("unexpected character in schema");
    }
  }
  return tokens;
}

bool scalarType(std::string_view name, FieldType& out) {
  static const std::pair<std::string_view, FieldType> kTypes[] = {
      {"int32", FieldType::Int32},     {"int64", FieldType::Int64},
      {"uint32", FieldType::UInt32},   {"uint64", FieldType::UInt64},
      {"sint32", FieldType::SInt32},   {"sint64", FieldType::SInt64},
      {"bool", FieldType::Bool},       {"fixed32", FieldType::Fixed32},
      {"fixed64", FieldType::Fixed64}, {"sfixed32", FieldType::SFixed32},
      {"sfixed64", FieldType::SFixed64}, {"string", FieldType::String},
      {"bytes", FieldType::Bytes},
  };
  for (const auto& [n, t] : kTypes)
    if (n == name) { out = t; return true; }
  return false;
}

std::uint32_t parseNumber(std::string_view tok) {
  if (tok.empty()) throw SchemaError("missing field number");
  std::uint64_t v = 0;
  for (char c : tok) {
    if (c < '0' || c > '9') throw SchemaError("invalid field number");
    v = v * 10 + static_cast<std::uint64_t>(c - '0');
    if (v > 0x1fffffff) throw SchemaError("field number out of range");
  }
  if (v == 0) throw SchemaError("field number out of range");
  return static_cast<std::uint32_t>(v);
}

}  // namespace

Schema Schema::parse(std::string_view text) {
  const auto tokens = tokenize(text);
  std::size_t pos = 0;
  auto expect = [&](std::string_view t) {
    if (pos >= tokens.size() || tokens[pos] != t)
      throw SchemaError("expected '" + std::string(t) + "' in schema");
    ++pos;
  };
  auto word = [&]() {
    if (pos >= tokens.size() || !isWordChar(tokens[pos][0])) throw SchemaError("expected identifier in schema");
    return tokens[pos++];
  };

  Schema schema;
  // Type names are resolved in a second pass so messages may refer forward.
  std::vector<std::vector<std::string_view>> pendingTypes;
  while (pos < tokens.size()) {
    expect("message");
    auto desc = std::make_unique<MessageDescriptor>();
    desc->name_ = std::string(word());
    if (!schema.byName_.emplace(desc->name_, desc.get()).second)
      throw SchemaError("duplicate message " + desc->name_);
    expect("{");
    std::vector<std::string_view> typeNames;
    while (pos < tokens.size() && tokens[pos] != "}") {
      FieldDescriptor f;
      std::string_view t = word();
      if (t == "repeated") {
        f.repeated = true;
        t = word();
      }
      typeNames.push_back(t);
      f.name = std::string(word());
      expect("=");
      f.number = parseNumber(word());
      expect(";");
      desc->fields_.push_back(std::move(f));
    }
    expect("}");
    // Sort by field number, keeping type names aligned with fields.
    std::vector<std::size_t> order(desc->fields_.size());
    for (std::size_t i = 0; i < order.size(); ++i) order[i] = i;
    std::sort(order.begin(), order.end(), [&](std::size_t a, std::size_t b) {
      return desc->fields_[a].number < desc->fields_[b].number;
    });
    std::vector<FieldDescriptor> sorted;
    std::vector<std::string_view> sortedTypes;
    for (std::size_t i : order) {
      sorted.push_back(std::move(desc->fields_[i]));
      sortedTypes.push_back(typeNames[i]);
    }
    desc->fields_ = std::move(sorted);
    for (std::size_t i = 0; i < desc->fields_.size(); ++i) {
      desc->fields_[i].index = static_cast<std::uint32_t>(i);
      if (i > 0 && desc->fields_[i].number == desc->fields_[i - 1].number)
        throw SchemaError("duplicate field number");
      if (!desc->byName_.emplace(desc->fields_[i].name, static_cast<std::uint32_t>(i)).second)
        throw SchemaError("duplicate field name " + desc->fields_[i].name);
    }
    pendingTypes.push_back(std::move(sortedTypes));
    schema.messages_.push_back(std::move(desc));
  }

  for (std::size_t m = 0; m < schema.messages_.size(); ++m) {
    auto& fields = schema.messages_[m]->fields_;
    for (std::size_t i = 0; i < fields.size(); ++i) {
      FieldType t;
      if (scalarType(pendingTypes[m][i], t)) {
        fields[i].type = t;
      } else {
        const MessageDescriptor* target = schema.findMessage(pendingTypes[m][i]);
        if (!target) throw SchemaError("unknown type " + std::string(pendingTypes[m][i]));
        fields[i].type = FieldType::Message;
        fields[i].message = target;
      }
    }
  }
  return schema;
}

}  // namespace protowire
