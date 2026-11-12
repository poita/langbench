-- | The instruction set and the compiled program (SPEC.md section 16).
module Langvm.Bytecode
  ( Instr (..)
  , FnCode (..)
  , Program (..)
  , implKey
  ) where

import Data.Array (Array)
import Data.Bits (shiftL, (.|.))
import Data.IntMap.Strict (IntMap)

import Langvm.Builtin (Builtin)
import Langvm.Value (Value)

-- | One VM instruction.  Operands are compile-time constants.
data Instr
  = IPush !Value
  | ILoad !Int
  | IStore !Int
  | ILoadUp !Int
  | IPop
  | IDup
  | IMakeClosure !Int !Int            -- ^ function, number of upvalues
  | ICall !Int !Int                   -- ^ function, argument count
  | ICallValue !Int                   -- ^ argument count
  | ICallBuiltin !Builtin !Int
  | ICallMethod !Int !Int !Int        -- ^ trait, method, argument count (receiver excluded)
  | IRet
  | IAddI | ISubI | IMulI | IDivI | IModI | INegI | IBitNot
  | IBitAnd | IBitOr | IBitXor | IShl | IShr
  | IAddF | ISubF | IMulF | IDivF | INegF
  | INot
  | IEq | INe | ILt | ILe | IGt | IGe
  | IConcat
  | IJump !Int
  | IJumpIfFalse !Int
  | IJumpIfTrue !Int
  | IMakeList !Int
  | IMakeMap !Int
  | IMakeTuple !Int
  | IMakeStruct !Int !Int             -- ^ declaration, field count
  | IMakeEnum !Int !Int !Int          -- ^ declaration, variant, payload count
  | IGetField !Int
  | IGetPayload !Int
  | IGetTuple !Int
  | IIndexGet
  | IIndexSet
  | IIsVariant !Int
  | ISeqLen
  | IListRest !Int
  | INoMatch

-- | A compiled function.
data FnCode = FnCode
  { fnParams :: !Int            -- ^ parameter count (including @self@)
  , fnLocals :: !Int            -- ^ local slots (parameters first)
  , fnFrame :: !Int             -- ^ stack slots a frame needs: locals plus operand depth
  , fnCode :: Array Int Instr
  }

-- | A whole compiled program.
data Program = Program
  { progFns :: Array Int FnCode
  , progMain :: !Int
  , progImpls :: IntMap (Array Int Int)  -- ^ 'implKey' -> method function indices
  }

-- | The key of an impl in the dispatch table.
implKey :: Int -> Int -> Int
implKey trait headCtor = (trait `shiftL` 24) .|. headCtor
