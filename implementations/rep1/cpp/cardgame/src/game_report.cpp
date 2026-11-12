// Inspection blocks: DUMP, LEGAL and VAULT (SPEC.md section 23).
#include <algorithm>
#include <ostream>
#include <sstream>

#include "spiremark/game.hpp"

namespace spiremark {

using detail::P;

namespace {
const char* kind_name_entry(int k) {
    switch (k) {
        case 0: return "rite";
        case 1: return "unit";
        case 2: return "relic";
        case 3: return "ability";
        default: return "trigger";
    }
}
}  // namespace

std::string Game::player_line(int p) const {
    std::ostringstream s;
    s << "player " << player_char(p) << " spire " << spire_[p] << " ember " << ember_[p] << " cap "
      << cap_[p] << " vault " << vault_[p].size() << " hand " << hand_[p].size() << " ash "
      << ash_[p].size() << " rift " << rift_[p].size();
    return s.str();
}

void Game::print_dump() {
    ensure_derived();
    std::ostringstream o;
    o << "STATE BEGIN\n";
    o << "turn " << turn_ << " active " << player_char(active_) << " phase " << step_name(cur_step_)
      << " decision ";
    if (over_) {
        o << "- over";
    } else {
        const char* k = decision_.kind == DecisionKind::Priority ? "priority"
                      : decision_.kind == DecisionKind::Attackers ? "attackers" : "blockers";
        o << player_char(decision_.player) << ' ' << k;
    }
    o << '\n';
    if (over_) o << "result " << result_winner_ << ' ' << result_reason_ << '\n';
    o << player_line(0) << '\n' << player_line(1) << '\n';
    for (int p = 0; p < 2; ++p)
        for (std::size_t i = 0; i < hand_[p].size(); ++i)
            o << "hand " << player_char(p) << ' ' << i + 1 << " #" << hand_[p][i] << ' '
              << obj(hand_[p][i]).card->id << '\n';
    for (int p = 0; p < 2; ++p) {
        for (int oid : field_) {
            const Obj& ob = obj(oid);
            if (ob.ctrl != p) continue;
            o << "field " << player_char(p) << " #" << oid << ' ' << ob.card->id << ' ';
            if (ob.card->type == CardType::Relic) o << "-/-";
            else o << ob.edge << '/' << ob.core;
            o << " w" << ob.wounds << " c" << ob.counters << ' ' << (ob.exhausted ? "exhausted" : "ready")
              << ' ';
            std::vector<std::string> flags;
            if (ob.attacking) flags.push_back("attacking");
            if (ob.blocked) flags.push_back("blocked");
            if (ob.blocking) flags.push_back("blocking");
            if (ob.doomed) flags.push_back("doomed");
            for (int idx : ob.once) flags.push_back("once" + std::to_string(idx));
            if (is_settling(ob)) flags.push_back("settling");
            if (ob.tenacity_used) flags.push_back("tenacity-used");
            if (ob.ward > 0) flags.push_back("ward" + std::to_string(ob.ward));
            std::sort(flags.begin(), flags.end());
            if (flags.empty()) o << '-';
            for (std::size_t i = 0; i < flags.size(); ++i) o << (i ? "," : "") << flags[i];
            o << " kw " << kwlist(ob) << '\n';
        }
    }
    for (int p = 0; p < 2; ++p)
        for (std::size_t i = 0; i < ash_[p].size(); ++i)
            o << "ash " << player_char(p) << ' ' << i + 1 << " #" << ash_[p][i] << ' '
              << obj(ash_[p][i]).card->id << '\n';
    for (int p = 0; p < 2; ++p)
        for (std::size_t i = 0; i < rift_[p].size(); ++i)
            o << "rift " << player_char(p) << ' ' << i + 1 << " #" << rift_[p][i] << ' '
              << obj(rift_[p][i]).card->id << '\n';
    for (std::size_t i = 0; i < chain_.size(); ++i) {
        const Entry& e = chain_[i];
        o << "chain " << i + 1 << " ~" << e.cid << ' ' << player_char(e.controller) << ' '
          << kind_name_entry(static_cast<int>(e.kind)) << " #" << e.source << ' ' << e.index
          << render_targets(e.targets, true) << '\n';
    }
    for (const Record& r : records_) {
        std::string desc, objs = "-";
        std::vector<int> affected;
        int ctrl = r.controller;
        RecKind kind = r.kind;
        std::int64_t a = r.a, b = r.b;
        KwSpec kw = r.kw;
        std::int64_t cheaper = 0;
        bool is_cheaper = false;
        if (r.aura) {
            ctrl = r.eff_controller;
            if (r.outs.empty()) continue;
            const AuraOut& f = r.outs[0];
            kind = f.kind;
            a = f.a;
            b = f.b;
            kw = f.kw;
            cheaper = f.cheaper;
            if (f.active) affected = f.objs;
        } else {
            for (int oid : r.affected)
                if (obj(oid).zone == Zone::Field) affected.push_back(oid);
        }
        std::vector<int> sorted = affected;
        std::sort(sorted.begin(), sorted.end(), [this](int x, int y) {
            const Obj& ox = obj(x);
            const Obj& oy = obj(y);
            return ox.ts != oy.ts ? ox.ts < oy.ts : ox.oid < oy.oid;
        });
        switch (kind) {
            case RecKind::Modify: desc = "modify " + std::to_string(a) + " " + std::to_string(b); break;
            case RecKind::Setbody: desc = "setbody " + std::to_string(a) + " " + std::to_string(b); break;
            case RecKind::Swapstats: desc = "swapstats"; break;
            case RecKind::Grant: desc = "grant " + kw.render(); break;
            case RecKind::Strip: desc = "strip"; break;
            case RecKind::Control: desc = std::string("control ") + player_char(ctrl); break;
            case RecKind::Cheaper: desc = "cheaper " + std::to_string(cheaper); is_cheaper = true; break;
        }
        if (!is_cheaper && !sorted.empty()) {
            objs.clear();
            for (std::size_t i = 0; i < sorted.size(); ++i) objs += (i ? ",#" : "#") + std::to_string(sorted[i]);
        }
        o << "effect " << r.eid << " ts" << r.ts << ' ' << player_char(ctrl) << ' '
          << (r.aura ? "aura" : "turn") << ' ' << desc << " on " << objs << '\n';
    }
    for (const Delayed& d : delayed_)
        o << "delayed " << d.ts << ' ' << player_char(d.controller) << ' ' << when_name(d.when)
          << render_targets(d.targets, false) << '\n';
    o << "STATE END\n";
    out_ << o.str();
}

void Game::print_vault() {
    std::ostringstream o;
    o << "VAULT BEGIN\n";
    for (int p = 0; p < 2; ++p) {
        std::size_t pos = 1;
        for (int oid : vault_[p])
            o << "vault " << player_char(p) << ' ' << pos++ << " #" << oid << ' ' << obj(oid).card->id << '\n';
    }
    o << "VAULT END\n";
    out_ << o.str();
}

void Game::print_legal() {
    ensure_derived();
    std::ostringstream o;
    if (over_) {
        o << "LEGAL BEGIN - over\nLEGAL END\n";
        out_ << o.str();
        return;
    }
    int who = decision_.player;
    switch (decision_.kind) {
        case DecisionKind::Priority: {
            o << "LEGAL BEGIN " << player_char(who) << " priority\nPASS\n";
            for (std::size_t i = 0; i < hand_[who].size(); ++i) {
                const Obj& ob = obj(hand_[who][i]);
                if (!play_timing_ok(ob, who)) continue;
                if (ember_[who] < effective_cost(*ob.card, who)) continue;
                static const std::vector<TargetSpec> none;
                const std::vector<TargetSpec>& specs =
                    (ob.card->type == CardType::Rite && ob.card->abilities[0].has_targets)
                        ? ob.card->abilities[0].targets : none;
                for (const auto& tuple : target_tuples(specs, who, ob.oid, next_cid_)) {
                    o << "PLAY " << i + 1 << ' ' << ob.card->id << render_ref_list(tuple) << '\n';
                }
            }
            std::vector<int> mine;
            for (int oid : field_)
                if (obj(oid).ctrl == who) mine.push_back(oid);
            std::sort(mine.begin(), mine.end());
            for (int oid : mine) {
                const Obj& ob = obj(oid);
                if (ob.stripped) continue;
                for (std::size_t k = 0; k < ob.card->abilities.size(); ++k) {
                    const Ability& ab = ob.card->abilities[k];
                    if (ab.kind != Ability::Kind::Act) continue;
                    if (!costs_payable(ob, ab, who, static_cast<int>(k) + 1)) continue;
                    for (const auto& tuple : target_tuples(ab.targets, who, oid, next_cid_))
                        o << "ACT #" << oid << ' ' << k + 1 << render_ref_list(tuple) << '\n';
                }
            }
            break;
        }
        case DecisionKind::Attackers: {
            o << "LEGAL BEGIN " << player_char(who) << " attackers\n";
            std::vector<int> can;
            for (int oid : field_)
                if (can_attack(oid)) can.push_back(oid);
            std::sort(can.begin(), can.end());
            for (int oid : can) o << "CANATTACK #" << oid << '\n';
            for (int oid : can)
                if (has_kw(oid, Kw::Relentless)) o << "MUSTATTACK #" << oid << '\n';
            break;
        }
        case DecisionKind::Blockers: {
            o << "LEGAL BEGIN " << player_char(who) << " blockers\n";
            std::vector<int> all = field_;
            std::sort(all.begin(), all.end());
            for (int b : all)
                for (int a : all)
                    if (can_block(b, a)) o << "CANBLOCK #" << b << " #" << a << '\n';
            for (int a : all)
                if (obj(a).attacking && has_kw(a, Kw::Provoke)) o << "MUSTBLOCK #" << a << '\n';
            break;
        }
        case DecisionKind::None: o << "LEGAL BEGIN - over\n"; break;
    }
    o << "LEGAL END\n";
    out_ << o.str();
}

}  // namespace spiremark
