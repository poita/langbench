-- | The abstract syntax tree produced by the parser (SPEC.md section 4).
module Langvm.Syntax where

import Langvm.Diagnostic (Pos)

-- | An identifier with its position.
data Ident = Ident { identName :: String, identPos :: !Pos }
  deriving (Eq, Show)

-- | A parsed module body.
data Module = Module { modName :: String, modItems :: [Item] }
  deriving (Show)

data Item
  = IUse Pos Ident (Maybe Ident)
  | IFn FnDecl
  | IStruct StructDecl
  | IEnum EnumDecl
  | ITrait TraitDecl
  | IImpl ImplDecl
  deriving (Show)

data GenParam = GenParam { gpName :: Ident, gpBounds :: [TraitRef] }
  deriving (Show)

-- | @Tr@ or @m::Tr@.  The position is that of the first token.
data TraitRef = TraitRef { trQual :: Maybe Ident, trName :: Ident }
  deriving (Show)

data Param = Param { paramName :: Ident, paramType :: TypeExpr }
  deriving (Show)

data FnDecl = FnDecl
  { fnPub :: Bool
  , fnPos :: Pos
  , fnName :: Ident
  , fnGenerics :: [GenParam]
  , fnParams :: [Param]
  , fnRet :: Maybe TypeExpr
  , fnBody :: Block
  } deriving (Show)

data StructDecl = StructDecl
  { sdPub :: Bool, sdPos :: Pos, sdName :: Ident
  , sdGenerics :: [GenParam], sdFields :: [Param]
  } deriving (Show)

data Variant = Variant { varName :: Ident, varPayload :: [TypeExpr] }
  deriving (Show)

data EnumDecl = EnumDecl
  { edPub :: Bool, edPos :: Pos, edName :: Ident
  , edGenerics :: [GenParam], edVariants :: [Variant]
  } deriving (Show)

-- | A method of a trait or an impl.  The body is 'Nothing' for a trait method
-- without a default.
data Method = Method
  { mPos :: Pos
  , mName :: Ident
  , mParams :: [Param]   -- ^ excluding @self@
  , mRet :: Maybe TypeExpr
  , mBody :: Maybe Block
  } deriving (Show)

data TraitDecl = TraitDecl
  { tdPub :: Bool, tdPos :: Pos, tdName :: Ident, tdMethods :: [Method] }
  deriving (Show)

data ImplDecl = ImplDecl
  { idPos :: Pos, idGenerics :: [GenParam], idTrait :: TraitRef
  , idHead :: TypeExpr, idMethods :: [Method]
  } deriving (Show)

data TypeExpr = TypeExpr { tePos :: !Pos, teNode :: TypeNode }
  deriving (Show)

data TypeNode
  = TyList TypeExpr
  | TyMap TypeExpr TypeExpr
  | TyTuple [TypeExpr]
  | TyFn [TypeExpr] (Maybe TypeExpr)
  | TyPath (Maybe Ident) Ident [TypeExpr]
  deriving (Show)

data Block = Block { blockPos :: !Pos, blockStmts :: [Stmt], blockTail :: Maybe Expr }
  deriving (Show)

data Stmt
  = SLet Pos Pattern (Maybe TypeExpr) Expr
  | SVar Pos Ident (Maybe TypeExpr) Expr
  | SAssign Expr Expr
  | SExpr Expr
  | SReturn Pos (Maybe Expr)
  | SWhile Pos Expr Block
  | SFor Pos Pattern Expr (Maybe Expr) Block
  | SBreak Pos
  | SContinue Pos
  deriving (Show)

data Expr = Expr { exprPos :: !Pos, exprNode :: ExprNode }
  deriving (Show)

data BinOp
  = OpAdd | OpSub | OpMul | OpDiv | OpMod | OpConcat
  | OpBitAnd | OpBitOr | OpBitXor | OpShl | OpShr
  | OpLt | OpLe | OpGt | OpGe | OpEq | OpNe | OpAnd | OpOr
  deriving (Eq, Show)

data UnOp = UNeg | UNot | UBitNot
  deriving (Eq, Show)

data Lambda = Lambda
  { lamPos :: Pos
  , lamParams :: [(Ident, Maybe TypeExpr)]
  , lamRet :: Maybe TypeExpr
  , lamBody :: Expr   -- ^ a block body is an 'EBlock'
  } deriving (Show)

data Arm = Arm
  { armPat :: Pattern, armGuard :: Maybe Expr, armBody :: Expr }
  deriving (Show)

-- | @a@ or @m::a@.
data Path = Path { pathQual :: Maybe Ident, pathName :: Ident }
  deriving (Show)

data ExprNode
  = EInt Int
  | EFloat Double
  | EStr String
  | EChar Char
  | EBool Bool
  | ESelf
  | EPath Path
  | EStructLit Path [(Ident, Expr)]
  | ETuple [Expr]
  | EList [Expr]
  | EMap [(Expr, Expr)]
  | ELambda Lambda
  | EIf Expr Block (Maybe Expr)  -- ^ the else branch is an 'EBlock' or an 'EIf'
  | EMatch Expr [Arm]
  | EBlock Block
  | EUnary UnOp Expr
  | EBinary BinOp Expr Expr
  | ECall Expr [Expr]
  | EMethod Expr Ident [Expr]
  | EIndex Expr Expr
  | EField Expr Ident
  deriving (Show)

data Pattern = Pattern { patPos :: !Pos, patNode :: PatNode }
  deriving (Show)

data PatNode
  = PWild
  | PInt Int
  | PFloat
  | PStr String
  | PChar Char
  | PBool Bool
  | PTuple [Pattern]
  | PList [Pattern] (Maybe (Maybe Ident))   -- ^ rest: @Just Nothing@ is @..@, @Just (Just r)@ is @..r@
  | PStruct Path [(Ident, Maybe Pattern)] Bool
  | PVariant Path [Pattern]                  -- ^ with parentheses
  | PIdent Path                              -- ^ bare path: a binding or a nullary variant
  deriving (Show)
