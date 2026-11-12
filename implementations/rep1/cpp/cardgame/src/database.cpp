#include "spiremark/database.hpp"

#include <algorithm>
#include <fstream>
#include <set>
#include <sstream>

namespace spiremark {

namespace {

[[noreturn]] void fail(const std::string& why) { throw DatabaseError(why); }

// -------------------------------------------------------------------------
// Small helpers over Sexpr
// -------------------------------------------------------------------------

const std::string& head_of(const Sexpr& e) {
    if (!e.is_list() || e.items.empty() || !e.items[0].is_symbol()) fail("form expected");
    return e.items[0].text;
}

void need_args(const Sexpr& e, std::size_t lo, std::size_t hi) {
    std::size_t n = e.items.size() - 1;
    if (n < lo || n > hi) fail("bad arity for " + head_of(e));
}

std::int64_t int_of(const Sexpr& e) {
    if (!e.is_int()) fail("integer expected");
    return e.value;
}

const std::string& symbol_of(const Sexpr& e) {
    if (!e.is_symbol()) fail("symbol expected");
    return e.text;
}

Cmp cmp_of(const Sexpr& e) {
    const std::string& s = symbol_of(e);
    if (s == "le") return Cmp::Le;
    if (s == "lt") return Cmp::Lt;
    if (s == "eq") return Cmp::Eq;
    if (s == "ge") return Cmp::Ge;
    if (s == "gt") return Cmp::Gt;
    if (s == "ne") return Cmp::Ne;
    fail("bad comparator");
}

Scope scope_of(const Sexpr& e) {
    const std::string& s = symbol_of(e);
    if (s == "yours") return Scope::Yours;
    if (s == "theirs") return Scope::Theirs;
    if (s == "all") return Scope::All;
    fail("bad scope");
}

CardType type_of(const std::string& s) {
    if (s == "unit") return CardType::Unit;
    if (s == "rite") return CardType::Rite;
    if (s == "relic") return CardType::Relic;
    fail("bad type");
}

bool valid_card_id(const std::string& s) {
    if (s.size() != 7 || s[3] != '-') return false;
    for (int i = 0; i < 3; ++i)
        if (s[i] < 'A' || s[i] > 'Z') return false;
    for (int i = 4; i < 7; ++i)
        if (s[i] < '0' || s[i] > '9') return false;
    return true;
}

// -------------------------------------------------------------------------
// The effect-language parser
// -------------------------------------------------------------------------

struct CardRef {
    std::string id;
    bool summon;
};

class Parser {
public:
    std::vector<CardRef> card_refs;

    KwSpec kwspec(const Sexpr& e) {
        KwSpec k;
        if (e.is_symbol()) {
            if (!keyword_from_name(e.text, k.kw)) fail("unknown keyword");
            if (k.kw == Kw::Plating) fail("plating needs a value");
            return k;
        }
        if (e.is_form("plating")) {
            need_args(e, 1, 1);
            k.kw = Kw::Plating;
            k.value = int_of(e.items[1]);
            return k;
        }
        fail("bad keyword spec");
    }

    Filter filter(const Sexpr& e) {
        const std::string& h = head_of(e);
        Filter f;
        using K = Filter::Kind;
        if (h == "kw" || h == "no-kw") {
            need_args(e, 1, 1);
            f.kind = h == "kw" ? K::Kw : K::NoKw;
            if (!keyword_from_name(symbol_of(e.items[1]), f.kw)) fail("unknown keyword");
        } else if (h == "tag") {
            need_args(e, 1, 1);
            f.kind = K::Tag;
            f.tag = symbol_of(e.items[1]);
        } else if (h == "type") {
            need_args(e, 1, 1);
            f.kind = K::Type;
            f.type = type_of(symbol_of(e.items[1]));
        } else if (h == "cost" || h == "edge" || h == "core") {
            need_args(e, 2, 2);
            f.kind = h == "cost" ? K::Cost : (h == "edge" ? K::Edge : K::Core);
            f.cmp = cmp_of(e.items[1]);
            f.n = int_of(e.items[2]);
        } else if (h == "wounded" || h == "ready" || h == "exhausted" || h == "settling" ||
                   h == "attacking" || h == "blocking" || h == "mine" || h == "enemy" ||
                   h == "other") {
            need_args(e, 0, 0);
            f.kind = h == "wounded" ? K::Wounded
                   : h == "ready" ? K::Ready
                   : h == "exhausted" ? K::Exhausted
                   : h == "settling" ? K::Settling
                   : h == "attacking" ? K::Attacking
                   : h == "blocking" ? K::Blocking
                   : h == "mine" ? K::Mine
                   : h == "enemy" ? K::Enemy : K::Other;
        } else if (h == "not") {
            need_args(e, 1, 1);
            f.kind = K::Not;
            f.inner.push_back(filter(e.items[1]));
        } else {
            fail("unknown filter");
        }
        return f;
    }

    std::vector<Filter> filters_from(const Sexpr& e, std::size_t first) {
        std::vector<Filter> out;
        for (std::size_t i = first; i < e.items.size(); ++i) out.push_back(filter(e.items[i]));
        return out;
    }

    // `(t n)`
    static bool is_target_form(const Sexpr& e) { return e.is_form("t"); }

    Selector target_sel(const Sexpr& e) {
        need_args(e, 1, 1);
        Selector s;
        s.kind = Selector::Kind::Target;
        std::int64_t n = int_of(e.items[1]);
        if (n < 1 || n > 1000000) fail("bad target index");
        s.n = static_cast<int>(n);
        return s;
    }

    Selector object_sel(const Sexpr& e) {
        using K = Selector::Kind;
        Selector s;
        if (e.is_symbol()) {
            if (e.text == "self") s.kind = K::Self;
            else if (e.text == "it") s.kind = K::It;
            else if (e.text == "that") s.kind = K::That;
            else fail("bad object selector");
            return s;
        }
        const std::string& h = head_of(e);
        if (h == "t") return target_sel(e);
        if (h == "units" || h == "relics" || h == "random-unit") {
            if (e.items.size() < 2) fail("bad arity");
            s.kind = h == "units" ? K::Units : h == "relics" ? K::Relics : K::RandomUnit;
            s.scope = scope_of(e.items[1]);
            s.filters = filters_from(e, 2);
            return s;
        }
        if (h == "cards") {
            if (e.items.size() < 3) fail("bad arity");
            s.kind = K::Cards;
            const std::string& z = symbol_of(e.items[1]);
            if (z == "hand") s.zone = CardZone::Hand;
            else if (z == "ash") s.zone = CardZone::Ash;
            else if (z == "vault") s.zone = CardZone::Vault;
            else if (z == "rift") s.zone = CardZone::Rift;
            else fail("bad zone");
            s.scope = scope_of(e.items[2]);
            s.filters = filters_from(e, 3);
            return s;
        }
        fail("bad object selector");
    }

    Selector player_sel(const Sexpr& e) {
        using K = Selector::Kind;
        Selector s;
        if (e.is_symbol()) {
            if (e.text == "you") s.kind = K::You;
            else if (e.text == "foe") s.kind = K::Foe;
            else if (e.text == "both") s.kind = K::Both;
            else fail("bad player selector");
            return s;
        }
        const std::string& h = head_of(e);
        if (h == "t") return target_sel(e);
        if (h == "owner-of") {
            need_args(e, 1, 1);
            s.kind = K::OwnerOf;
            s.inner.push_back(object_sel(e.items[1]));
            return s;
        }
        fail("bad player selector");
    }

    Selector damage_sel(const Sexpr& e) {
        if (e.is_symbol() && (e.text == "you" || e.text == "foe" || e.text == "both"))
            return player_sel(e);
        if (e.is_form("owner-of")) return player_sel(e);
        return object_sel(e);
    }

    Amount amount(const Sexpr& e) {
        using K = Amount::Kind;
        Amount a;
        if (e.is_int()) {
            a.kind = K::Literal;
            a.value = e.value;
            return a;
        }
        const std::string& h = head_of(e);
        need_args(e, 1, 1);
        if (h == "count") { a.kind = K::Count; a.sel = object_sel(e.items[1]); }
        else if (h == "edge") { a.kind = K::Edge; a.sel = object_sel(e.items[1]); }
        else if (h == "core") { a.kind = K::Core; a.sel = object_sel(e.items[1]); }
        else if (h == "wounds") { a.kind = K::Wounds; a.sel = object_sel(e.items[1]); }
        else if (h == "hand") { a.kind = K::Hand; a.sel = player_sel(e.items[1]); }
        else if (h == "ash") { a.kind = K::Ash; a.sel = player_sel(e.items[1]); }
        else if (h == "vault") { a.kind = K::Vault; a.sel = player_sel(e.items[1]); }
        else fail("bad amount");
        return a;
    }

    Condition condition(const Sexpr& e) {
        using K = Condition::Kind;
        const std::string& h = head_of(e);
        Condition c;
        if (h == "myturn") {
            need_args(e, 0, 0);
            c.kind = K::MyTurn;
        } else if (h == "count") {
            need_args(e, 3, 3);
            c.kind = K::Count;
            c.sel = object_sel(e.items[1]);
            c.cmp = cmp_of(e.items[2]);
            c.n = int_of(e.items[3]);
        } else if (h == "spire" || h == "hand" || h == "ash" || h == "vault" || h == "ember") {
            need_args(e, 3, 3);
            c.kind = h == "spire" ? K::Spire : h == "hand" ? K::Hand : h == "ash" ? K::Ash
                   : h == "vault" ? K::Vault : K::Ember;
            c.sel = player_sel(e.items[1]);
            c.cmp = cmp_of(e.items[2]);
            c.n = int_of(e.items[3]);
        } else if (h == "and" || h == "or") {
            c.kind = h == "and" ? K::And : K::Or;
            for (std::size_t i = 1; i < e.items.size(); ++i) c.kids.push_back(condition(e.items[i]));
        } else if (h == "not") {
            need_args(e, 1, 1);
            c.kind = K::Not;
            c.kids.push_back(condition(e.items[1]));
        } else {
            fail("bad condition");
        }
        return c;
    }

    std::vector<Effect> effect_list(const Sexpr& e) {
        if (!e.is_list()) fail("effect list expected");
        std::vector<Effect> out;
        for (const Sexpr& it : e.items) out.push_back(effect(it));
        return out;
    }

    Effect effect(const Sexpr& e) {
        using K = Effect::Kind;
        const std::string& h = head_of(e);
        Effect f;
        auto objsel_effect = [&](K kind) {
            need_args(e, 1, 1);
            f.kind = kind;
            f.sel = object_sel(e.items[1]);
        };
        if (h == "damage") {
            need_args(e, 2, 2);
            f.kind = K::Damage;
            f.a = amount(e.items[1]);
            f.sel = damage_sel(e.items[2]);
        } else if (h == "destroy") objsel_effect(K::Destroy);
        else if (h == "sacrifice") objsel_effect(K::Sacrifice);
        else if (h == "exile") objsel_effect(K::Exile);
        else if (h == "bounce") objsel_effect(K::Bounce);
        else if (h == "swapstats") objsel_effect(K::Swapstats);
        else if (h == "strip") objsel_effect(K::Strip);
        else if (h == "control") objsel_effect(K::Control);
        else if (h == "ready") objsel_effect(K::Ready);
        else if (h == "exhaust") objsel_effect(K::Exhaust);
        else if (h == "doom") objsel_effect(K::Doom);
        else if (h == "reanimate") objsel_effect(K::Reanimate);
        else if (h == "recall") objsel_effect(K::Recall);
        else if (h == "negate") {
            objsel_effect(K::Negate);
            if (f.sel.kind != Selector::Kind::Target) fail("negate needs (t n)");
        } else if (h == "draw" || h == "discard" || h == "mill" || h == "spire" ||
                   h == "ember" || h == "cap" || h == "shield") {
            need_args(e, 2, 2);
            f.kind = h == "draw" ? K::Draw : h == "discard" ? K::Discard : h == "mill" ? K::Mill
                   : h == "spire" ? K::Spire : h == "ember" ? K::Ember : h == "cap" ? K::Cap
                   : K::Shield;
            f.a = amount(e.items[1]);
            f.sel = player_sel(e.items[2]);
        } else if (h == "modify" || h == "setbody") {
            need_args(e, 3, 3);
            f.kind = h == "modify" ? K::Modify : K::Setbody;
            f.a = amount(e.items[1]);
            f.b = amount(e.items[2]);
            f.sel = object_sel(e.items[3]);
        } else if (h == "grant") {
            need_args(e, 2, 2);
            f.kind = K::Grant;
            f.kwspec = kwspec(e.items[1]);
            f.sel = object_sel(e.items[2]);
        } else if (h == "counters" || h == "ward") {
            need_args(e, 2, 2);
            f.kind = h == "counters" ? K::Counters : K::Ward;
            f.a = amount(e.items[1]);
            f.sel = object_sel(e.items[2]);
        } else if (h == "summon" || h == "conjure") {
            need_args(e, 3, 3);
            f.kind = h == "summon" ? K::Summon : K::Conjure;
            f.card = symbol_of(e.items[1]);
            if (!valid_card_id(f.card)) fail("bad card id");
            f.a = amount(e.items[2]);
            f.sel = player_sel(e.items[3]);
            card_refs.push_back({f.card, h == "summon"});
        } else if (h == "dig") {
            need_args(e, 3, 3);
            f.kind = K::Dig;
            f.k = int_of(e.items[1]);
            if (!e.items[2].is_list()) fail("filter list expected");
            for (const Sexpr& fe : e.items[2].items) f.filters.push_back(filter(fe));
            f.sel = player_sel(e.items[3]);
        } else if (h == "delay") {
            if (e.items.size() < 2) fail("bad arity");
            f.kind = K::Delay;
            const std::string& w = symbol_of(e.items[1]);
            if (w == "turn-end") f.when = When::TurnEnd;
            else if (w == "end-of-combat") f.when = When::EndOfCombat;
            else if (w == "your-next-turn-start") f.when = When::YourNextTurnStart;
            else fail("bad delay time");
            for (std::size_t i = 2; i < e.items.size(); ++i) f.body.push_back(effect(e.items[i]));
        } else if (h == "if") {
            need_args(e, 2, 3);
            f.kind = K::If;
            f.cond = condition(e.items[1]);
            f.body = effect_list(e.items[2]);
            if (e.items.size() == 4) f.orelse = effect_list(e.items[3]);
        } else if (h == "each") {
            if (e.items.size() < 2) fail("bad arity");
            f.kind = K::Each;
            f.sel = object_sel(e.items[1]);
            for (std::size_t i = 2; i < e.items.size(); ++i) f.body.push_back(effect(e.items[i]));
        } else if (h == "repeat") {
            if (e.items.size() < 2) fail("bad arity");
            f.kind = K::Repeat;
            f.a = amount(e.items[1]);
            for (std::size_t i = 2; i < e.items.size(); ++i) f.body.push_back(effect(e.items[i]));
        } else if (h == "nothing") {
            need_args(e, 0, 0);
            f.kind = K::Nothing;
        } else {
            fail("unknown effect");
        }
        return f;
    }

    Static static_form(const Sexpr& e) {
        using K = Static::Kind;
        const std::string& h = head_of(e);
        Static s;
        if (h == "modify" || h == "setbody") {
            need_args(e, 3, 3);
            s.kind = h == "modify" ? K::Modify : K::Setbody;
            s.a = amount(e.items[1]);
            s.b = amount(e.items[2]);
            s.sel = object_sel(e.items[3]);
        } else if (h == "swapstats") {
            need_args(e, 1, 1);
            s.kind = K::Swapstats;
            s.sel = object_sel(e.items[1]);
        } else if (h == "grant") {
            need_args(e, 2, 2);
            s.kind = K::Grant;
            s.kwspec = kwspec(e.items[1]);
            s.sel = object_sel(e.items[2]);
        } else if (h == "cheaper") {
            if (e.items.size() < 2) fail("bad arity");
            s.kind = K::Cheaper;
            s.n = int_of(e.items[1]);
            for (std::size_t i = 2; i < e.items.size(); ++i) {
                Filter f = filter(e.items[i]);
                if (f.kind != Filter::Kind::Type && f.kind != Filter::Kind::Tag &&
                    f.kind != Filter::Kind::Cost)
                    fail("bad card filter");
                s.card_filters.push_back(std::move(f));
            }
        } else if (h == "when") {
            if (e.items.size() < 2) fail("bad arity");
            s.kind = K::When;
            s.cond = condition(e.items[1]);
            for (std::size_t i = 2; i < e.items.size(); ++i) s.body.push_back(static_form(e.items[i]));
        } else {
            fail("bad static");
        }
        return s;
    }

    TargetSpec target_spec(const Sexpr& e) {
        using K = TargetSpec::Kind;
        const std::string& h = head_of(e);
        TargetSpec t;
        if (h == "unit" || h == "relic" || h == "any" || h == "ashcard") {
            t.kind = h == "unit" ? K::Unit : h == "relic" ? K::Relic : h == "any" ? K::Any
                   : K::AshCard;
            t.filters = filters_from(e, 1);
        } else if (h == "player" || h == "chained") {
            need_args(e, 0, 0);
            t.kind = h == "player" ? K::Player : K::Chained;
        } else {
            fail("bad target spec");
        }
        return t;
    }

    CostItem cost_item(const Sexpr& e) {
        using K = CostItem::Kind;
        const std::string& h = head_of(e);
        CostItem c;
        if (h == "ember" || h == "spire" || h == "discard" || h == "counters") {
            need_args(e, 1, 1);
            c.kind = h == "ember" ? K::Ember : h == "spire" ? K::Spire
                   : h == "discard" ? K::Discard : K::Counters;
            c.n = int_of(e.items[1]);
        } else if (h == "exhaust" || h == "sacself" || h == "once") {
            need_args(e, 0, 0);
            c.kind = h == "exhaust" ? K::Exhaust : h == "sacself" ? K::Sacself : K::Once;
        } else {
            fail("bad cost item");
        }
        return c;
    }
};

std::string join_printed(const std::vector<Sexpr>& v, std::size_t from) {
    std::string out;
    for (std::size_t i = from; i < v.size(); ++i) {
        if (i > from) out += ' ';
        out += v[i].print();
    }
    return out;
}

// Parses an `on`/`act`/`resolve` clause body starting at items[first].
void parse_ability_body(Parser& p, const Sexpr& clause, std::size_t first, Ability& ab) {
    bool seen_cost = false, seen_effect = false;
    std::string cost_text, target_text = "-", effect_text;
    for (std::size_t i = first; i < clause.items.size(); ++i) {
        const Sexpr& part = clause.items[i];
        if (part.is_form("cost")) {
            if (ab.kind != Ability::Kind::Act || seen_cost || seen_effect) fail("bad cost clause");
            seen_cost = true;
            for (std::size_t j = 1; j < part.items.size(); ++j)
                ab.cost.push_back(p.cost_item(part.items[j]));
            cost_text = part.print();
        } else if (part.is_form("targets")) {
            if (ab.has_targets || seen_effect) fail("bad targets clause");
            ab.has_targets = true;
            for (std::size_t j = 1; j < part.items.size(); ++j)
                ab.targets.push_back(p.target_spec(part.items[j]));
            target_text = part.print();
        } else {
            seen_effect = true;
            ab.effects.push_back(p.effect(part));
            if (!effect_text.empty()) effect_text += ' ';
            effect_text += part.print();
        }
    }
    if (ab.kind == Ability::Kind::Act && !seen_cost) fail("act without cost");
    if (!seen_effect) fail("ability without effects");
    std::string r;
    switch (ab.kind) {
        case Ability::Kind::Resolve: r = "resolve " + target_text + " " + effect_text; break;
        case Ability::Kind::On: break;  // filled in by caller (needs event name)
        case Ability::Kind::Act: r = "act " + cost_text + " " + target_text + " " + effect_text; break;
        case Ability::Kind::Aura: break;
    }
    if (ab.kind == Ability::Kind::On)
        r = "on " + clause.items[1].text + " " + target_text + " " + effect_text;
    ab.rendering = r;
}

void parse_keywords(Parser& p, const Sexpr& clause, Card& card) {
    for (std::size_t i = 1; i < clause.items.size(); ++i) {
        KwSpec k = p.kwspec(clause.items[i]);
        bool only_rite = k.kw == Kw::Swift;
        if (card.type == CardType::Relic) fail("relics have no keywords");
        if (only_rite && card.type != CardType::Rite) fail("swift only on rites");
        if (!only_rite && card.type != CardType::Unit) fail("unit keyword on non-unit");
        card.keywords.push_back(k);
        card.kw_mask |= 1u << static_cast<int>(k.kw);
        if (k.kw == Kw::Plating) card.plating_sum += k.value;
    }
}

std::unique_ptr<Card> parse_card(Parser& p, const Sexpr& form) {
    if (!form.is_form("card") || form.items.size() < 2) fail("card expected");
    auto card = std::make_unique<Card>();
    const Sexpr& id = form.items[1];
    if (!id.is_symbol() || !valid_card_id(id.text)) fail("bad card id");
    card->id = id.text;

    bool has_name = false, has_type = false, has_cost = false, has_body = false;
    bool has_tags = false, has_kw = false, has_text = false;
    std::vector<const Sexpr*> resolves, ons, acts, auras, kwclauses;
    // First pass: simple clauses (type must be known before keywords).
    for (std::size_t i = 2; i < form.items.size(); ++i) {
        const Sexpr& c = form.items[i];
        if (!c.is_list() || c.items.empty() || !c.items[0].is_symbol()) fail("clause expected");
        const std::string& h = c.items[0].text;
        if (h == "name") {
            if (has_name || c.items.size() != 2 || !c.items[1].is_string()) fail("bad name");
            has_name = true;
            card->name = c.items[1].text;
        } else if (h == "type") {
            if (has_type || c.items.size() != 2) fail("bad type");
            has_type = true;
            card->type = type_of(symbol_of(c.items[1]));
        } else if (h == "cost") {
            if (has_cost || c.items.size() != 2) fail("bad cost");
            has_cost = true;
            card->cost = int_of(c.items[1]);
            if (card->cost < 0) fail("negative cost");
        } else if (h == "body") {
            if (has_body || c.items.size() != 3) fail("bad body");
            has_body = true;
            card->edge = int_of(c.items[1]);
            card->core = int_of(c.items[2]);
            if (card->edge < 0 || card->core < 0) fail("negative body");
        } else if (h == "tags") {
            if (has_tags) fail("two tags");
            has_tags = true;
            for (std::size_t j = 1; j < c.items.size(); ++j) {
                if (!c.items[j].is_symbol()) fail("tag must be a symbol");
                card->tags.push_back(c.items[j].text);
            }
        } else if (h == "keywords") {
            if (has_kw) fail("two keywords");
            has_kw = true;
            kwclauses.push_back(&c);
        } else if (h == "text") {
            if (has_text || c.items.size() != 2 || !c.items[1].is_string()) fail("bad text");
            has_text = true;
        } else if (h == "resolve") {
            resolves.push_back(&c);
        } else if (h == "on") {
            ons.push_back(&c);
        } else if (h == "act") {
            acts.push_back(&c);
        } else if (h == "aura") {
            auras.push_back(&c);
        } else {
            fail("unknown clause");
        }
    }
    if (!has_name || !has_type || !has_cost) fail("missing required clause");
    if (card->type == CardType::Unit && !has_body) fail("unit needs body");
    if (card->type != CardType::Unit && has_body) fail("body only on units");
    if (card->type == CardType::Rite && resolves.size() != 1) fail("rite needs one resolve");
    if (card->type != CardType::Rite && !resolves.empty()) fail("resolve only on rites");
    for (const Sexpr* k : kwclauses) parse_keywords(p, *k, *card);

    for (const Sexpr* c : resolves) {
        Ability ab;
        ab.kind = Ability::Kind::Resolve;
        parse_ability_body(p, *c, 1, ab);
        card->abilities.push_back(std::move(ab));
    }
    for (const Sexpr* c : ons) {
        if (c->items.size() < 2 || !c->items[1].is_symbol()) fail("bad on clause");
        Ability ab;
        ab.kind = Ability::Kind::On;
        if (!event_from_name(c->items[1].text, ab.event)) fail("unknown event");
        parse_ability_body(p, *c, 2, ab);
        card->abilities.push_back(std::move(ab));
    }
    for (const Sexpr* c : acts) {
        Ability ab;
        ab.kind = Ability::Kind::Act;
        parse_ability_body(p, *c, 1, ab);
        card->abilities.push_back(std::move(ab));
    }
    for (const Sexpr* c : auras) {
        if (c->items.size() < 2) fail("empty aura");
        Ability ab;
        ab.kind = Ability::Kind::Aura;
        for (std::size_t i = 1; i < c->items.size(); ++i) ab.statics.push_back(p.static_form(c->items[i]));
        ab.rendering = "aura " + join_printed(c->items, 1);
        card->abilities.push_back(std::move(ab));
    }
    return card;
}

}  // namespace

Database Database::parse(const std::string& source) {
    std::vector<Sexpr> forms = parse_sexprs(source);
    Database db;
    Parser p;
    for (const Sexpr& f : forms) {
        std::unique_ptr<Card> c = parse_card(p, f);
        if (db.cards_.count(c->id)) fail("duplicate card id");
        std::string id = c->id;
        db.cards_.emplace(std::move(id), std::move(c));
    }
    for (const CardRef& r : p.card_refs) {
        const Card* c = db.find(r.id);
        if (!c) fail("unknown card referenced");
        if (r.summon && c->type == CardType::Rite) fail("cannot summon a rite");
    }
    return db;
}

Database Database::load_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw DatabaseError("cannot read " + path);
    std::ostringstream ss;
    ss << in.rdbuf();
    if (in.bad()) throw DatabaseError("cannot read " + path);
    return parse(ss.str());
}

const Card* Database::find(const std::string& id) const {
    auto it = cards_.find(id);
    return it == cards_.end() ? nullptr : it->second.get();
}

std::string Database::describe(const std::string& id) const {
    std::string out = "CARD BEGIN " + id + "\n";
    const Card* c = find(id);
    if (!c) {
        out += "unknown\nCARD END\n";
        return out;
    }
    out += "name " + c->name + "\n";
    out += std::string("type ") + card_type_name(c->type) + "\n";
    out += "cost " + std::to_string(c->cost) + "\n";
    if (c->type == CardType::Unit)
        out += "body " + std::to_string(c->edge) + "/" + std::to_string(c->core) + "\n";
    out += "tags ";
    if (c->tags.empty()) out += "-";
    for (std::size_t i = 0; i < c->tags.size(); ++i) out += (i ? "," : "") + c->tags[i];
    out += "\nkeywords ";
    if (c->keywords.empty()) {
        out += "-";
    } else {
        std::vector<std::string> names;
        for (const KwSpec& k : c->keywords) names.push_back(k.render());
        std::sort(names.begin(), names.end());
        for (std::size_t i = 0; i < names.size(); ++i) out += (i ? "," : "") + names[i];
    }
    out += "\n";
    for (std::size_t i = 0; i < c->abilities.size(); ++i)
        out += "ability " + std::to_string(i + 1) + " " + c->abilities[i].rendering + "\n";
    out += "CARD END\n";
    return out;
}

}  // namespace spiremark
