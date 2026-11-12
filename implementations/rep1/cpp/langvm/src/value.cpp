#include "value.h"

#include <functional>

namespace langvm {
namespace {

// Freeing is iterative so that dropping a very long chain of nested values
// does not recurse on the host stack.
std::vector<Obj*>& pendingList() {
  static thread_local std::vector<Obj*> p;
  return p;
}
bool& draining() {
  static thread_local bool d = false;
  return d;
}

void destroyOne(Obj* o) {
  switch (o->kind) {
    case VT::Str: delete static_cast<StrObj*>(o); break;
    case VT::List: delete static_cast<ListObj*>(o); break;
    case VT::Map: delete static_cast<MapObj*>(o); break;
    default: {
      ArrObj* a = static_cast<ArrObj*>(o);
      Value* it = a->items();
      for (uint32_t i = 0; i < a->n; ++i) it[i].~Value();
      a->~ArrObj();
      std::free(a);
    }
  }
}

}  // namespace

void objFree(Obj* o) {
  auto& pending = pendingList();
  pending.push_back(o);
  if (draining()) return;
  draining() = true;
  while (!pending.empty()) {
    Obj* x = pending.back();
    pending.pop_back();
    destroyOne(x);
  }
  draining() = false;
}

Value newStr(std::u32string s) {
  auto* o = new StrObj();
  o->kind = VT::Str;
  o->s = std::move(s);
  o->rc = 1;
  Value v;
  v.t = VT::Str;
  v.u.o = o;
  return v;
}

Value newList(std::vector<Value> items) {
  auto* o = new ListObj();
  o->kind = VT::List;
  o->v = std::move(items);
  o->rc = 1;
  Value v;
  v.t = VT::List;
  v.u.o = o;
  return v;
}

Value newMap() {
  auto* o = new MapObj();
  o->kind = VT::Map;
  o->rc = 1;
  Value v;
  v.t = VT::Map;
  v.u.o = o;
  return v;
}

Value newArr(VT kind, uint32_t n, uint32_t decl, uint8_t variant, int32_t aux) {
  void* mem = std::malloc(sizeof(ArrObj) + sizeof(Value) * n);
  auto* o = new (mem) ArrObj();
  o->kind = kind;
  o->n = n;
  o->aux = aux;
  o->rc = 1;
  Value* it = o->items();
  for (uint32_t i = 0; i < n; ++i) new (&it[i]) Value();
  Value v;
  v.t = kind;
  v.decl = decl;
  v.variant = variant;
  v.u.o = o;
  return v;
}

size_t KeyHash::operator()(const Value& v) const {
  if (v.t == VT::Str) return std::hash<std::u32string_view>()(strOf(v));
  return std::hash<int64_t>()(v.u.i);
}

bool KeyEq::operator()(const Value& a, const Value& b) const {
  if (a.t != b.t) return false;
  if (a.t == VT::Str) return strOf(a) == strOf(b);
  return a.u.i == b.u.i;
}

Value* MapObj::find(const Value& k) {
  auto it = index.find(k);
  return it == index.end() ? nullptr : &entries[it->second].v;
}

void MapObj::set(const Value& k, const Value& v) {
  auto it = index.find(k);
  if (it != index.end()) {
    entries[it->second].v = v;
    return;
  }
  index.emplace(k, static_cast<uint32_t>(entries.size()));
  entries.push_back({k, v, true});
}

bool MapObj::erase(const Value& k) {
  auto it = index.find(k);
  if (it == index.end()) return false;
  Entry& e = entries[it->second];
  e.live = false;
  e.k = Value();
  e.v = Value();
  index.erase(it);
  if (entries.size() > 32 && entries.size() > 2 * index.size()) compact();
  return true;
}

void MapObj::clear() {
  entries.clear();
  index.clear();
}

void MapObj::compact() {
  std::vector<Entry> live;
  live.reserve(index.size());
  for (Entry& e : entries)
    if (e.live) live.push_back(std::move(e));
  entries = std::move(live);
  index.clear();
  for (uint32_t i = 0; i < entries.size(); ++i) index.emplace(entries[i].k, i);
}

int valueCtor(const Value& v) {
  switch (v.t) {
    case VT::Int: return 0;
    case VT::Float: return 1;
    case VT::Bool: return 2;
    case VT::Char: return 3;
    case VT::Str: return 4;
    case VT::Unit: return 5;
    case VT::List: return 6;
    case VT::Map: return 7;
    case VT::Struct: case VT::Enum: return 8 + static_cast<int>(v.decl);
    default: return -1;
  }
}

bool valuesEqual(const Value& a, const Value& b) {
  if (a.t != b.t) return false;
  switch (a.t) {
    case VT::Unit: return true;
    case VT::Bool: case VT::Int: case VT::Char: return a.u.i == b.u.i;
    case VT::Float: return a.u.f == b.u.f;
    case VT::Str: return a.u.o == b.u.o || strOf(a) == strOf(b);
    case VT::List: {
      if (a.u.o == b.u.o) return true;
      const auto& x = listOf(a);
      const auto& y = listOf(b);
      if (x.size() != y.size()) return false;
      for (size_t i = 0; i < x.size(); ++i)
        if (!valuesEqual(x[i], y[i])) return false;
      return true;
    }
    case VT::Map: {
      MapObj& x = mapOf(a);
      MapObj& y = mapOf(b);
      if (x.size() != y.size()) return false;
      for (auto& e : x.entries) {
        if (!e.live) continue;
        Value* o = y.find(e.k);
        if (!o || !valuesEqual(e.v, *o)) return false;
      }
      return true;
    }
    case VT::Struct: case VT::Tuple: case VT::Enum: {
      if (a.t == VT::Enum && (a.variant != b.variant || a.decl != b.decl)) return false;
      if (a.t == VT::Struct && a.decl != b.decl) return false;
      if (a.u.o == b.u.o) return true;
      if (!a.u.o || !b.u.o) return false;
      const ArrObj& x = arrOf(a);
      const ArrObj& y = arrOf(b);
      if (x.n != y.n) return false;
      for (uint32_t i = 0; i < x.n; ++i)
        if (!valuesEqual(x.items()[i], y.items()[i])) return false;
      return true;
    }
    case VT::Closure: return false;
  }
  return false;
}

}  // namespace langvm
