// Filters, selectors, amounts, conditions, the effect interpreter and the
// state-changing primitives of SPEC.md section 17.
#include <algorithm>
#include <ostream>
#include <set>

#include "spiremark/game.hpp"

namespace spiremark {

using detail::C;
using detail::O;
using detail::P;
using detail::S;

// ------------------------------------------------------------------ filters --

bool Game::match_filter(const Obj& o, const Filter& f, const Ctx& ctx) {
    using K = Filter::Kind;
    switch (f.kind) {
        case K::Kw: return o.card->has_printed_kw(f.kw);
        case K::NoKw: return !o.card->has_printed_kw(f.kw);
        case K::Tag: return o.card->has_tag(f.tag);
        case K::Type: return o.card->type == f.type;
        case K::Cost: return compare(f.cmp, o.card->cost, f.n);
        case K::Edge: return compare(f.cmp, base_edge(o), f.n);
        case K::Core: return compare(f.cmp, base_core(o), f.n);
        case K::Wounded: return o.zone == Zone::Field && o.wounds >= 1;
        case K::Ready: return o.zone == Zone::Field && !o.exhausted;
        case K::Exhausted: return o.zone == Zone::Field && o.exhausted;
        case K::Settling: return is_settling(o);
        case K::Attacking: return o.zone == Zone::Field && o.attacking;
        case K::Blocking: return o.zone == Zone::Field && o.blocking;
        case K::Mine: return (o.zone == Zone::Field ? o.ctrl : o.owner) == ctx.controller;
        case K::Enemy: return (o.zone == Zone::Field ? o.ctrl : o.owner) != ctx.controller;
        case K::Other: return o.oid != ctx.source;
        case K::Not: return !match_filter(o, f.inner[0], ctx);
    }
    return false;
}

bool Game::match_filters(const Obj& o, const std::vector<Filter>& fs, const Ctx& ctx) {
    for (const Filter& f : fs)
        if (!match_filter(o, f, ctx)) return false;
    return true;
}

// ---------------------------------------------------------------- selectors --

std::vector<int> Game::eval_objs(const Selector& s, Ctx& ctx) {
    using K = Selector::Kind;
    ensure_derived();
    std::vector<int> out;
    switch (s.kind) {
        case K::Self:
            out.push_back(ctx.source);
            return out;
        case K::It:
            if (ctx.it.is_object()) out.push_back(static_cast<int>(ctx.it.id));
            return out;
        case K::That:
            if (ctx.that) out.push_back(ctx.that);
            return out;
        case K::Target:
            if (ctx.targets && s.n >= 1 && static_cast<std::size_t>(s.n) <= ctx.targets->size()) {
                const Target& t = (*ctx.targets)[static_cast<std::size_t>(s.n - 1)];
                if (!t.removed && t.ref.is_object()) out.push_back(static_cast<int>(t.ref.id));
            }
            return out;
        case K::Units:
        case K::Relics:
        case K::RandomUnit: {
            CardType want = s.kind == K::Relics ? CardType::Relic : CardType::Unit;
            for (int oid : field_) {
                const Obj& o = obj(oid);
                if (o.card->type != want) continue;
                if (s.scope == Scope::Yours && o.ctrl != ctx.controller) continue;
                if (s.scope == Scope::Theirs && o.ctrl == ctx.controller) continue;
                if (!match_filters(o, s.filters, ctx)) continue;
                out.push_back(oid);
            }
            if (s.kind == K::RandomUnit) {
                if (out.empty()) return out;
                int pick = out[static_cast<std::size_t>(rng_.below(out.size()))];
                out.assign(1, pick);
            }
            return out;
        }
        case K::Cards: {
            for (int p = 0; p < 2; ++p) {
                if (s.scope == Scope::Yours && p != ctx.controller) continue;
                if (s.scope == Scope::Theirs && p == ctx.controller) continue;
                auto consider = [&](int oid) {
                    if (match_filters(obj(oid), s.filters, ctx)) out.push_back(oid);
                };
                switch (s.zone) {
                    case CardZone::Hand: for (int oid : hand_[p]) consider(oid); break;
                    case CardZone::Ash: for (int oid : ash_[p]) consider(oid); break;
                    case CardZone::Rift: for (int oid : rift_[p]) consider(oid); break;
                    case CardZone::Vault: for (int oid : vault_[p]) consider(oid); break;
                }
            }
            sort_canonical(out);
            return out;
        }
        default:
            return out;
    }
}

std::vector<int> Game::eval_players(const Selector& s, Ctx& ctx) {
    using K = Selector::Kind;
    std::vector<int> out;
    switch (s.kind) {
        case K::You: out.push_back(ctx.controller); break;
        case K::Foe: out.push_back(opponent(ctx.controller)); break;
        case K::Both: out = {0, 1}; break;
        case K::Target:
            if (ctx.targets && s.n >= 1 && static_cast<std::size_t>(s.n) <= ctx.targets->size()) {
                const Target& t = (*ctx.targets)[static_cast<std::size_t>(s.n - 1)];
                if (!t.removed && t.ref.is_player()) out.push_back(static_cast<int>(t.ref.id));
            }
            break;
        case K::OwnerOf: {
            const Selector& inner = s.inner[0];
            if (inner.kind == K::Target) {
                if (ctx.targets && inner.n >= 1 &&
                    static_cast<std::size_t>(inner.n) <= ctx.targets->size()) {
                    const Target& t = (*ctx.targets)[static_cast<std::size_t>(inner.n - 1)];
                    if (t.removed) break;
                    if (t.ref.is_player()) { out.push_back(static_cast<int>(t.ref.id)); break; }
                }
            }
            std::set<int> owners;
            for (int oid : eval_objs(inner, ctx)) owners.insert(obj(oid).owner);
            out.assign(owners.begin(), owners.end());
            break;
        }
        default: break;
    }
    return out;
}

std::vector<Ref> Game::eval_dsel(const Selector& s, Ctx& ctx) {
    using K = Selector::Kind;
    std::vector<Ref> out;
    if (s.kind == K::You || s.kind == K::Foe || s.kind == K::Both || s.kind == K::OwnerOf) {
        for (int p : eval_players(s, ctx)) out.push_back(Ref::player(p));
        return out;
    }
    if (s.kind == K::Target) {
        if (ctx.targets && s.n >= 1 && static_cast<std::size_t>(s.n) <= ctx.targets->size()) {
            const Target& t = (*ctx.targets)[static_cast<std::size_t>(s.n - 1)];
            if (!t.removed && (t.ref.is_player() || t.ref.is_object())) out.push_back(t.ref);
        }
        return out;
    }
    for (int oid : eval_objs(s, ctx)) out.push_back(Ref::object(static_cast<std::uint64_t>(oid)));
    return out;
}

std::int64_t Game::eval_amount(const Amount& a, Ctx& ctx) {
    using K = Amount::Kind;
    switch (a.kind) {
        case K::Literal: return a.value;
        case K::Count: return static_cast<std::int64_t>(eval_objs(a.sel, ctx).size());
        case K::Hand:
        case K::Ash:
        case K::Vault: {
            std::int64_t total = 0;
            for (int p : eval_players(a.sel, ctx)) {
                total += static_cast<std::int64_t>(a.kind == K::Hand ? hand_[p].size()
                                                  : a.kind == K::Ash ? ash_[p].size()
                                                                     : vault_[p].size());
            }
            return total;
        }
        case K::Edge:
        case K::Core: {
            std::int64_t total = 0;
            for (int oid : eval_objs(a.sel, ctx)) {
                const Obj& o = obj(oid);
                if (ctx.aura) total += a.kind == K::Edge ? base_edge(o) : base_core(o);
                else total += a.kind == K::Edge ? cur_edge(oid) : cur_core(oid);
            }
            return total;
        }
        case K::Wounds: {
            std::int64_t total = 0;
            for (int oid : eval_objs(a.sel, ctx)) total += obj(oid).wounds;
            return total;
        }
    }
    return 0;
}

bool Game::eval_cond(const Condition& c, Ctx& ctx) {
    using K = Condition::Kind;
    switch (c.kind) {
        case K::MyTurn: return active_ == ctx.controller;
        case K::Count: return compare(c.cmp, static_cast<std::int64_t>(eval_objs(c.sel, ctx).size()), c.n);
        case K::Spire:
        case K::Hand:
        case K::Ash:
        case K::Vault:
        case K::Ember: {
            std::int64_t total = 0;
            for (int p : eval_players(c.sel, ctx)) {
                switch (c.kind) {
                    case K::Spire: total += spire_[p]; break;
                    case K::Hand: total += static_cast<std::int64_t>(hand_[p].size()); break;
                    case K::Ash: total += static_cast<std::int64_t>(ash_[p].size()); break;
                    case K::Vault: total += static_cast<std::int64_t>(vault_[p].size()); break;
                    default: total += ember_[p]; break;
                }
            }
            return compare(c.cmp, total, c.n);
        }
        case K::And:
            for (const Condition& k : c.kids)
                if (!eval_cond(k, ctx)) return false;
            return true;
        case K::Or:
            for (const Condition& k : c.kids)
                if (eval_cond(k, ctx)) return true;
            return false;
        case K::Not: return !eval_cond(c.kids[0], ctx);
    }
    return false;
}

// ------------------------------------------------------------------ effects --

void Game::run_effects(const std::vector<Effect>& es, Ctx& ctx) {
    for (const Effect& e : es) run_effect(e, ctx);
}

void Game::run_effect(const Effect& e, Ctx& ctx) {
    using K = Effect::Kind;
    switch (e.kind) {
        case K::Nothing: return;
        case K::Damage: {
            std::int64_t n = eval_amount(e.a, ctx);
            if (n <= 0) return;
            for (Ref t : eval_dsel(e.sel, ctx))
                deal_damage(Ref::object(static_cast<std::uint64_t>(ctx.source)), t, n);
            return;
        }
        case K::Destroy:
            for (int oid : eval_objs(e.sel, ctx))
                if (on_field(oid)) destroy_obj(oid);
            return;
        case K::Sacrifice:
            for (int oid : eval_objs(e.sel, ctx))
                if (on_field(oid)) sacrifice_obj(oid);
            return;
        case K::Exile:
            for (int oid : eval_objs(e.sel, ctx)) exile_obj(oid);
            return;
        case K::Bounce:
            for (int oid : eval_objs(e.sel, ctx))
                if (on_field(oid)) bounce_obj(oid);
            return;
        case K::Draw: {
            std::int64_t n = eval_amount(e.a, ctx);
            if (n <= 0) return;
            for (int p : eval_players(e.sel, ctx)) draw_cards(p, n);
            return;
        }
        case K::Discard: {
            std::int64_t n = eval_amount(e.a, ctx);
            if (n <= 0) return;
            for (int p : eval_players(e.sel, ctx))
                for (std::int64_t i = 0; i < n && !hand_[p].empty(); ++i) discard_one(p);
            return;
        }
        case K::Mill: {
            std::int64_t n = eval_amount(e.a, ctx);
            if (n <= 0) return;
            for (int p : eval_players(e.sel, ctx))
                for (std::int64_t i = 0; i < n && !vault_[p].empty(); ++i) mill_one(p);
            return;
        }
        case K::Spire: {
            std::int64_t n = eval_amount(e.a, ctx);
            for (int p : eval_players(e.sel, ctx)) change_spire(p, n);
            return;
        }
        case K::Ember: {
            std::int64_t n = eval_amount(e.a, ctx);
            if (n <= 0) return;
            for (int p : eval_players(e.sel, ctx)) gain_ember(p, n);
            return;
        }
        case K::Cap: {
            std::int64_t n = eval_amount(e.a, ctx);
            if (n <= 0) return;
            for (int p : eval_players(e.sel, ctx)) raise_cap(p, n);
            return;
        }
        case K::Shield: {
            std::int64_t n = eval_amount(e.a, ctx);
            if (n <= 0) return;
            for (int p : eval_players(e.sel, ctx)) {
                shield_[p] += n;
                emit("SHIELD", P{p}, n, shield_[p]);
            }
            return;
        }
        case K::Modify:
        case K::Setbody:
        case K::Swapstats:
        case K::Grant:
        case K::Strip:
        case K::Control:
            make_record(e, ctx);
            return;
        case K::Counters: {
            std::int64_t n = eval_amount(e.a, ctx);
            for (int oid : eval_objs(e.sel, ctx))
                if (on_field(oid)) add_counters(oid, n);
            return;
        }
        case K::Ready:
            for (int oid : eval_objs(e.sel, ctx))
                if (on_field(oid)) set_exhausted(oid, false);
            return;
        case K::Exhaust:
            for (int oid : eval_objs(e.sel, ctx))
                if (on_field(oid)) set_exhausted(oid, true);
            return;
        case K::Doom:
            for (int oid : eval_objs(e.sel, ctx))
                if (on_field(oid) && obj(oid).card->type == CardType::Unit) doom_obj(oid);
            return;
        case K::Ward: {
            std::int64_t n = eval_amount(e.a, ctx);
            if (n <= 0) return;
            for (int oid : eval_objs(e.sel, ctx)) {
                if (!on_field(oid)) continue;
                obj(oid).ward += n;
                emit("WARD", O{oid}, n, obj(oid).ward);
            }
            return;
        }
        case K::Summon:
        case K::Conjure:
            create_objects(e, ctx);
            return;
        case K::Reanimate:
            for (int oid : eval_objs(e.sel, ctx)) {
                Obj& o = obj(oid);
                if (o.zone != Zone::Ash || o.card->type != CardType::Unit) continue;
                remove_from_zone(o);
                enter_field(oid, ctx.controller, true);
            }
            return;
        case K::Recall:
            for (int oid : eval_objs(e.sel, ctx)) {
                Obj& o = obj(oid);
                if (o.zone != Zone::Ash) continue;
                remove_from_zone(o);
                place_in_zone(o, Zone::Hand);
                emit("RECALL", O{oid}, o.card->id);
            }
            return;
        case K::Negate: {
            const Selector& s = e.sel;
            if (ctx.targets && s.n >= 1 && static_cast<std::size_t>(s.n) <= ctx.targets->size()) {
                const Target& t = (*ctx.targets)[static_cast<std::size_t>(s.n - 1)];
                if (!t.removed && t.ref.is_entry()) negate_entry(static_cast<int>(t.ref.id));
            }
            return;
        }
        case K::Dig:
            for (int p : eval_players(e.sel, ctx)) do_dig(e, p, ctx);
            return;
        case K::Delay:
            make_delay(e, ctx);
            return;
        case K::If:
            if (eval_cond(e.cond, ctx)) run_effects(e.body, ctx);
            else run_effects(e.orelse, ctx);
            return;
        case K::Each: {
            std::vector<int> list = eval_objs(e.sel, ctx);
            sort_canonical(list);
            std::vector<Zone> zones;
            for (int oid : list) zones.push_back(obj(oid).zone);
            int saved = ctx.that;
            for (std::size_t i = 0; i < list.size(); ++i) {
                if (obj(list[i]).zone != zones[i]) continue;
                ctx.that = list[i];
                run_effects(e.body, ctx);
            }
            ctx.that = saved;
            return;
        }
        case K::Repeat: {
            std::int64_t n = eval_amount(e.a, ctx);
            for (std::int64_t i = 0; i < n; ++i) run_effects(e.body, ctx);
            return;
        }
    }
}

void Game::make_record(const Effect& e, Ctx& ctx) {
    using K = Effect::Kind;
    Record r;
    r.controller = ctx.controller;
    r.source = ctx.source;
    if (e.kind == K::Modify || e.kind == K::Setbody) {
        r.a = eval_amount(e.a, ctx);
        r.b = eval_amount(e.b, ctx);
    }
    std::vector<int> sel = eval_objs(e.sel, ctx);
    std::vector<int> affected;
    for (int oid : sel)
        if (on_field(oid)) affected.push_back(oid);
    sort_canonical(affected);
    if (e.kind == K::Control) {
        make_control(ctx, affected);
        return;
    }
    r.eid = next_eid_++;
    r.ts = next_ts_++;
    r.affected = affected;
    switch (e.kind) {
        case K::Modify: r.kind = RecKind::Modify; break;
        case K::Setbody: r.kind = RecKind::Setbody; break;
        case K::Swapstats: r.kind = RecKind::Swapstats; break;
        case K::Grant: r.kind = RecKind::Grant; r.kw = e.kwspec; break;
        default: r.kind = RecKind::Strip; break;
    }
    records_.push_back(r);
    touch();
    for (int oid : affected) {
        switch (r.kind) {
            case RecKind::Modify: emit("BUFF", O{oid}, r.a, r.b); break;
            case RecKind::Setbody: emit("SETBODY", O{oid}, r.a, r.b); break;
            case RecKind::Swapstats: emit("SWAP", O{oid}); break;
            case RecKind::Grant: emit("GRANT", O{oid}, r.kw.render()); break;
            default: emit("STRIP", O{oid}); break;
        }
    }
}

void Game::make_control(Ctx& ctx, const std::vector<int>& affected) {
    Record r;
    r.controller = ctx.controller;
    r.source = ctx.source;
    r.kind = RecKind::Control;
    r.eid = next_eid_++;
    r.ts = next_ts_++;
    r.affected = affected;
    records_.push_back(r);
    touch();
    for (int oid : affected) {
        Obj& o = obj(oid);
        o.since = turn_;
        if (o.card->type == CardType::Unit) remove_from_combat(oid);
    }
    for (int oid : affected) emit("CONTROL", O{oid}, P{ctx.controller});
}

void Game::make_delay(const Effect& e, Ctx& ctx) {
    Delayed d;
    d.ts = next_ts_++;
    d.controller = ctx.controller;
    d.source = ctx.source;
    d.when = e.when;
    if (ctx.targets) {
        d.targets = *ctx.targets;
        for (Target& t : d.targets) t.removed = false;
    }
    d.specs = ctx.specs;
    d.effects = &e.body;
    delayed_.push_back(std::move(d));
    emit("DELAY", P{ctx.controller}, when_name(e.when));
}

void Game::create_objects(const Effect& e, Ctx& ctx) {
    std::int64_t n = eval_amount(e.a, ctx);
    if (n <= 0) return;
    const Card* card = db_.find(e.card);
    if (!card) return;
    bool summon = e.kind == Effect::Kind::Summon;
    for (int p : eval_players(e.sel, ctx)) {
        for (std::int64_t i = 0; i < n; ++i) {
            int oid = new_object(card, p);
            emit("CREATE", O{oid}, card->id, summon ? "field" : "hand");
            if (summon) enter_field(oid, p, true);
            else place_in_zone(obj(oid), Zone::Hand);
        }
    }
}

void Game::do_dig(const Effect& e, int p, Ctx& ctx) {
    std::vector<int> look;
    for (std::int64_t i = 0; i < e.k && !vault_[p].empty(); ++i) {
        look.push_back(vault_[p].front());
        vault_[p].pop_front();
    }
    touch();
    int found = -1;
    for (std::size_t i = 0; i < look.size(); ++i) {
        if (match_filters(obj(look[i]), e.filters, ctx)) {
            found = static_cast<int>(i);
            break;
        }
    }
    if (found >= 0) {
        int oid = look[static_cast<std::size_t>(found)];
        look.erase(look.begin() + found);
        Obj& o = obj(oid);
        o.zone = Zone::Stack;  // briefly in limbo
        place_in_zone(o, Zone::Hand);
        emit("DIG", P{p}, O{oid}, o.card->id);
    } else {
        emit("DIG-MISS", P{p});
    }
    for (int oid : look) {
        obj(oid).zone = Zone::Stack;
        place_in_zone(obj(oid), Zone::Vault);
        emit("BOTTOM", P{p}, O{oid}, obj(oid).card->id);
    }
}

void Game::negate_entry(int cid) {
    auto it = std::find_if(chain_.begin(), chain_.end(), [&](const Entry& e) { return e.cid == cid; });
    if (it == chain_.end()) return;
    Entry e = *it;
    chain_.erase(it);
    emit("NEGATE", C{cid});
    if (e.kind == EntryKind::Rite || e.kind == EntryKind::Unit || e.kind == EntryKind::Relic) {
        Obj& o = obj(e.source);
        place_in_zone(o, Zone::Ash);
        emit("SPENT", O{o.oid}, o.card->id);
    }
}

// ---------------------------------------------------------------- primitives --

void Game::deal_damage(Ref src, Ref dst, std::int64_t n) {
    if (n <= 0) return;
    ensure_derived();
    if (dst.is_object()) {
        int oid = static_cast<int>(dst.id);
        Obj& o = obj(oid);
        if (o.zone != Zone::Field || o.card->type == CardType::Relic) return;
    }
    std::int64_t rem = n;
    if (dst.is_object()) {
        std::int64_t pl = plating_of(static_cast<int>(dst.id));
        if (pl > 0) rem = std::max<std::int64_t>(0, rem - pl);
        Obj& o = obj(static_cast<int>(dst.id));
        std::int64_t u = std::min(o.ward, rem);
        o.ward -= u;
        rem -= u;
    } else {
        int p = static_cast<int>(dst.id);
        std::int64_t u = std::min(shield_[p], rem);
        shield_[p] -= u;
        rem -= u;
    }
    if (rem < n) emit("PREVENT", dst, n - rem);
    if (rem == 0) return;
    emit("DAMAGE", src, dst, rem);
    if (dst.is_object()) {
        obj(static_cast<int>(dst.id)).wounds += rem;
        touch();
    } else {
        change_spire(static_cast<int>(dst.id), -rem);
    }
    bool src_unit_on_field = src.is_object() && on_field(static_cast<int>(src.id)) &&
                             obj(static_cast<int>(src.id)).card->type == CardType::Unit;
    if (dst.is_object() && src_unit_on_field && has_kw(static_cast<int>(src.id), Kw::Venom))
        doom_obj(static_cast<int>(dst.id));
    if (src_unit_on_field && has_kw(static_cast<int>(src.id), Kw::Siphon))
        change_spire(ctrl_of(static_cast<int>(src.id)), rem);
    if (dst.is_object() && on_field(static_cast<int>(dst.id)))
        collect_self(Event::Damaged, static_cast<int>(dst.id), src, false, 0);
    if (src.is_object() && on_field(static_cast<int>(src.id)))
        collect_self(Event::DealsDamage, static_cast<int>(src.id), dst, false, 0);
}

void Game::remove_from_combat(int oid) {
    Obj& o = obj(oid);
    if (o.blocking) {
        if (o.blocking_oid) {
            auto& bl = obj(o.blocking_oid).blockers;
            bl.erase(std::remove(bl.begin(), bl.end(), oid), bl.end());
        }
        o.blocking = false;
        o.blocking_oid = 0;
    }
    if (o.attacking) {
        for (int b : o.blockers) {
            obj(b).blocking = false;
            obj(b).blocking_oid = 0;
        }
        o.blockers.clear();
        o.attacking = false;
    }
    touch();
}

void Game::leave_field(int oid, const char* verb, bool is_death, bool fire_leave) {
    // Common tail of destroy / sacrifice (17.3, 17.4).
    Obj& o = obj(oid);
    int ctrl = ctrl_of(oid);
    o.last_ctrl = ctrl;
    remove_from_combat(oid);
    remove_from_zone(o);
    place_in_zone(o, Zone::Ash);
    emit(verb, O{oid}, o.card->id);
    records_.erase(std::remove_if(records_.begin(), records_.end(),
                                  [&](const Record& r) { return r.aura && r.source == oid; }),
                   records_.end());
    o.exhausted = false;
    o.doomed = false;
    o.wounds = o.counters = o.ward = 0;
    o.tenacity_used = false;
    o.once.clear();
    o.blocked = false;
    touch();
    collect_death(oid, ctrl, is_death, fire_leave);
}

void Game::destroy_obj(int oid) {
    ensure_derived();
    Obj& o = obj(oid);
    if (has_kw(oid, Kw::Tenacity) && !o.tenacity_used) {
        o.tenacity_used = true;
        o.wounds = 0;
        o.doomed = false;
        touch();
        emit("TENACITY", O{oid});
        return;
    }
    leave_field(oid, "DESTROY", true, true);
}

void Game::sacrifice_obj(int oid) { leave_field(oid, "SACRIFICE", true, true); }

void Game::exile_obj(int oid) {
    Obj& o = obj(oid);
    const char* zone = nullptr;
    switch (o.zone) {
        case Zone::Field: zone = "field"; break;
        case Zone::Hand: zone = "hand"; break;
        case Zone::Ash: zone = "ash"; break;
        case Zone::Vault: zone = "vault"; break;
        case Zone::Rift: zone = "rift"; break;
        case Zone::Stack: return;
    }
    bool from_field = o.zone == Zone::Field;
    int ctrl = 0;
    if (from_field) {
        ctrl = ctrl_of(oid);
        o.last_ctrl = ctrl;
        remove_from_combat(oid);
    }
    remove_from_zone(o);
    place_in_zone(o, Zone::Rift);
    emit("EXILE", O{oid}, o.card->id, zone);
    if (from_field) {
        records_.erase(std::remove_if(records_.begin(), records_.end(),
                                      [&](const Record& r) { return r.aura && r.source == oid; }),
                       records_.end());
        o.exhausted = false;
        o.doomed = false;
        o.wounds = o.counters = o.ward = 0;
        o.tenacity_used = false;
        o.once.clear();
        o.blocked = false;
        touch();
        collect_death(oid, ctrl, false, true);
    }
}

void Game::bounce_obj(int oid) {
    Obj& o = obj(oid);
    int ctrl = ctrl_of(oid);
    o.last_ctrl = ctrl;
    remove_from_combat(oid);
    remove_from_zone(o);
    place_in_zone(o, Zone::Hand);
    emit("BOUNCE", O{oid}, o.card->id);
    records_.erase(std::remove_if(records_.begin(), records_.end(),
                                  [&](const Record& r) { return r.aura && r.source == oid; }),
                   records_.end());
    o.exhausted = false;
    o.doomed = false;
    o.wounds = o.counters = o.ward = 0;
    o.tenacity_used = false;
    o.once.clear();
    o.blocked = false;
    touch();
    collect_death(oid, ctrl, false, true);
}

bool Game::draw_one(int p) {
    if (vault_[p].empty()) {
        emit("DRAW-EMPTY", P{p});
        if (loss_reason_[p].empty()) loss_reason_[p] = "vault";
        return false;
    }
    int oid = vault_[p].front();
    Obj& o = obj(oid);
    remove_from_zone(o);
    place_in_zone(o, Zone::Hand);
    emit("DRAW", P{p}, O{oid}, o.card->id);
    if (!no_triggers_) collect_all(Event::YouDraw, p, true, Ref::object(static_cast<std::uint64_t>(oid)));
    return true;
}

void Game::draw_cards(int p, std::int64_t n) {
    for (std::int64_t i = 0; i < n; ++i)
        if (!draw_one(p)) break;
}

void Game::discard_one(int p) {
    if (hand_[p].empty()) return;
    int oid = hand_[p].front();
    Obj& o = obj(oid);
    remove_from_zone(o);
    place_in_zone(o, Zone::Ash);
    emit("DISCARD", P{p}, O{oid}, o.card->id);
}

void Game::mill_one(int p) {
    if (vault_[p].empty()) return;
    int oid = vault_[p].front();
    Obj& o = obj(oid);
    remove_from_zone(o);
    place_in_zone(o, Zone::Ash);
    emit("MILL", P{p}, O{oid}, o.card->id);
}

void Game::change_spire(int p, std::int64_t delta) {
    if (delta == 0) return;
    spire_[p] += delta;
    touch();
    emit("SPIRE", P{p}, S{delta}, spire_[p]);
    if (delta < 0) collect_spire_loss(p);
}

void Game::gain_ember(int p, std::int64_t n) {
    if (n <= 0) return;
    ember_[p] += n;
    touch();
    emit("EMBERGAIN", P{p}, n, ember_[p]);
}

void Game::raise_cap(int p, std::int64_t n) {
    if (n <= 0) return;
    cap_[p] = std::min<std::int64_t>(cap_[p] + n, cfg_.maxcap);
    touch();
    emit("CAP", P{p}, n, cap_[p]);
}

void Game::add_counters(int oid, std::int64_t delta) {
    Obj& o = obj(oid);
    std::int64_t now = std::max<std::int64_t>(0, o.counters + delta);
    std::int64_t change = now - o.counters;
    if (change == 0) return;
    o.counters = now;
    touch();
    emit("COUNTERS", O{oid}, S{change}, now);
}

void Game::set_exhausted(int oid, bool ex) {
    Obj& o = obj(oid);
    if (o.exhausted == ex) return;
    o.exhausted = ex;
    touch();
    emit(ex ? "EXHAUST" : "READY", O{oid});
}

void Game::doom_obj(int oid) {
    obj(oid).doomed = true;
    touch();
    emit("DOOM", O{oid});
}

void Game::enter_field(int oid, int controller, bool fire) {
    Obj& o = obj(oid);
    if (o.zone != Zone::Stack) remove_from_zone(o);
    o.ts = next_ts_++;
    o.base_ctrl = controller;
    o.exhausted = false;
    o.doomed = false;
    o.wounds = o.counters = o.ward = 0;
    o.attacking = o.blocking = o.blocked = false;
    o.blocking_oid = 0;
    o.blockers.clear();
    o.tenacity_used = false;
    o.once.clear();
    o.since = turn_;
    place_in_zone(o, Zone::Field);
    create_aura_records(o);
    emit("ARRIVE", O{oid}, o.card->id);
    if (fire) collect_arrive(oid);
}

}  // namespace spiremark
