#include "gitrepo/object_store.hpp"

#include <algorithm>
#include <set>

#include "fs_util.hpp"
#include "gitrepo/error.hpp"
#include "gitrepo/inflate.hpp"
#include "gitrepo/sha1.hpp"

namespace gitrepo {

namespace fs = std::filesystem;

namespace {

constexpr int kMaxDeltaDepth = 1000;  // guards against cyclic deltas

std::optional<ObjectType> type_from_name(std::string_view name) {
  if (name == "commit") return ObjectType::Commit;
  if (name == "tree") return ObjectType::Tree;
  if (name == "blob") return ObjectType::Blob;
  if (name == "tag") return ObjectType::Tag;
  return std::nullopt;
}

bool is_hex_name(std::string_view s, std::size_t length) {
  return s.size() == length && std::all_of(s.begin(), s.end(), is_lower_hex);
}

std::uint32_t be32(std::string_view s, std::size_t pos) {
  auto b = [&](std::size_t i) { return std::uint32_t(static_cast<std::uint8_t>(s[pos + i])); };
  return (b(0) << 24) | (b(1) << 16) | (b(2) << 8) | b(3);
}

/// Bounds-checked cursor over a byte string.
struct Reader {
  std::string_view data;
  std::size_t pos;

  std::uint8_t byte() {
    if (pos >= data.size()) throw Error("unexpected end of data");
    return static_cast<std::uint8_t>(data[pos++]);
  }
};

}  // namespace

std::string_view type_name(ObjectType type) {
  switch (type) {
    case ObjectType::Commit: return "commit";
    case ObjectType::Tree: return "tree";
    case ObjectType::Blob: return "blob";
    case ObjectType::Tag: return "tag";
  }
  return "";
}

ObjectId hash_object(ObjectType type, std::string_view data) {
  std::string header(type_name(type));
  header += ' ';
  header += std::to_string(data.size());
  header += '\0';
  Sha1 h;
  h.update(header);
  h.update(data);
  return h.finish();
}

// ---------------------------------------------------------------- PackIndex

namespace {
constexpr std::size_t kFanoutPos = 8;
constexpr std::size_t kIdsPos = kFanoutPos + 256 * 4;
constexpr std::size_t kTrailer = 40;
}  // namespace

std::optional<PackIndex> PackIndex::parse(std::string bytes) {
  if (bytes.size() < kIdsPos + kTrailer) return std::nullopt;
  if (bytes.compare(0, 4, "\xff" "tOc", 4) != 0) return std::nullopt;
  PackIndex idx;
  idx.bytes_ = std::move(bytes);
  if (idx.read32(4) != 2) return std::nullopt;
  std::uint32_t previous = 0;
  for (int b = 0; b < 256; ++b) {
    std::uint32_t f = idx.fanout(b);
    if (f < previous) return std::nullopt;
    previous = f;
  }
  idx.count_ = previous;
  std::uint64_t need = kIdsPos + std::uint64_t(idx.count_) * 28 + kTrailer;
  if (idx.bytes_.size() < need) return std::nullopt;
  return idx;
}

std::uint32_t PackIndex::read32(std::size_t pos) const { return be32(bytes_, pos); }

std::uint32_t PackIndex::fanout(int b) const { return read32(kFanoutPos + 4 * b); }

ObjectId PackIndex::id_at(std::uint32_t i) const {
  return ObjectId::from_raw(bytes_.data() + kIdsPos + std::size_t(i) * 20);
}

std::uint32_t PackIndex::lower_bound(const ObjectId& key) const {
  int first = key.bytes[0];
  std::uint32_t lo = first == 0 ? 0 : fanout(first - 1);
  std::uint32_t hi = fanout(first);
  while (lo < hi) {
    std::uint32_t mid = lo + (hi - lo) / 2;
    if (id_at(mid) < key) lo = mid + 1; else hi = mid;
  }
  return lo;
}

std::optional<std::uint64_t> PackIndex::find(const ObjectId& id) const {
  std::uint32_t i = lower_bound(id);
  if (i >= count_ || id_at(i) != id) return std::nullopt;
  std::size_t offsets_pos = kIdsPos + std::size_t(count_) * 24;
  std::uint32_t v = read32(offsets_pos + 4 * std::size_t(i));
  if ((v & 0x80000000u) == 0) return v;
  std::size_t big_pos = offsets_pos + std::size_t(count_) * 4 + 8 * std::size_t(v & 0x7fffffffu);
  if (big_pos + 8 > bytes_.size() - kTrailer) return std::nullopt;
  return (std::uint64_t(be32(bytes_, big_pos)) << 32) | be32(bytes_, big_pos + 4);
}

// -------------------------------------------------------------- ObjectStore

ObjectStore::ObjectStore(const fs::path& objects_dir) : objects_dir_(objects_dir) {
  std::error_code ec;

  for (fs::directory_iterator it(objects_dir, ec), end; !ec && it != end; it.increment(ec)) {
    std::string prefix = it->path().filename().string();
    std::error_code ec2;
    if (!is_hex_name(prefix, 2) || !it->is_directory(ec2)) continue;
    for (fs::directory_iterator sub(it->path(), ec2), send; !ec2 && sub != send;
         sub.increment(ec2)) {
      std::string rest = sub->path().filename().string();
      std::error_code ec3;
      if (!is_hex_name(rest, 38) || !sub->is_regular_file(ec3)) continue;
      if (auto id = ObjectId::from_hex(prefix + rest)) loose_.push_back(*id);
    }
  }
  std::sort(loose_.begin(), loose_.end());

  std::vector<fs::path> idx_paths;
  ec.clear();
  for (fs::directory_iterator it(objects_dir / "pack", ec), end; !ec && it != end;
       it.increment(ec)) {
    std::error_code ec2;
    if (it->path().extension() == ".idx" && it->is_regular_file(ec2)) {
      idx_paths.push_back(it->path());
    }
  }
  std::sort(idx_paths.begin(), idx_paths.end());
  for (const fs::path& idx_path : idx_paths) {
    fs::path pack_path = idx_path;
    pack_path.replace_extension(".pack");
    auto idx_bytes = detail::read_file(idx_path);
    auto pack_bytes = detail::read_file(pack_path);
    if (!idx_bytes || !pack_bytes) continue;
    auto index = PackIndex::parse(std::move(*idx_bytes));
    if (!index) continue;
    packs_.push_back(Pack{std::move(*index), std::move(*pack_bytes)});
  }
}

std::size_t ObjectStore::packed_object_count() const {
  std::size_t total = 0;
  for (const Pack& p : packs_) total += p.index.size();
  return total;
}

bool ObjectStore::contains(const ObjectId& id) const {
  if (std::binary_search(loose_.begin(), loose_.end(), id)) return true;
  return std::any_of(packs_.begin(), packs_.end(),
                     [&](const Pack& p) { return p.index.find(id).has_value(); });
}

ObjectPtr ObjectStore::read(const ObjectId& id) {
  if (auto it = cache_.find(id); it != cache_.end()) return it->second;

  ObjectPtr result;
  if (std::binary_search(loose_.begin(), loose_.end(), id)) {
    result = read_loose(id);
  } else {
    for (std::size_t i = 0; i < packs_.size() && !result; ++i) {
      if (auto offset = packs_[i].index.find(id)) result = read_packed(i, *offset);
    }
    if (!result) throw Error("object not found: " + id.hex());
  }
  cache_.emplace(id, result);
  return result;
}

ObjectPtr ObjectStore::read_loose(const ObjectId& id) const {
  std::string hex = id.hex();
  auto file = detail::read_file(objects_dir_ / hex.substr(0, 2) / hex.substr(2));
  if (!file) throw Error("cannot read loose object " + hex);

  std::string plain;
  zlib_inflate(*file, plain);

  std::size_t space = plain.find(' ');
  if (space == std::string::npos) throw Error("loose object: bad header");
  auto type = type_from_name(std::string_view(plain).substr(0, space));
  if (!type) throw Error("loose object: bad type");
  std::size_t i = space + 1;
  std::uint64_t size = 0;
  std::size_t digits = 0;
  while (i < plain.size() && plain[i] >= '0' && plain[i] <= '9') {
    if (++digits > 18) throw Error("loose object: size too large");
    size = size * 10 + std::uint64_t(plain[i] - '0');
    ++i;
  }
  if (digits == 0 || i >= plain.size() || plain[i] != '\0') {
    throw Error("loose object: bad header");
  }
  ++i;
  if (plain.size() - i != size) throw Error("loose object: size mismatch");
  return std::make_shared<const Object>(Object{*type, plain.substr(i)});
}

namespace {
struct DepthGuard {
  int& depth;
  explicit DepthGuard(int& d) : depth(d) {
    if (++depth > kMaxDeltaDepth) {
      --depth;
      throw Error("delta chain too deep");
    }
  }
  ~DepthGuard() { --depth; }
};
}  // namespace

ObjectPtr ObjectStore::read_packed(std::size_t pack_index, std::uint64_t offset) {
  auto key = std::make_pair(pack_index, offset);
  if (auto it = pack_cache_.find(key); it != pack_cache_.end()) return it->second;
  DepthGuard guard(depth_);

  std::string_view data = packs_[pack_index].data;
  if (data.size() < 12 + 20 || data.compare(0, 4, "PACK") != 0 || be32(data, 4) != 2) {
    throw Error("bad pack header");
  }
  if (offset < 12 || offset >= data.size() - 20) throw Error("pack offset out of range");

  Reader r{data.substr(0, data.size() - 20), static_cast<std::size_t>(offset)};
  std::uint8_t c = r.byte();
  int type = (c >> 4) & 7;
  std::uint64_t size = c & 15;
  int shift = 4;
  while (c & 0x80) {
    c = r.byte();
    if (shift > 56) throw Error("pack object size too large");
    size |= std::uint64_t(c & 0x7f) << shift;
    shift += 7;
  }

  ObjectPtr result;
  if (type >= 1 && type <= 4) {
    std::string plain;
    zlib_inflate(r.data.substr(r.pos), plain, size);
    if (plain.size() != size) throw Error("pack object size mismatch");
    result = std::make_shared<const Object>(Object{static_cast<ObjectType>(type), std::move(plain)});
  } else if (type == 6 || type == 7) {
    ObjectPtr base;
    if (type == 6) {
      c = r.byte();
      std::uint64_t back = c & 0x7f;
      while (c & 0x80) {
        c = r.byte();
        back = ((back + 1) << 7) | (c & 0x7f);
        if (back > (std::uint64_t(1) << 56)) throw Error("bad delta base offset");
      }
      if (back == 0 || back > offset) throw Error("bad delta base offset");
      base = read_packed(pack_index, offset - back);
    } else {
      if (r.pos + 20 > r.data.size()) throw Error("truncated ref-delta header");
      ObjectId base_id = ObjectId::from_raw(r.data.data() + r.pos);
      r.pos += 20;
      base = read(base_id);
    }
    std::string delta;
    zlib_inflate(r.data.substr(r.pos), delta, size);
    if (delta.size() != size) throw Error("pack delta size mismatch");
    result = std::make_shared<const Object>(Object{base->type, apply_delta(base->data, delta)});
  } else {
    throw Error("invalid pack object type");
  }
  pack_cache_.emplace(key, result);
  return result;
}

std::vector<ObjectId> ObjectStore::find_by_prefix(std::string_view prefix,
                                                  std::size_t limit) const {
  ObjectId low;  // smallest id with the prefix
  for (std::size_t i = 0; i < prefix.size(); ++i) {
    char ch = prefix[i];
    std::uint8_t v = ch <= '9' ? ch - '0' : ch - 'a' + 10;
    low.bytes[i / 2] |= (i % 2 == 0) ? (v << 4) : v;
  }
  auto matches = [&](const ObjectId& id) {
    for (std::size_t i = 0; i < prefix.size(); ++i) {
      std::uint8_t b = id.bytes[i / 2];
      std::uint8_t v = (i % 2 == 0) ? (b >> 4) : (b & 15);
      std::uint8_t want = prefix[i] <= '9' ? prefix[i] - '0' : prefix[i] - 'a' + 10;
      if (v != want) return false;
    }
    return true;
  };

  std::set<ObjectId> found;
  auto it = std::lower_bound(loose_.begin(), loose_.end(), low);
  for (std::size_t n = 0; it != loose_.end() && matches(*it) && n < limit; ++it, ++n) {
    found.insert(*it);
  }
  for (const Pack& p : packs_) {
    std::uint32_t i = p.index.lower_bound(low);
    for (std::size_t n = 0; i < p.index.size() && n < limit; ++i, ++n) {
      ObjectId id = p.index.id_at(i);
      if (!matches(id)) break;
      found.insert(id);
    }
  }
  std::vector<ObjectId> out(found.begin(), found.end());
  if (out.size() > limit) out.resize(limit);
  return out;
}

// -------------------------------------------------------------------- delta

std::string apply_delta(std::string_view base, std::string_view delta) {
  Reader r{delta, 0};
  auto varint = [&]() {
    std::uint64_t v = 0;
    int shift = 0;
    std::uint8_t c;
    do {
      c = r.byte();
      if (shift > 56) throw Error("delta: size too large");
      v |= std::uint64_t(c & 0x7f) << shift;
      shift += 7;
    } while (c & 0x80);
    return v;
  };
  std::uint64_t base_size = varint();
  std::uint64_t result_size = varint();
  if (base_size != base.size()) throw Error("delta: base size mismatch");
  if (result_size > (std::uint64_t(1) << 31)) throw Error("delta: result too large");

  std::string out;
  out.reserve(static_cast<std::size_t>(result_size));
  while (r.pos < delta.size()) {
    std::uint8_t op = r.byte();
    if (op & 0x80) {
      std::uint64_t offset = 0, length = 0;
      for (int i = 0; i < 4; ++i) {
        if (op & (1 << i)) offset |= std::uint64_t(r.byte()) << (8 * i);
      }
      for (int i = 0; i < 3; ++i) {
        if (op & (0x10 << i)) length |= std::uint64_t(r.byte()) << (8 * i);
      }
      if (length == 0) length = 0x10000;
      if (offset > base.size() || length > base.size() - offset) {
        throw Error("delta: copy outside base");
      }
      out.append(base.data() + offset, static_cast<std::size_t>(length));
    } else if (op != 0) {
      if (op > delta.size() - r.pos) throw Error("delta: truncated insert");
      out.append(delta.data() + r.pos, op);
      r.pos += op;
    } else {
      throw Error("delta: invalid instruction 0");
    }
    if (out.size() > result_size) throw Error("delta: result larger than declared");
  }
  if (out.size() != result_size) throw Error("delta: result size mismatch");
  return out;
}

}  // namespace gitrepo
