-- |
-- Module      : Spiremark.Engine.Types
-- Description : The complete game state of a Spiremark match.
--
-- All mutable match state lives in one strict record, 'G'.  The engine is a
-- state machine over it: 'gMode' says what the engine is waiting for (or about
-- to do), and every rules procedure is a function in the 'Eng' monad.
module Spiremark.Engine.Types
  ( -- * Game state
    G (..)
  , Config (..)
  , Mode (..)
  , Decision (..)
  , Phase (..)
  , phaseName
  , Eng
    -- * Objects
  , Obj (..)
  , Zone (..)
  , FieldSt (..)
  , freshFieldSt
  , PState (..)
    -- * Chain, triggers, records
  , Entry (..)
  , EKind (..)
  , Slot (..)
  , Subject (..)
  , Pending (..)
  , Delayed (..)
  , Rec (..)
  , RBody (..)
  , DKind (..)
    -- * Derived characteristics
  , Derived (..)
  , AuraEval (..)
    -- * Accessors
  , pst
  , modP
  , getObj
  , lookupObj
  , isOver
  ) where

import Control.Monad.State.Strict (State)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntSet (IntSet)
import Data.Sequence (Seq)
import Data.Set (Set)
import Data.Word ()

import Spiremark.Card.Types
import Spiremark.Match (TraceMode)
import Spiremark.Random (Rng)
import Spiremark.Types

-- | The engine monad.
type Eng = State G

-- | Static match configuration.
data Config = Config
  { cfMaxCap    :: !Int
  , cfHandMax   :: !Int
  , cfTurnLimit :: !Int
  , cfFirst     :: !Player
  , cfTrace     :: !TraceMode
  } deriving (Show)

-- | What the engine is waiting for.
data Decision = DPriority | DAttackers | DBlockers
  deriving (Eq, Show)

-- | Phases and steps of a turn (SPEC.md section 9).
data Phase
  = PhDawn | PhDraw | PhMain1 | PhClashAttack | PhClashBlock | PhClashRiposte
  | PhClashDamage | PhClashEnd | PhMain2 | PhDuskTrigger | PhDuskDiscard
  | PhDuskCleanup
  deriving (Eq, Ord, Show, Enum, Bounded)

phaseName :: Phase -> String
phaseName p = case p of
  PhDawn -> "dawn"; PhDraw -> "draw"; PhMain1 -> "main1"
  PhClashAttack -> "clash-attack"; PhClashBlock -> "clash-block"
  PhClashRiposte -> "clash-riposte"; PhClashDamage -> "clash-damage"
  PhClashEnd -> "clash-end"; PhMain2 -> "main2"
  PhDuskTrigger -> "dusk-trigger"; PhDuskDiscard -> "dusk-discard"
  PhDuskCleanup -> "dusk-cleanup"

-- | The engine's control state.
data Mode
  = MEnter !Phase        -- ^ about to enter this phase or step
  | MAwait !Decision     -- ^ stopped at a decision point
  | MOver                -- ^ the match has ended
  deriving (Eq, Show)

-- | Zones an object can be in.  'ZnChain' is a card on the Chain.
data Zone = ZnVault | ZnHand | ZnField | ZnAsh | ZnRift | ZnChain
  deriving (Eq, Show)

-- | State that exists only while an object is on the Field (SPEC.md 7.5).
data FieldSt = FieldSt
  { fCtl       :: !Player      -- ^ base controller
  , fExhausted :: !Bool
  , fWounds    :: !Int
  , fCounters  :: !Int
  , fWard      :: !Int
  , fDoomed    :: !Bool
  , fSince     :: !Int
  , fAttacking :: !Bool
  , fBlocking  :: !(Maybe Int)  -- ^ the attacker this unit blocks
  , fBlockers  :: [Int]         -- ^ blockers of this attacker, canonical order
  , fBlocked   :: !Bool
  , fTenUsed   :: !Bool
  , fOnce      :: !IntSet
  } deriving (Show)

-- | Field state of an object that has just entered the Field.
freshFieldSt :: Player -> Int -> FieldSt
freshFieldSt c since = FieldSt
  { fCtl = c, fExhausted = False, fWounds = 0, fCounters = 0, fWard = 0
  , fDoomed = False, fSince = since, fAttacking = False, fBlocking = Nothing
  , fBlockers = [], fBlocked = False, fTenUsed = False, fOnce = mempty }

-- | A card instance.
data Obj = Obj
  { oOid     :: !Int
  , oCard    :: Card
  , oOwner   :: !Player
  , oTs      :: !Int       -- ^ timestamp of the last Field entry (0 if none)
  , oZone    :: !Zone
  , oLastCtl :: !Player    -- ^ controller when it last left the Field
  , oF       :: !FieldSt
  }

-- | Per-player state.
data PState = PState
  { pSpire  :: !Int
  , pEmber  :: !Int
  , pCap    :: !Int
  , pShield :: !Int
  , pVault  :: !(Seq Int)
  , pHand   :: !(Seq Int)
  , pAsh    :: !(Seq Int)
  , pRift   :: !(Seq Int)
  }

-- | Kind of a Chain entry.
data EKind = EKRite | EKUnit | EKRelic | EKAbility | EKTrigger
  deriving (Eq, Show)

-- | A target together with its \"removed as illegal\" mark.
data Slot = Slot { slTarget :: !Target, slRemoved :: !Bool }
  deriving (Eq, Show)

-- | The trigger subject @it@.
data Subject = SubObj !Int | SubPlayer !Player
  deriving (Eq, Show)

-- | An entry on the Chain.
data Entry = Entry
  { enCid     :: !Int
  , enKind    :: !EKind
  , enCtl     :: !Player
  , enSrc     :: !Int
  , enIdx     :: !Int
  , enSlots   :: [Slot]
  , enSpecs   :: [TSpec]
  , enIt      :: Maybe Subject
  , enEffects :: Maybe [Effect]   -- ^ stored effects of a delayed trigger
  }

-- | A registered delayed trigger.
data Delayed = Delayed
  { dlTs      :: !Int
  , dlCtl     :: !Player
  , dlWhen    :: !When
  , dlSrc     :: !Int
  , dlSlots   :: [Slot]
  , dlSpecs   :: [TSpec]
  , dlEffects :: [Effect]
  }

-- | A collected, not yet pushed, trigger.
data Pending = Pending
  { pdCtl     :: !Player
  , pdTs      :: !Int
  , pdOid     :: !Int
  , pdIdx     :: !Int
  , pdIt      :: Maybe Subject
  , pdDelayed :: Maybe Delayed
  }

-- | The kind of a discrete continuous-effect record.
data DKind
  = DModify !Int !Int | DSetbody !Int !Int | DSwap | DGrant !KwSpec | DStrip
  | DControl !Player
  deriving (Eq, Show)

-- | Body of a continuous-effect record.
data RBody
  = RDiscrete DKind [Int]       -- ^ duration @turn@, fixed affected list
  | RAura Ability               -- ^ duration @aura@, from this ability's statics

-- | A continuous-effect record (SPEC.md 14.1).
data Rec = Rec
  { rEid  :: !Int
  , rTs   :: !Int
  , rCtl  :: !Player          -- ^ meaningful for discrete records only
  , rSrc  :: !Int
  , rBody :: RBody
  }

-- | Evaluation of one aura record against the current board.
data AuraEval = AuraEval
  { aeActive :: !Bool
  , aeDesc   :: String
  , aeObjs   :: [Int]
  , aeCtl    :: !Player
  }

-- | Whole-board derivation result (SPEC.md 14.3).
data Derived = Derived
  { dCtl      :: !(IntMap Player)      -- ^ current controller of Field objects
  , dStripped :: !IntSet
  , dStats    :: !(IntMap (Int, Int))  -- ^ current (edge, core) of Field objects
  , dKw       :: !(IntMap [KwSpec])    -- ^ current keywords of Field objects
  , dAuras    :: !(IntMap AuraEval)    -- ^ per aura record, by eid
  , dCheaper  :: [(Player, Int, [CardFilter])]
  , dDeps     :: !Int                  -- ^ state classes the aura records read (see 'Spiremark.Engine.Core.mutDep')
  }

-- | The match.
data G = G
  { gCfg      :: !Config
  , gDb       :: CardDb
  , gObjs     :: !(IntMap Obj)
  , gField    :: !(Set (Int, Int))     -- ^ (timestamp, oid) of Field objects
  , gNextOid  :: !Int
  , gNextTs   :: !Int
  , gNextCid  :: !Int
  , gNextEid  :: !Int
  , gA        :: !PState
  , gB        :: !PState
  , gChain    :: [Entry]               -- ^ top entry first
  , gRecs     :: !(IntMap Rec)         -- ^ by eid
  , gDelayed  :: [Delayed]             -- ^ in creation order
  , gPending  :: [Pending]             -- ^ most recently collected first
  , gTurn     :: !Int
  , gActive   :: !Player
  , gPhase    :: !Phase
  , gMode     :: !Mode
  , gPass     :: !Int
  , gHolder   :: !Player
  , gDealt    :: !IntSet               -- ^ units that dealt riposte damage
  , gLossA    :: !(Maybe String)
  , gLossB    :: !(Maybe String)
  , gResult   :: !(Maybe (String, String))
  , gRng      :: !Rng
  , gSeq      :: !Int
  , gOut      :: [String]              -- ^ output lines, newest first
  , gDerived  :: !(Maybe Derived)
  }

-- | Player state accessor.
pst :: Player -> G -> PState
pst A = gA
pst B = gB

-- | Modify a player's state.
modP :: Player -> (PState -> PState) -> G -> G
modP A f g = g { gA = f (gA g) }
modP B f g = g { gB = f (gB g) }

getObj :: Int -> G -> Obj
getObj oid g = gObjs g IM.! oid

lookupObj :: Int -> G -> Maybe Obj
lookupObj oid g = IM.lookup oid (gObjs g)

isOver :: G -> Bool
isOver g = gMode g == MOver
