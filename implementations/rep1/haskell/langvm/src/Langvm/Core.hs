-- | The resolved, type-checked program that the checker hands to the bytecode
-- compiler.  Names are replaced by ids, operators by their typed variants and
-- types are erased.
module Langvm.Core where

import Langvm.Builtin (Builtin)

-- | A unique local variable id (unique within the whole program).
type VarId = Int

data Const
  = KInt !Int
  | KFloat !Double
  | KStr String
  | KChar !Char
  | KBool !Bool
  | KUnit
  deriving (Show)

data UnaryOp = NegI | NegF | NotB | BitNot
  deriving (Eq, Show)

data BinaryOp
  = AddI | SubI | MulI | DivI | ModI
  | AddF | SubF | MulF | DivF
  | Concat
  | BitAnd | BitOr | BitXor | Shl | Shr
  | Eq | Ne | Lt | Le | Gt | Ge
  deriving (Eq, Show)

data CExpr
  = CConst Const
  | CVar VarId
  | CCallFn Int [CExpr]
  | CCallBuiltin Builtin [CExpr]
  | CCtor Int Int [CExpr]            -- ^ enum declaration, variant index, payloads
  | CCallValue CExpr [CExpr]
  | CCallMethod Int Int CExpr [CExpr] -- ^ trait, method index, receiver, arguments
  | CUnary UnaryOp CExpr
  | CBinary BinaryOp CExpr CExpr
  | CAnd CExpr CExpr
  | COr CExpr CExpr
  | CIndex CExpr CExpr
  | CListLit [CExpr]
  | CMapLit [(CExpr, CExpr)]
  | CTupleLit [CExpr]
  | CStructLit Int Int [(Int, CExpr)] -- ^ declaration, field count, (field index, value) in written order
  | CField CExpr Int
  | CLambda [VarId] CExpr
  | CIf CExpr CExpr CExpr
  | CMatch CExpr [CArm]
  | CBlock [CStmt] (Maybe CExpr)
  deriving (Show)

data CArm = CArm CPat (Maybe CExpr) CExpr
  deriving (Show)

data CPat
  = CPWild
  | CPVar VarId
  | CPInt !Int
  | CPStr String
  | CPChar !Char
  | CPBool !Bool
  | CPTuple [CPat]
  | CPList [CPat] (Maybe (Maybe VarId))
  | CPStruct [(Int, CPat)]            -- ^ (field index, pattern) in written order
  | CPVariant Int [CPat]              -- ^ variant index, payload patterns
  deriving (Show)

data CStmt
  = CSLet CPat CExpr
  | CSVar VarId CExpr
  | CSAssign VarId CExpr
  | CSSetIndex CExpr CExpr CExpr
  | CSExpr CExpr
  | CSReturn (Maybe CExpr)
  | CSWhile CExpr [CStmt]
  | CSForList CPat CExpr [CStmt]
  | CSForRange CPat CExpr CExpr [CStmt]
  | CSBreak
  | CSContinue
  deriving (Show)

-- | A function body: parameter variables (@self@ first for methods) and body.
data CFn = CFn { cfParams :: [VarId], cfBody :: CExpr }
  deriving (Show)

-- | Everything the compiler needs.
data CheckedProgram = CheckedProgram
  { cpFns :: [(Int, CFn)]                 -- ^ user functions by function id
  , cpMethods :: [((Int, Int), CFn)]      -- ^ (impl index, position in the impl)
  , cpDefaults :: [((Int, Int), CFn)]     -- ^ (trait id, method index)
  } deriving (Show)
