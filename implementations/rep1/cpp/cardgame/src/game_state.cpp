// Game construction, setup, zones and the layer system.
#include <algorithm>
#include <ostream>

#include "spiremark/game.hpp"

namespace spiremark {

using detail::C;
using detail::O;
using detail::P;
using detail::S;

bool resolve_setup(const MatchSetup& m, const Database& db, GameSetup& out) {
    out.match = m;
    for (int z = 0; z < 5; ++z) {
        for (int p = 0; p < 2; ++p) {
            out.cards[z][p].clear();
            for (const SetupEntry& e : m.zones[z][p]) {
                const Card* c = db.find(e.card_id);
                if (!c) return false;
                for (int i = 0; i < e.count; ++i) out.cards[z][p].push_back(c);
            }
        }
    }
    return true;
}

void Game::emit_line(const std::string& body) {
    out_ << ++seq_ << ' ' << body << '\n';
}

int Game::new_object(const Card* c, int owner) {
    Obj o;
    o.oid = static_cast<int>(objs_.size());
    o.card = c;
    o.owner = owner;
    o.base_ctrl = owner;
    o.last_ctrl = owner;
    o.ctrl = owner;
    objs_.push_back(std::move(o));
    return objs_.back().oid;
}

void Game::sort_canonical(std::vector<int>& v) {
    std::sort(v.begin(), v.end(), [this](int a, int b) {
        const Obj& x = obj(a);
        const Obj& y = obj(b);
        return x.ts != y.ts ? x.ts < y.ts : x.oid < y.oid;
    });
}

void Game::remove_from_zone(Obj& o) {
    auto erase_from = [&](std::vector<int>& v) {
        auto it = std::find(v.begin(), v.end(), o.oid);
        if (it != v.end()) v.erase(it);
    };
    switch (o.zone) {
        case Zone::Vault: {
            auto& d = vault_[o.owner];
            if (!d.empty() && d.front() == o.oid) d.pop_front();
            else {
                auto it = std::find(d.begin(), d.end(), o.oid);
                if (it != d.end()) d.erase(it);
            }
            break;
        }
        case Zone::Hand: erase_from(hand_[o.owner]); break;
        case Zone::Ash: erase_from(ash_[o.owner]); break;
        case Zone::Rift: erase_from(rift_[o.owner]); break;
        case Zone::Field: erase_from(field_); break;
        case Zone::Stack: break;
    }
    touch();
}

void Game::place_in_zone(Obj& o, Zone z) {
    o.zone = z;
    switch (z) {
        case Zone::Vault: vault_[o.owner].push_back(o.oid); break;
        case Zone::Hand: hand_[o.owner].push_back(o.oid); break;
        case Zone::Ash: ash_[o.owner].push_back(o.oid); break;
        case Zone::Rift: rift_[o.owner].push_back(o.oid); break;
        case Zone::Field: field_.push_back(o.oid); break;
        case Zone::Stack: break;
    }
    touch();
}

Game::Game(const Database& db, const GameSetup& s, std::ostream& out)
    : out_(out), db_(db), cfg_(s.match), rng_(s.match.seed) {
    objs_.emplace_back();  // slot 0 is unused
    setup(s);
}

void Game::setup(const GameSetup& s) {
    active_ = cfg_.first;
    for (int p = 0; p < 2; ++p) {
        spire_[p] = cfg_.spire;
        cap_[p] = cfg_.cap[p];
    }
    // Step 5: oids; step 6: Field placement in ascending oid order.
    std::vector<int> fielded;
    for (int p = 0; p < 2; ++p) {
        for (int z = 0; z < 5; ++z) {
            for (const Card* c : s.cards[z][p]) {
                int oid = new_object(c, p);
                Obj& o = obj(oid);
                switch (z) {
                    case 0: place_in_zone(o, Zone::Vault); break;
                    case 1: place_in_zone(o, Zone::Hand); break;
                    case 2: fielded.push_back(oid); break;
                    case 3: place_in_zone(o, Zone::Ash); break;
                    case 4: place_in_zone(o, Zone::Rift); break;
                }
            }
        }
    }
    for (int oid : fielded) {
        Obj& o = obj(oid);
        o.ts = next_ts_++;
        o.since = 0;
        o.base_ctrl = o.owner;
        place_in_zone(o, Zone::Field);
        create_aura_records(o);
    }
    touch();

    emit("GAME-START", P{active_});
    if (cfg_.shuffle) {
        rng_.shuffle(vault_[0]);
        emit("SHUFFLE", P{0});
        rng_.shuffle(vault_[1]);
        emit("SHUFFLE", P{1});
    }
    no_triggers_ = true;
    draw_cards(active_, cfg_.opening);
    draw_cards(opponent(active_), cfg_.opening);
    no_triggers_ = false;
    settle();
    if (over_) return;
    next_step_ = Step::Dawn;
    run();
}

void Game::finish() {
    if (!over_) emit("RESULT", "pending", "none");
}

// ---------------------------------------------------------------- layers --

void Game::create_aura_records(Obj& o) {
    for (const Ability& ab : o.card->abilities) {
        if (ab.kind != Ability::Kind::Aura) continue;
        Record r;
        r.eid = next_eid_++;
        r.ts = next_ts_++;
        r.source = o.oid;
        r.controller = o.base_ctrl;
        r.aura = true;
        r.ability = &ab;
        records_.push_back(std::move(r));
    }
    touch();
}

int Game::ctrl_of(int oid) {
    ensure_derived();
    const Obj& o = obj(oid);
    if (o.zone == Zone::Field) return o.ctrl;
    return o.last_ctrl;
}

std::int64_t Game::cur_edge(int oid) {
    ensure_derived();
    const Obj& o = obj(oid);
    return o.zone == Zone::Field ? o.edge : o.card->edge;
}

std::int64_t Game::cur_core(int oid) {
    ensure_derived();
    const Obj& o = obj(oid);
    return o.zone == Zone::Field ? o.core : o.card->core;
}

bool Game::has_kw(int oid, Kw k) {
    ensure_derived();
    const Obj& o = obj(oid);
    std::uint32_t mask = o.zone == Zone::Field ? o.kw_mask : o.card->kw_mask;
    return (mask >> static_cast<int>(k)) & 1u;
}

std::int64_t Game::plating_of(int oid) {
    ensure_derived();
    const Obj& o = obj(oid);
    return o.zone == Zone::Field ? o.plating : o.card->plating_sum;
}

std::string Game::kwlist(const Obj& o) const {
    std::vector<std::string> names;
    std::uint32_t mask = o.zone == Zone::Field ? o.kw_mask : o.card->kw_mask;
    for (int k = 0; k < static_cast<int>(Kw::Count); ++k) {
        if (!((mask >> k) & 1u)) continue;
        Kw kw = static_cast<Kw>(k);
        if (kw == Kw::Plating) {
            std::int64_t pl = o.zone == Zone::Field ? o.plating : o.card->plating_sum;
            names.push_back("plating:" + std::to_string(pl));
        } else {
            names.push_back(keyword_name(kw));
        }
    }
    if (names.empty()) return "-";
    std::sort(names.begin(), names.end());
    std::string s;
    for (std::size_t i = 0; i < names.size(); ++i) s += (i ? "," : "") + names[i];
    return s;
}

void Game::eval_statics(const std::vector<Static>& sts, Ctx& ctx, bool active, Record& rec) {
    for (const Static& st : sts) {
        using K = Static::Kind;
        if (st.kind == K::When) {
            bool c = eval_cond(st.cond, ctx);
            eval_statics(st.body, ctx, active && c, rec);
            continue;
        }
        AuraOut out;
        out.active = active;
        switch (st.kind) {
            case K::Modify: out.kind = RecKind::Modify; break;
            case K::Setbody: out.kind = RecKind::Setbody; break;
            case K::Swapstats: out.kind = RecKind::Swapstats; break;
            case K::Grant: out.kind = RecKind::Grant; break;
            case K::Cheaper: out.kind = RecKind::Cheaper; break;
            case K::When: break;
        }
        if (st.kind == K::Modify || st.kind == K::Setbody) {
            out.a = eval_amount(st.a, ctx);
            out.b = eval_amount(st.b, ctx);
        }
        if (st.kind == K::Grant) out.kw = st.kwspec;
        if (st.kind == K::Cheaper) {
            out.cheaper = st.n;
            out.card_filters = &st.card_filters;
        } else if (active) {
            std::vector<int> sel = eval_objs(st.sel, ctx);
            for (int oid : sel)
                if (obj(oid).zone == Zone::Field) out.objs.push_back(oid);
        }
        rec.outs.push_back(std::move(out));
    }
}

void Game::derive() {
    deriving_ = true;
    dirty_ = false;

    // Layer 1: controllers.
    for (int oid : field_) {
        Obj& o = obj(oid);
        o.ctrl = o.base_ctrl;
        o.stripped = false;
    }
    for (const Record& r : records_) {
        if (r.aura || r.kind != RecKind::Control) continue;
        for (int oid : r.affected)
            if (on_field(oid)) obj(oid).ctrl = r.controller;
    }
    // Which objects are stripped.
    for (const Record& r : records_) {
        if (r.aura || r.kind != RecKind::Strip) continue;
        for (int oid : r.affected)
            if (on_field(oid)) obj(oid).stripped = true;
    }
    // Aura records.
    cheaper_.clear();
    for (Record& r : records_) {
        if (!r.aura) continue;
        r.outs.clear();
        const Obj& src = obj(r.source);
        bool active = src.zone == Zone::Field && !src.stripped;
        r.eff_controller = src.zone == Zone::Field ? src.ctrl : src.last_ctrl;
        Ctx ctx;
        ctx.controller = r.eff_controller;
        ctx.source = r.source;
        ctx.aura = true;
        eval_statics(r.ability->statics, ctx, active, r);
        for (const AuraOut& o : r.outs)
            if (o.kind == RecKind::Cheaper && o.active)
                cheaper_.push_back({r.eff_controller, o.cheaper, o.card_filters});
    }
    // Layer 2: keywords.
    for (int oid : field_) {
        Obj& o = obj(oid);
        o.kw_mask = o.card->kw_mask;
        o.plating = o.card->plating_sum;
        o.edge = o.card->edge;
        o.core = o.card->core;
    }
    auto grant = [&](int oid, const KwSpec& k) {
        Obj& o = obj(oid);
        o.kw_mask |= 1u << static_cast<int>(k.kw);
        if (k.kw == Kw::Plating) o.plating += k.value;
    };
    for (const Record& r : records_) {
        if (r.aura) {
            for (const AuraOut& o : r.outs)
                if (o.active && o.kind == RecKind::Grant)
                    for (int oid : o.objs) grant(oid, o.kw);
        } else if (r.kind == RecKind::Grant) {
            for (int oid : r.affected)
                if (on_field(oid)) grant(oid, r.kw);
        } else if (r.kind == RecKind::Strip) {
            for (int oid : r.affected)
                if (on_field(oid)) {
                    obj(oid).kw_mask = 0;
                    obj(oid).plating = 0;
                }
        }
    }
    // Layers 3 and 4.
    auto apply_layer = [&](RecKind kind) {
        for (const Record& r : records_) {
            auto apply = [&](int oid, std::int64_t a, std::int64_t b) {
                Obj& o = obj(oid);
                if (kind == RecKind::Setbody) { o.edge = a; o.core = b; }
                else if (kind == RecKind::Modify) { o.edge += a; o.core += b; }
                else if (kind == RecKind::Swapstats) std::swap(o.edge, o.core);
            };
            if (r.aura) {
                for (const AuraOut& o : r.outs)
                    if (o.active && o.kind == kind)
                        for (int oid : o.objs) apply(oid, o.a, o.b);
            } else if (r.kind == kind) {
                for (int oid : r.affected)
                    if (on_field(oid)) apply(oid, r.a, r.b);
            }
        }
    };
    apply_layer(RecKind::Setbody);
    apply_layer(RecKind::Modify);
    for (int oid : field_) {
        Obj& o = obj(oid);
        o.edge += o.counters;
        o.core += o.counters;
    }
    apply_layer(RecKind::Swapstats);
    deriving_ = false;
}

std::int64_t Game::effective_cost(const Card& c, int player) {
    ensure_derived();
    std::int64_t cost = c.cost;
    for (const CheaperRec& r : cheaper_) {
        if (r.controller != player) continue;
        bool ok = true;
        for (const Filter& f : *r.filters) {
            switch (f.kind) {
                case Filter::Kind::Type: ok = c.type == f.type; break;
                case Filter::Kind::Tag: ok = c.has_tag(f.tag); break;
                case Filter::Kind::Cost: ok = compare(f.cmp, c.cost, f.n); break;
                default: ok = false; break;
            }
            if (!ok) break;
        }
        if (ok) cost -= r.amount;
    }
    return cost < 0 ? 0 : cost;
}

}  // namespace spiremark
