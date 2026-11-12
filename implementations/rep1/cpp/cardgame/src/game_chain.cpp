// Triggers, state checks, targeting, playing cards, activating abilities and
// resolving Chain entries (SPEC.md sections 10-13, 18).
#include <algorithm>
#include <ostream>

#include "spiremark/game.hpp"

namespace spiremark {

using detail::C;
using detail::O;
using detail::P;
using detail::S;

// ------------------------------------------------------------------ triggers --

void Game::collect_self(Event ev, int oid, Ref it, bool force, int controller) {
    if (no_triggers_) return;
    ensure_derived();
    Obj& o = obj(oid);
    if (!force) {
        if (o.zone != Zone::Field || o.stripped) return;
        controller = o.ctrl;
    }
    for (std::size_t i = 0; i < o.card->abilities.size(); ++i) {
        const Ability& ab = o.card->abilities[i];
        if (ab.kind != Ability::Kind::On || ab.event != ev) continue;
        Pending p;
        p.controller = controller;
        p.ts = o.ts;
        p.oid = oid;
        p.index = static_cast<int>(i) + 1;
        p.source = oid;
        p.it = it;
        pending_.push_back(std::move(p));
    }
}

void Game::collect_all(Event ev, int ctrl_filter, bool use_ctrl, Ref it) {
    if (no_triggers_) return;
    ensure_derived();
    for (std::size_t k = 0; k < field_.size(); ++k) {
        int oid = field_[k];
        if (use_ctrl && obj(oid).ctrl != ctrl_filter) continue;
        collect_self(ev, oid, it, false, 0);
    }
}

void Game::collect_arrive(int oid) {
    if (no_triggers_) return;
    ensure_derived();
    Ref it = Ref::object(static_cast<std::uint64_t>(oid));
    collect_self(Event::Arrive, oid, it, false, 0);
    if (obj(oid).card->type != CardType::Unit) return;
    int ctrl = obj(oid).ctrl;
    for (std::size_t k = 0; k < field_.size(); ++k) {
        int y = field_[k];
        if (y == oid) continue;
        collect_self(obj(y).ctrl == ctrl ? Event::AllyArrive : Event::EnemyArrive, y, it, false, 0);
    }
}

void Game::collect_death(int oid, int ctrl_at_leave, bool died, bool left) {
    if (no_triggers_) return;
    Ref it = Ref::object(static_cast<std::uint64_t>(oid));
    if (died) collect_self(Event::Dies, oid, it, true, ctrl_at_leave);
    if (left) collect_self(Event::Leave, oid, it, true, ctrl_at_leave);
    if (died && obj(oid).card->type == CardType::Unit) {
        ensure_derived();
        for (std::size_t k = 0; k < field_.size(); ++k) {
            int y = field_[k];
            collect_self(obj(y).ctrl == ctrl_at_leave ? Event::AllyDies : Event::EnemyDies, y, it,
                         false, 0);
        }
    }
}

void Game::collect_spire_loss(int p) {
    Ref it = Ref::player(p);
    collect_all(Event::SpireLoss, p, true, it);
    collect_all(Event::EnemySpireLoss, opponent(p), true, it);
}

// -------------------------------------------------------------------- settle --

bool Game::check_losses() {
    bool lost[2];
    for (int p = 0; p < 2; ++p) {
        if (loss_reason_[p].empty() && spire_[p] <= 0) loss_reason_[p] = "spire";
        lost[p] = !loss_reason_[p].empty();
    }
    if (!lost[0] && !lost[1]) return false;
    for (int p = 0; p < 2; ++p)
        if (lost[p]) emit("LOSE", P{p}, loss_reason_[p]);
    if (lost[0] && lost[1]) {
        result_winner_ = "draw";
        result_reason_ = loss_reason_[0];
    } else if (lost[0]) {
        result_winner_ = "B";
        result_reason_ = loss_reason_[0];
    } else {
        result_winner_ = "A";
        result_reason_ = loss_reason_[1];
    }
    emit("RESULT", result_winner_, result_reason_);
    over_ = true;
    decision_ = Decision{};
    return true;
}

void Game::end_with_draw(const char* reason) {
    result_winner_ = "draw";
    result_reason_ = reason;
    emit("RESULT", "draw", reason);
    over_ = true;
    decision_ = Decision{};
}

bool Game::state_checks() {
    if (check_losses()) return false;
    ensure_derived();
    std::vector<int> doomed;
    for (int oid : field_) {
        const Obj& o = obj(oid);
        if (o.card->type != CardType::Unit) continue;
        if (o.doomed || o.core <= o.wounds) doomed.push_back(oid);
    }
    for (int oid : doomed)
        if (on_field(oid)) destroy_obj(oid);
    return !doomed.empty();
}

bool Game::settle() {
    bool acted = false;
    for (;;) {
        bool a = state_checks();
        if (over_) return acted;
        bool b = push_triggers();
        acted = acted || a || b;
        if (!a && !b) break;
    }
    return acted;
}

void Game::drain() {
    for (;;) {
        settle();
        if (over_ || chain_.empty()) return;
        resolve_top();
    }
}

bool Game::push_triggers() {
    if (pending_.empty()) return false;
    std::vector<Pending> batch;
    batch.swap(pending_);
    std::stable_sort(batch.begin(), batch.end(), [this](const Pending& a, const Pending& b) {
        int ka = a.controller == active_ ? 0 : 1;
        int kb = b.controller == active_ ? 0 : 1;
        if (ka != kb) return ka < kb;
        if (a.ts != b.ts) return a.ts < b.ts;
        if (a.oid != b.oid) return a.oid < b.oid;
        return a.index < b.index;
    });
    std::vector<Entry> entries;
    for (Pending& p : batch) {
        Entry e;
        e.kind = EntryKind::Trigger;
        e.controller = p.controller;
        e.source = p.source;
        e.index = p.index;
        e.it = p.it;
        bool dropped = false;
        if (p.effects) {
            e.delayed_effects = p.effects;
            e.specs = p.specs;
            e.targets = p.targets;
        } else {
            const Ability& ab = obj(p.source).card->abilities[static_cast<std::size_t>(p.index - 1)];
            e.specs = &ab.targets;
            for (const TargetSpec& spec : ab.targets) {
                std::vector<Ref> cands = candidates(spec, p.controller, p.source, -1);
                Ref pick;
                for (const Ref& c : cands) {
                    bool used = false;
                    for (const Target& t : e.targets)
                        if (t.ref == c) { used = true; break; }
                    if (!used) { pick = c; break; }
                }
                if (pick.kind == Ref::Kind::None) { dropped = true; break; }
                e.targets.push_back({pick, false});
            }
        }
        if (dropped) {
            emit("TRIGGER-NO-TARGET", P{p.controller}, O{p.source}, p.index);
            continue;
        }
        e.cid = next_cid_++;
        emit_line(detail::build("TRIGGER", P{e.controller}, C{e.cid}, O{e.source}, e.index) +
                  render_targets(e.targets, false));
        entries.push_back(std::move(e));
    }
    for (auto it = entries.rbegin(); it != entries.rend(); ++it) chain_.push_back(std::move(*it));
    return true;
}

// ------------------------------------------------------------------ targeting --

Game::Entry* Game::find_entry(int cid) {
    for (Entry& e : chain_)
        if (e.cid == cid) return &e;
    return nullptr;
}

bool Game::target_legal(const TargetSpec& s, Ref r, int controller, int source, int self_cid) {
    using K = TargetSpec::Kind;
    ensure_derived();
    Ctx ctx;
    ctx.controller = controller;
    ctx.source = source;
    auto unit_ok = [&](const Obj& o, CardType want) {
        if (o.zone != Zone::Field || o.card->type != want) return false;
        if (!match_filters(o, s.filters, ctx)) return false;
        if (o.card->type == CardType::Unit && has_kw(o.oid, Kw::Spectral) && o.ctrl != controller)
            return false;
        return true;
    };
    switch (s.kind) {
        case K::Player: return r.is_player();
        case K::Any:
            if (r.is_player()) return true;
            return r.is_object() && valid_oid(r.id) && unit_ok(obj(static_cast<int>(r.id)), CardType::Unit);
        case K::Unit:
            return r.is_object() && valid_oid(r.id) && unit_ok(obj(static_cast<int>(r.id)), CardType::Unit);
        case K::Relic:
            return r.is_object() && valid_oid(r.id) && unit_ok(obj(static_cast<int>(r.id)), CardType::Relic);
        case K::Chained:
            return r.is_entry() && r.id < 0x7fffffffULL && static_cast<int>(r.id) != self_cid &&
                   find_entry(static_cast<int>(r.id)) != nullptr;
        case K::AshCard: {
            if (!r.is_object() || !valid_oid(r.id)) return false;
            const Obj& o = obj(static_cast<int>(r.id));
            return o.zone == Zone::Ash && match_filters(o, s.filters, ctx);
        }
    }
    return false;
}

std::vector<Ref> Game::candidates(const TargetSpec& s, int controller, int source, int self_cid) {
    using K = TargetSpec::Kind;
    std::vector<Ref> out;
    if (s.kind == K::Player || s.kind == K::Any) {
        out.push_back(Ref::player(0));
        out.push_back(Ref::player(1));
    }
    if (s.kind == K::Unit || s.kind == K::Relic || s.kind == K::Any) {
        for (int oid : field_) {
            Ref r = Ref::object(static_cast<std::uint64_t>(oid));
            if (target_legal(s, r, controller, source, self_cid)) out.push_back(r);
        }
    }
    if (s.kind == K::AshCard) {
        std::vector<int> all;
        for (int p = 0; p < 2; ++p) all.insert(all.end(), ash_[p].begin(), ash_[p].end());
        sort_canonical(all);
        for (int oid : all) {
            Ref r = Ref::object(static_cast<std::uint64_t>(oid));
            if (target_legal(s, r, controller, source, self_cid)) out.push_back(r);
        }
    }
    if (s.kind == K::Chained) {
        std::vector<int> cids;
        for (const Entry& e : chain_)
            if (e.cid != self_cid) cids.push_back(e.cid);
        std::sort(cids.begin(), cids.end());
        for (int c : cids) out.push_back(Ref::entry(static_cast<std::uint64_t>(c)));
    }
    return out;
}

std::vector<std::vector<Ref>> Game::target_tuples(const std::vector<TargetSpec>& specs,
                                                  int controller, int source, int self_cid) {
    std::vector<std::vector<Ref>> cand;
    for (const TargetSpec& s : specs) {
        cand.push_back(candidates(s, controller, source, self_cid));
        if (cand.back().empty()) return {};
    }
    std::vector<std::vector<Ref>> out;
    std::vector<Ref> cur;
    // iterative odometer over the candidate lists, skipping repeated tokens
    std::vector<std::size_t> idx(specs.size(), 0);
    if (specs.empty()) {
        out.push_back({});
        return out;
    }
    std::size_t depth = 0;
    std::vector<std::size_t> pos(specs.size(), 0);
    cur.assign(specs.size(), Ref::none());
    for (;;) {
        if (pos[depth] >= cand[depth].size()) {
            if (depth == 0) break;
            pos[depth] = 0;
            --depth;
            ++pos[depth];
            continue;
        }
        Ref r = cand[depth][pos[depth]];
        bool dup = false;
        for (std::size_t k = 0; k < depth; ++k)
            if (cur[k] == r) { dup = true; break; }
        if (dup) {
            ++pos[depth];
            continue;
        }
        cur[depth] = r;
        if (depth + 1 == specs.size()) {
            out.push_back(cur);
            ++pos[depth];
        } else {
            ++depth;
            pos[depth] = 0;
        }
    }
    return out;
}

std::string Game::render_targets(const std::vector<Target>& ts, bool show_removed) const {
    std::string s;
    for (const Target& t : ts) {
        s += ' ';
        s += (show_removed && t.removed) ? "-" : t.ref.render();
    }
    return s;
}

std::string Game::render_ref_list(const std::vector<Ref>& rs) const {
    std::string s;
    for (const Ref& r : rs) {
        s += ' ';
        s += r.render();
    }
    return s;
}

// --------------------------------------------------------------- play / act --

bool Game::play_timing_ok(const Obj& o, int player) {
    if (o.card->type == CardType::Rite && o.card->has_printed_kw(Kw::Swift)) return true;
    return player == active_ && (cur_step_ == Step::Main1 || cur_step_ == Step::Main2) &&
           chain_.empty();
}

std::optional<ErrKind> Game::do_play(const Action& a) {
    int pl = a.player;
    if (a.pos == 0 || a.pos > hand_[pl].size()) return ErrKind::NoSuchCard;
    int oid = hand_[pl][static_cast<std::size_t>(a.pos - 1)];
    Obj& o = obj(oid);
    if (!play_timing_ok(o, pl)) return ErrKind::BadTiming;
    const std::vector<TargetSpec>* specs = nullptr;
    if (o.card->type == CardType::Rite && o.card->abilities[0].has_targets)
        specs = &o.card->abilities[0].targets;
    std::size_t need = specs ? specs->size() : 0;
    if (a.targets.size() != need) return ErrKind::BadTargetCount;
    int cid = next_cid_;
    for (std::size_t i = 0; i < need; ++i) {
        if (!target_legal((*specs)[i], a.targets[i], pl, oid, cid)) return ErrKind::IllegalTarget;
        for (std::size_t k = 0; k < i; ++k)
            if (a.targets[k] == a.targets[i]) return ErrKind::IllegalTarget;
    }
    std::int64_t cost = effective_cost(*o.card, pl);
    if (ember_[pl] < cost) return ErrKind::CannotAfford;

    Entry e;
    e.cid = next_cid_++;
    e.kind = o.card->type == CardType::Rite ? EntryKind::Rite
           : o.card->type == CardType::Unit ? EntryKind::Unit : EntryKind::Relic;
    e.controller = pl;
    e.source = oid;
    e.index = 0;
    e.specs = specs;
    for (const Ref& r : a.targets) e.targets.push_back({r, false});
    remove_from_zone(o);
    o.zone = Zone::Stack;
    chain_.push_back(e);
    emit_line(detail::build("PLAY", P{pl}, C{e.cid}, O{oid}, o.card->id) +
              render_targets(e.targets, false));
    if (cost > 0) {
        ember_[pl] -= cost;
        emit("PAY", P{pl}, "ember", cost);
    }
    if (o.card->type == CardType::Rite) {
        Ref it = Ref::object(static_cast<std::uint64_t>(oid));
        collect_all(Event::YouPlayRite, pl, true, it);
        collect_all(Event::EnemyPlaysRite, opponent(pl), true, it);
    }
    return std::nullopt;
}

bool Game::costs_payable(const Obj& o, const Ability& ab, int player, int index) {
    for (const CostItem& c : ab.cost) {
        switch (c.kind) {
            case CostItem::Kind::Ember:
                if (ember_[player] < c.n) return false;
                break;
            case CostItem::Kind::Spire: break;
            case CostItem::Kind::Discard:
                if (static_cast<std::int64_t>(hand_[player].size()) < c.n) return false;
                break;
            case CostItem::Kind::Exhaust:
                if (o.zone != Zone::Field || o.exhausted) return false;
                if (is_settling(o) && !has_kw(o.oid, Kw::Vanguard)) return false;
                break;
            case CostItem::Kind::Sacself:
                if (o.zone != Zone::Field) return false;
                break;
            case CostItem::Kind::Counters:
                if (o.counters < c.n) return false;
                break;
            case CostItem::Kind::Once:
                if (std::find(o.once.begin(), o.once.end(), index) != o.once.end()) return false;
                break;
        }
    }
    return true;
}

std::optional<ErrKind> Game::do_act(const Action& a) {
    int pl = a.player;
    ensure_derived();
    if (!valid_oid(a.oid)) return ErrKind::NoSuchObject;
    int oid = static_cast<int>(a.oid);
    Obj& o = obj(oid);
    if (o.zone != Zone::Field || o.ctrl != pl) return ErrKind::NoSuchObject;
    if (a.index == 0 || a.index > o.card->abilities.size()) return ErrKind::NoSuchAbility;
    const Ability& ab = o.card->abilities[static_cast<std::size_t>(a.index - 1)];
    if (ab.kind != Ability::Kind::Act || o.stripped) return ErrKind::NoSuchAbility;
    std::size_t need = ab.targets.size();
    if (a.targets.size() != need) return ErrKind::BadTargetCount;
    int cid = next_cid_;
    for (std::size_t i = 0; i < need; ++i) {
        if (!target_legal(ab.targets[i], a.targets[i], pl, oid, cid)) return ErrKind::IllegalTarget;
        for (std::size_t k = 0; k < i; ++k)
            if (a.targets[k] == a.targets[i]) return ErrKind::IllegalTarget;
    }
    if (!costs_payable(o, ab, pl, static_cast<int>(a.index))) return ErrKind::CostUnpayable;

    Entry e;
    e.cid = next_cid_++;
    e.kind = EntryKind::Ability;
    e.controller = pl;
    e.source = oid;
    e.index = static_cast<int>(a.index);
    e.specs = &ab.targets;
    for (const Ref& r : a.targets) e.targets.push_back({r, false});
    chain_.push_back(e);
    emit_line(detail::build("ACTIVATE", P{pl}, C{e.cid}, O{oid}, e.index) +
              render_targets(e.targets, false));
    pay_costs(o, ab, pl, e.index);
    return std::nullopt;
}

void Game::pay_costs(Obj& o, const Ability& ab, int pl, int index) {
    for (const CostItem& c : ab.cost) {
        switch (c.kind) {
            case CostItem::Kind::Ember:
                if (c.n > 0) {
                    ember_[pl] -= c.n;
                    touch();
                    emit("PAY", P{pl}, "ember", c.n);
                }
                break;
            case CostItem::Kind::Spire:
                if (c.n > 0) {
                    emit("PAY", P{pl}, "spire", c.n);
                    change_spire(pl, -c.n);
                }
                break;
            case CostItem::Kind::Discard:
                for (std::int64_t k = 0; k < c.n; ++k) discard_one(pl);
                break;
            case CostItem::Kind::Exhaust: set_exhausted(o.oid, true); break;
            case CostItem::Kind::Sacself: sacrifice_obj(o.oid); break;
            case CostItem::Kind::Counters: add_counters(o.oid, -c.n); break;
            case CostItem::Kind::Once: o.once.push_back(index); break;
        }
    }
}

// ------------------------------------------------------------------- resolve --

void Game::resolve_top() {
    Entry e = chain_.back();
    emit("RESOLVE", C{e.cid});
    // Re-check the targets (12.3).
    if (e.specs) {
        for (std::size_t i = 0; i < e.targets.size() && i < e.specs->size(); ++i)
            e.targets[i].removed = !target_legal((*e.specs)[i], e.targets[i].ref, e.controller,
                                                 e.source, e.cid);
    }
    bool all_removed = !e.targets.empty();
    for (const Target& t : e.targets)
        if (!t.removed) all_removed = false;
    auto remove_entry = [&]() {
        auto it = std::find_if(chain_.begin(), chain_.end(), [&](const Entry& x) { return x.cid == e.cid; });
        if (it != chain_.end()) chain_.erase(it);
    };
    if (all_removed) {
        emit("FIZZLE", C{e.cid});
    } else {
        Ctx ctx;
        ctx.controller = e.controller;
        ctx.source = e.source;
        ctx.it = e.it;
        ctx.targets = &e.targets;
        ctx.specs = e.specs;
        switch (e.kind) {
            case EntryKind::Rite:
                run_effects(obj(e.source).card->abilities[0].effects, ctx);
                break;
            case EntryKind::Unit:
            case EntryKind::Relic:
                remove_entry();
                enter_field(e.source, e.controller, true);
                break;
            case EntryKind::Ability:
            case EntryKind::Trigger:
                if (e.delayed_effects)
                    run_effects(*e.delayed_effects, ctx);
                else
                    run_effects(obj(e.source).card->abilities[static_cast<std::size_t>(e.index - 1)].effects, ctx);
                break;
        }
    }
    remove_entry();
    if (e.kind == EntryKind::Rite || (all_removed && (e.kind == EntryKind::Unit || e.kind == EntryKind::Relic))) {
        Obj& o = obj(e.source);
        place_in_zone(o, Zone::Ash);
        emit("SPENT", O{o.oid}, o.card->id);
    }
}

}  // namespace spiremark
