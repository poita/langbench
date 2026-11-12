// Typed card model: the effect language of SPEC.md section 6 as a tree.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace spiremark {

enum class CardType : std::uint8_t { Unit, Rite, Relic };

/// The sixteen keywords. `Plating` carries a value; the rest are flags.
enum class Kw : std::uint8_t {
    Vanguard, Vigil, Riposte, Pierce, Ghostwalk, Skyhook, Venom, Siphon,
    Plating, Provoke, Spectral, Tenacity, Siegework, Shackled, Relentless, Swift,
    Count
};

const char* keyword_name(Kw k);
/// Looks a keyword up by its printed name; returns false when unknown.
bool keyword_from_name(const std::string& name, Kw& out);

/// A keyword instance as printed on a card or granted by an effect.
struct KwSpec {
    Kw kw = Kw::Vanguard;
    std::int64_t value = 0;  ///< plating value (0 for other keywords)
    /// "vanguard" or "plating:2".
    std::string render() const;
};

enum class Cmp : std::uint8_t { Le, Lt, Eq, Ge, Gt, Ne };
bool compare(Cmp c, std::int64_t lhs, std::int64_t rhs);

enum class Scope : std::uint8_t { Yours, Theirs, All };
enum class CardZone : std::uint8_t { Hand, Ash, Vault, Rift };

// ---------------------------------------------------------------- filters --

struct Filter {
    enum class Kind : std::uint8_t {
        Kw, NoKw, Tag, Type, Cost, Edge, Core, Wounded, Ready, Exhausted,
        Settling, Attacking, Blocking, Mine, Enemy, Other, Not
    };
    Kind kind = Kind::Wounded;
    Kw kw = Kw::Vanguard;
    std::string tag;
    CardType type = CardType::Unit;
    Cmp cmp = Cmp::Eq;
    std::int64_t n = 0;
    std::vector<Filter> inner;  ///< exactly one element for Kind::Not
};

// -------------------------------------------------------------- selectors --

struct Selector {
    enum class Kind : std::uint8_t {
        Self, It, That, Target,          // object forms
        Units, Relics, Cards, RandomUnit,
        You, Foe, Both, OwnerOf          // player forms (Target doubles as `(t n)`)
    };
    Kind kind = Kind::Self;
    int n = 0;                       ///< target index for Kind::Target
    Scope scope = Scope::All;
    CardZone zone = CardZone::Hand;
    std::vector<Filter> filters;
    std::vector<Selector> inner;     ///< one element for OwnerOf
};

// ---------------------------------------------------------------- amounts --

struct Amount {
    enum class Kind : std::uint8_t { Literal, Count, Hand, Ash, Vault, Edge, Core, Wounds };
    Kind kind = Kind::Literal;
    std::int64_t value = 0;
    Selector sel;  ///< object selector (Count/Edge/Core/Wounds) or player selector
};

// ------------------------------------------------------------- conditions --

struct Condition {
    enum class Kind : std::uint8_t {
        Count, Spire, Hand, Ash, Vault, Ember, MyTurn, And, Or, Not
    };
    Kind kind = Kind::MyTurn;
    Cmp cmp = Cmp::Eq;
    std::int64_t n = 0;
    Selector sel;
    std::vector<Condition> kids;
};

// ---------------------------------------------------------------- effects --

enum class When : std::uint8_t { TurnEnd, EndOfCombat, YourNextTurnStart };
const char* when_name(When w);

struct Effect {
    enum class Kind : std::uint8_t {
        Damage, Destroy, Sacrifice, Exile, Bounce, Draw, Discard, Mill, Spire,
        Ember, Cap, Modify, Setbody, Swapstats, Grant, Strip, Control, Counters,
        Ready, Exhaust, Doom, Ward, Shield, Summon, Conjure, Reanimate, Recall,
        Negate, Dig, Delay, If, Each, Repeat, Nothing
    };
    Kind kind = Kind::Nothing;
    Amount a;                       ///< first amount (damage, draw, modify edge, ...)
    Amount b;                       ///< second amount (modify/setbody core)
    Selector sel;                   ///< object, player or damage selector
    KwSpec kwspec;                  ///< Grant
    std::string card;               ///< Summon / Conjure
    std::int64_t k = 0;             ///< Dig count
    std::vector<Filter> filters;    ///< Dig
    When when = When::TurnEnd;      ///< Delay
    Condition cond;                 ///< If
    std::vector<Effect> body;       ///< Delay/Each/Repeat body, If "then"
    std::vector<Effect> orelse;     ///< If "else"
};

// ----------------------------------------------------------------- statics --

struct Static {
    enum class Kind : std::uint8_t { Modify, Setbody, Swapstats, Grant, Cheaper, When };
    Kind kind = Kind::Modify;
    Amount a;
    Amount b;
    Selector sel;
    KwSpec kwspec;
    std::int64_t n = 0;               ///< Cheaper amount
    std::vector<Filter> card_filters; ///< Cheaper (type/tag/cost filters)
    Condition cond;                   ///< When
    std::vector<Static> body;         ///< When
};

// ---------------------------------------------------------------- abilities --

struct TargetSpec {
    enum class Kind : std::uint8_t { Unit, Relic, Any, Player, Chained, AshCard };
    Kind kind = Kind::Unit;
    std::vector<Filter> filters;
};

struct CostItem {
    enum class Kind : std::uint8_t { Ember, Spire, Discard, Exhaust, Sacself, Counters, Once };
    Kind kind = Kind::Once;
    std::int64_t n = 0;
};

enum class Event : std::uint8_t {
    Arrive, Leave, Dies, AllyArrive, EnemyArrive, AllyDies, EnemyDies,
    TurnStart, YourTurnStart, TurnEnd, YourTurnEnd, Attacks, Blocks, Blocked,
    Unblocked, Damaged, DealsDamage, YouPlayRite, EnemyPlaysRite, YouDraw,
    SpireLoss, EnemySpireLoss, EndOfCombat, Count
};
bool event_from_name(const std::string& name, Event& out);

struct Ability {
    enum class Kind : std::uint8_t { Resolve, On, Act, Aura };
    Kind kind = Kind::Resolve;
    Event event = Event::Arrive;        ///< On
    bool has_targets = false;
    std::vector<TargetSpec> targets;
    std::vector<CostItem> cost;         ///< Act
    std::vector<Effect> effects;        ///< Resolve / On / Act
    std::vector<Static> statics;        ///< Aura
    std::string rendering;              ///< canonical text printed by `CARD`
};

// -------------------------------------------------------------------- card --

struct Card {
    std::string id;
    std::string name;
    CardType type = CardType::Unit;
    std::int64_t cost = 0;
    std::int64_t edge = 0;   ///< printed edge (0 for non-units)
    std::int64_t core = 0;   ///< printed core (0 for non-units)
    std::vector<std::string> tags;                 ///< file order
    std::vector<KwSpec> keywords;                  ///< printed, file order
    std::vector<Ability> abilities;                ///< numbered from 1 (index 0 = ability 1)
    std::uint32_t kw_mask = 0;                     ///< bit per Kw present when printed
    std::int64_t plating_sum = 0;                  ///< sum of printed plating values

    bool has_tag(const std::string& t) const;
    bool has_printed_kw(Kw k) const { return (kw_mask >> static_cast<int>(k)) & 1u; }
};

const char* card_type_name(CardType t);

}  // namespace spiremark
