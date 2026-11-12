#include "spreadsheet/sheet.h"

#include <algorithm>
#include <cstdlib>
#include <unordered_map>
#include <unordered_set>

#include "spreadsheet/evaluator.h"
#include "spreadsheet/formula.h"
#include "spreadsheet/parser.h"

namespace spreadsheet {
namespace {

enum class Content { Empty, Number, String, Formula };

struct Cell {
  explicit Cell(CellRef r) : ref(r) {}

  CellRef ref;
  Content content = Content::Empty;
  Value value;                          // stored (current) value
  std::unique_ptr<Formula> formula;     // when content == Formula
  std::vector<Cell*> deps;              // cells this cell reads (deduplicated)
  std::unordered_set<Cell*> dependents; // formula cells that read this cell

  // Scratch state for one recalculation.
  std::uint64_t epoch = 0;  // == current epoch iff the cell is in the affected set
  int index = -1;
  int lowlink = 0;
  bool on_stack = false;
};

const Value kEmptyValue;

}  // namespace

struct Sheet::Impl : CellLookup {
  std::unordered_map<std::uint32_t, std::unique_ptr<Cell>> cells;
  std::uint64_t epoch = 0;

  const Value& value_at(CellRef ref) const override {
    auto it = cells.find(ref.key());
    return it == cells.end() ? kEmptyValue : it->second->value;
  }

  Cell* find(CellRef ref) const {
    auto it = cells.find(ref.key());
    return it == cells.end() ? nullptr : it->second.get();
  }

  Cell& get_or_create(CellRef ref) {
    auto& slot = cells[ref.key()];
    if (!slot) slot = std::make_unique<Cell>(ref);
    return *slot;
  }

  void unlink(Cell& c) {
    for (Cell* d : c.deps) d->dependents.erase(&c);
    c.deps.clear();
  }

  void link(Cell& c, const std::vector<CellRef>& deps) {
    c.deps.reserve(deps.size());
    for (CellRef d : deps) {
      Cell& target = get_or_create(d);
      c.deps.push_back(&target);
      target.dependents.insert(&c);
    }
  }

  void assign(CellRef ref, Content content, Value value, std::unique_ptr<Formula> formula) {
    Cell& c = get_or_create(ref);
    unlink(c);
    c.content = content;
    c.value = std::move(value);
    c.formula = std::move(formula);
    if (c.formula) link(c, c.formula->dependencies());
    recalculate(c);
  }

  // Recomputes the edited cell and everything that transitively reads it.
  void recalculate(Cell& start) {
    ++epoch;
    // 1. Affected set A: reverse reachability from the edited cell.
    std::vector<Cell*> affected;
    start.epoch = epoch;
    start.index = -1;
    start.on_stack = false;
    affected.push_back(&start);
    for (std::size_t i = 0; i < affected.size(); ++i) {
      for (Cell* d : affected[i]->dependents) {
        if (d->epoch == epoch) continue;
        d->epoch = epoch;
        d->index = -1;
        d->on_stack = false;
        affected.push_back(d);
      }
    }
    // 2. Tarjan over the subgraph induced by A (edges: cell -> its
    //    dependencies). Components are emitted dependencies-first.
    struct Frame {
      Cell* cell;
      std::size_t next;
    };
    std::vector<Frame> frames;
    std::vector<Cell*> stack;
    int counter = 0;
    auto open = [&](Cell* c) {
      c->index = c->lowlink = counter++;
      c->on_stack = true;
      stack.push_back(c);
      frames.push_back({c, 0});
    };
    std::vector<Cell*> component;
    for (Cell* root : affected) {
      if (root->index >= 0) continue;
      open(root);
      while (!frames.empty()) {
        Frame& f = frames.back();
        Cell* c = f.cell;
        if (f.next < c->deps.size()) {
          Cell* d = c->deps[f.next++];
          if (d->epoch != epoch) continue;
          if (d->index < 0) {
            open(d);  // invalidates `f`
          } else if (d->on_stack) {
            c->lowlink = std::min(c->lowlink, d->index);
          }
          continue;
        }
        int low = c->lowlink;
        if (c->lowlink == c->index) {
          component.clear();
          Cell* m;
          do {
            m = stack.back();
            stack.pop_back();
            m->on_stack = false;
            component.push_back(m);
          } while (m != c);
          settle(component);
        }
        frames.pop_back();
        if (!frames.empty()) {
          Cell* parent = frames.back().cell;
          parent->lowlink = std::min(parent->lowlink, low);
        }
      }
    }
  }

  void settle(const std::vector<Cell*>& component) {
    bool cyclic = component.size() > 1;
    if (!cyclic) {
      const Cell* c = component[0];
      cyclic = std::find(c->deps.begin(), c->deps.end(), c) != c->deps.end();
    }
    if (cyclic) {
      for (Cell* c : component) c->value = Value::error(ErrorCode::Cycle);
      return;
    }
    Cell* c = component[0];
    if (c->content == Content::Formula) c->value = evaluate(*c->formula, *this);
  }
};

Sheet::Sheet() : impl_(std::make_unique<Impl>()) {}
Sheet::~Sheet() = default;
Sheet::Sheet(Sheet&&) noexcept = default;
Sheet& Sheet::operator=(Sheet&&) noexcept = default;

void Sheet::set_number(CellRef ref, double value) {
  impl_->assign(ref, Content::Number, Value::number(value), nullptr);
}

void Sheet::set_string(CellRef ref, std::string_view text) {
  impl_->assign(ref, Content::String, Value::string(std::string(text)), nullptr);
}

void Sheet::set_formula(CellRef ref, std::string_view expression) {
  auto formula = std::make_unique<Formula>(parse_formula(expression));
  impl_->assign(ref, Content::Formula, Value(), std::move(formula));
}

void Sheet::set_content(CellRef ref, std::string_view content) {
  if (!content.empty() && content[0] == '=') {
    set_formula(ref, content.substr(1));
  } else if (content.size() >= 2 && content.front() == '"' && content.back() == '"') {
    set_string(ref, content.substr(1, content.size() - 2));
  } else {
    // Number literal: -?[0-9]+(\.[0-9]+)?
    if (content.empty()) throw ParseError("empty cell content");
    std::size_t i = content[0] == '-' ? 1 : 0;
    std::size_t d = i;
    while (d < content.size() && content[d] >= '0' && content[d] <= '9') ++d;
    bool ok = d > i;
    if (ok && d < content.size() && content[d] == '.') {
      std::size_t f = ++d;
      while (d < content.size() && content[d] >= '0' && content[d] <= '9') ++d;
      ok = d > f;
    }
    if (!ok || d != content.size()) throw ParseError("invalid cell content: " + std::string(content));
    set_number(ref, std::strtod(std::string(content).c_str(), nullptr));
  }
}

void Sheet::clear(CellRef ref) {
  Cell* c = impl_->find(ref);
  if (!c || c->content == Content::Empty) return;
  impl_->assign(ref, Content::Empty, Value(), nullptr);
}

const Value& Sheet::value(CellRef ref) const { return impl_->value_at(ref); }

std::string Sheet::display(CellRef ref) const { return value(ref).display(); }

std::vector<std::pair<CellRef, Value>> Sheet::cells() const {
  std::vector<std::pair<CellRef, Value>> out;
  for (const auto& kv : impl_->cells) {
    const Cell& c = *kv.second;
    if (c.content != Content::Empty) out.emplace_back(c.ref, c.value);
  }
  std::sort(out.begin(), out.end(),
            [](const auto& a, const auto& b) { return a.first < b.first; });
  return out;
}

std::size_t Sheet::size() const {
  std::size_t n = 0;
  for (const auto& kv : impl_->cells) n += kv.second->content != Content::Empty;
  return n;
}

}  // namespace spreadsheet
