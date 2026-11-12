-- |
-- Module      : Spiremark.Card.Types
-- Description : Typed representation of cards, abilities and the effect language.
--
-- These types are the output of the card-database validator
-- ("Spiremark.Card.Parse") and the input of the rules engine.  They follow
-- SPEC.md sections 5 and 6 one-to-one.
module Spiremark.Card.Types
  ( -- * Cards
    Card (..)
  , CardDb
  , CardType (..)
  , Keyword (..)
  , KwSpec (..)
  , allKeywords
  , keywordName
  , keywordFromName
  , renderKw
    -- * Abilities
  , Ability (..)
  , AbilityKind (..)
  , Event (..)
  , eventName
  , eventFromName
  , allEvents
  , When (..)
  , whenName
  , whenFromName
    -- * Effect language
  , Cmp (..)
  , cmpFromName
  , compareBy
  , Scope (..)
  , CardZone (..)
  , Filter (..)
  , Sel (..)
  , PSel (..)
  , DSel (..)
  , Amt (..)
  , Cond (..)
  , Effect (..)
  , TSpec (..)
  , CostItem (..)
  , Static (..)
  , CardFilter (..)
  ) where

import Data.Map.Strict (Map)

import Spiremark.SExpr (SExpr)

-- | Card database: card id to card.
type CardDb = Map String Card

-- | The three card types.
data CardType = Unit | Rite | Relic
  deriving (Eq, Ord, Show)

-- | The sixteen keywords (SPEC.md 16).
data Keyword
  = Vanguard | Vigil | Riposte | Pierce | Ghostwalk | Skyhook | Venom | Siphon
  | Plating | Provoke | Spectral | Tenacity | Siegework | Shackled | Relentless
  | Swift
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A keyword instance; the integer is the value of @plating@ and 0 otherwise.
data KwSpec = KwSpec !Keyword !Int
  deriving (Eq, Ord, Show)

allKeywords :: [Keyword]
allKeywords = [minBound .. maxBound]

-- | Lower-case name of a keyword as written in the database.
keywordName :: Keyword -> String
keywordName k = case k of
  Vanguard -> "vanguard"; Vigil -> "vigil"; Riposte -> "riposte"
  Pierce -> "pierce"; Ghostwalk -> "ghostwalk"; Skyhook -> "skyhook"
  Venom -> "venom"; Siphon -> "siphon"; Plating -> "plating"
  Provoke -> "provoke"; Spectral -> "spectral"; Tenacity -> "tenacity"
  Siegework -> "siegework"; Shackled -> "shackled"; Relentless -> "relentless"
  Swift -> "swift"

keywordFromName :: String -> Maybe Keyword
keywordFromName s = lookup s [(keywordName k, k) | k <- allKeywords]

-- | Render a keyword instance: @plating:N@ or the bare name.
renderKw :: KwSpec -> String
renderKw (KwSpec Plating n) = "plating:" ++ show n
renderKw (KwSpec k _) = keywordName k

-- | What kind of clause an ability came from.
data AbilityKind = AKResolve | AKOn Event | AKAct | AKAura
  deriving (Eq, Show)

-- | Trigger events (SPEC.md 13.1).
data Event
  = EvArrive | EvLeave | EvDies | EvAllyArrive | EvEnemyArrive | EvAllyDies
  | EvEnemyDies | EvTurnStart | EvYourTurnStart | EvTurnEnd | EvYourTurnEnd
  | EvAttacks | EvBlocks | EvBlocked | EvUnblocked | EvDamaged | EvDealsDamage
  | EvYouPlayRite | EvEnemyPlaysRite | EvYouDraw | EvSpireLoss
  | EvEnemySpireLoss | EvEndOfCombat
  deriving (Eq, Ord, Show, Enum, Bounded)

allEvents :: [Event]
allEvents = [minBound .. maxBound]

eventName :: Event -> String
eventName e = case e of
  EvArrive -> "arrive"; EvLeave -> "leave"; EvDies -> "dies"
  EvAllyArrive -> "ally-arrive"; EvEnemyArrive -> "enemy-arrive"
  EvAllyDies -> "ally-dies"; EvEnemyDies -> "enemy-dies"
  EvTurnStart -> "turn-start"; EvYourTurnStart -> "your-turn-start"
  EvTurnEnd -> "turn-end"; EvYourTurnEnd -> "your-turn-end"
  EvAttacks -> "attacks"; EvBlocks -> "blocks"; EvBlocked -> "blocked"
  EvUnblocked -> "unblocked"; EvDamaged -> "damaged"
  EvDealsDamage -> "deals-damage"; EvYouPlayRite -> "you-play-rite"
  EvEnemyPlaysRite -> "enemy-plays-rite"; EvYouDraw -> "you-draw"
  EvSpireLoss -> "spire-loss"; EvEnemySpireLoss -> "enemy-spire-loss"
  EvEndOfCombat -> "end-of-combat"

eventFromName :: String -> Maybe Event
eventFromName s = lookup s [(eventName e, e) | e <- allEvents]

-- | Timing of a delayed trigger.
data When = WTurnEnd | WEndOfCombat | WYourNextTurnStart
  deriving (Eq, Ord, Show)

whenName :: When -> String
whenName w = case w of
  WTurnEnd -> "turn-end"; WEndOfCombat -> "end-of-combat"
  WYourNextTurnStart -> "your-next-turn-start"

whenFromName :: String -> Maybe When
whenFromName s = lookup s [(whenName w, w) | w <- [WTurnEnd, WEndOfCombat, WYourNextTurnStart]]

-- | Comparators (SPEC.md 6.1).
data Cmp = CLe | CLt | CEq | CGe | CGt | CNe
  deriving (Eq, Show)

cmpFromName :: String -> Maybe Cmp
cmpFromName s = lookup s
  [("le", CLe), ("lt", CLt), ("eq", CEq), ("ge", CGe), ("gt", CGt), ("ne", CNe)]

-- | @compareBy c l r@ is @l \`c\` r@.
compareBy :: Cmp -> Int -> Int -> Bool
compareBy c l r = case c of
  CLe -> l <= r; CLt -> l < r; CEq -> l == r; CGe -> l >= r; CGt -> l > r; CNe -> l /= r

-- | Selector scope.
data Scope = Yours | Theirs | AllScope
  deriving (Eq, Show)

-- | Zones usable in a @(cards ...)@ selector.
data CardZone = CZHand | CZAsh | CZVault | CZRift
  deriving (Eq, Ord, Show)

-- | Filters (SPEC.md 6.5); all inspect base characteristics.
data Filter
  = FKw Keyword | FNoKw Keyword | FTag String | FType CardType
  | FCost Cmp Int | FEdge Cmp Int | FCore Cmp Int
  | FWounded | FReady | FExhausted | FSettling | FAttacking | FBlocking
  | FMine | FEnemy | FOther | FNot Filter
  deriving (Eq, Show)

-- | Object selectors (SPEC.md 6.3).
data Sel
  = SelSelf | SelIt | SelThat | SelTarget Int
  | SelUnits Scope [Filter] | SelRelics Scope [Filter]
  | SelCards CardZone Scope [Filter] | SelRandomUnit Scope [Filter]
  deriving (Eq, Show)

-- | Player selectors (SPEC.md 6.4).
data PSel = PYou | PFoe | PBoth | PTarget Int | POwnerOf Sel
  deriving (Eq, Show)

-- | Damage selectors (SPEC.md 6.4.1).
data DSel = DPlayers PSel | DObjects Sel
  deriving (Eq, Show)

-- | Amounts (SPEC.md 6.6).
data Amt
  = AInt Int | ACount Sel | AHand PSel | AAsh PSel | AVault PSel
  | AEdge Sel | ACore Sel | AWounds Sel
  deriving (Eq, Show)

-- | Conditions (SPEC.md 6.7).
data Cond
  = CCount Sel Cmp Int | CSpire PSel Cmp Int | CHand PSel Cmp Int
  | CAsh PSel Cmp Int | CVault PSel Cmp Int | CEmber PSel Cmp Int
  | CMyTurn | CAnd [Cond] | COr [Cond] | CNot Cond
  deriving (Eq, Show)

-- | Effects (SPEC.md 6.8).
data Effect
  = EDamage Amt DSel | EDestroy Sel | ESacrifice Sel | EExile Sel | EBounce Sel
  | EDraw Amt PSel | EDiscard Amt PSel | EMill Amt PSel | ESpire Amt PSel
  | EEmber Amt PSel | ECap Amt PSel
  | EModify Amt Amt Sel | ESetbody Amt Amt Sel | ESwapstats Sel
  | EGrant KwSpec Sel | EStrip Sel | EControl Sel
  | ECounters Amt Sel | EReady Sel | EExhaust Sel | EDoom Sel
  | EWard Amt Sel | EShield Amt PSel
  | ESummon String Amt PSel | EConjure String Amt PSel
  | EReanimate Sel | ERecall Sel | ENegate Int
  | EDig Int [Filter] PSel
  | EDelay When [Effect]
  | EIf Cond [Effect] [Effect]
  | EEach Sel [Effect]
  | ERepeat Amt [Effect]
  | ENothing
  deriving (Eq, Show)

-- | Target specifications (SPEC.md 12.1).
data TSpec
  = TUnit [Filter] | TRelic [Filter] | TAny [Filter] | TPlayer | TChained
  | TAshCard [Filter]
  deriving (Eq, Show)

-- | Activated-ability cost items (SPEC.md 6.10).
data CostItem
  = CIEmber Int | CISpire Int | CIDiscard Int | CIExhaust | CISacSelf
  | CICounters Int | CIOnce
  deriving (Eq, Show)

-- | Filters for the @cheaper@ static, tested against printed card data.
data CardFilter = CFType CardType | CFTag String | CFCost Cmp Int
  deriving (Eq, Show)

-- | Aura statics (SPEC.md 6.11).
data Static
  = StModify Amt Amt Sel | StSetbody Amt Amt Sel | StSwapstats Sel
  | StGrant KwSpec Sel | StCheaper Int [CardFilter] | StWhen Cond [Static]
  deriving (Eq, Show)

-- | One numbered ability of a card (SPEC.md 5.3).
data Ability = Ability
  { abIndex      :: !Int            -- ^ 1-based ability number
  , abKind       :: AbilityKind
  , abTargets    :: [TSpec]
  , abTargetsRaw :: Maybe SExpr     -- ^ the @(targets ...)@ clause as written
  , abCost       :: [CostItem]
  , abCostRaw    :: Maybe SExpr     -- ^ the @(cost ...)@ clause as written
  , abEffects    :: [Effect]
  , abStatics    :: [Static]
  , abRaw        :: [SExpr]         -- ^ effects or statics as written
  } deriving (Show)

-- | A validated card.
data Card = Card
  { cardId        :: String
  , cardName      :: String
  , cardType      :: CardType
  , cardCost      :: !Int
  , cardBody      :: Maybe (Int, Int)   -- ^ printed (edge, core), units only
  , cardTags      :: [String]
  , cardKeywords  :: [KwSpec]
  , cardAbilities :: [Ability]
  } deriving (Show)
