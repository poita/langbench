-- | Source positions and the single-line diagnostics a rejected program
-- produces (SPEC.md section 13).
module Langvm.Diagnostic
  ( Pos (..)
  , Kind (..)
  , Diagnostic (..)
  , kindName
  , renderDiagnostic
  ) where

-- | A 1-based line and column.  Columns count Unicode scalar values.
data Pos = Pos { posLine :: !Int, posCol :: !Int }
  deriving (Eq, Ord, Show)

-- | Every kind of compile-time error (section 13.4).
data Kind
  = BadModule | DupModule | BadToken | IntRange | BadEscape | Unterminated
  | ParseError | ReservedName | DupName | UnknownModule | UnknownType
  | UnknownTrait | NotPublic | ArityType | BadArity | BadKeyType | SelfOutside
  | BuiltinTraitImpl | BadImplHead | UnusedParam | DupImpl | MissingMethod
  | ExtraMethod | SigMismatch | NoMain | UnknownName | TypeMismatch | Arity
  | NotCallable | NotStruct | UnknownField | MissingField | DupField
  | NotIndexable | NotIterable | NoMethod | AmbigMethod | UnsatisfiedBound
  | NotEq | NotOrd | CannotInfer | NonExhaustive | Unreachable | MissingReturn
  | BadValueRef | BadPattern | RefutablePattern | BreakOutside
  | AssignImmutable | AssignCaptured | BadTarget
  deriving (Eq, Show, Enum, Bounded)

-- | The spelling of a kind in the diagnostic line.
kindName :: Kind -> String
kindName k = case k of
  BadModule -> "bad-module"; DupModule -> "dup-module"; BadToken -> "bad-token"
  IntRange -> "int-range"; BadEscape -> "bad-escape"
  Unterminated -> "unterminated"; ParseError -> "parse"
  ReservedName -> "reserved-name"; DupName -> "dup-name"
  UnknownModule -> "unknown-module"; UnknownType -> "unknown-type"
  UnknownTrait -> "unknown-trait"; NotPublic -> "not-public"
  ArityType -> "arity-type"; BadArity -> "bad-arity"
  BadKeyType -> "bad-key-type"; SelfOutside -> "self-outside"
  BuiltinTraitImpl -> "builtin-trait-impl"; BadImplHead -> "bad-impl-head"
  UnusedParam -> "unused-param"; DupImpl -> "dup-impl"
  MissingMethod -> "missing-method"; ExtraMethod -> "extra-method"
  SigMismatch -> "sig-mismatch"; NoMain -> "no-main"
  UnknownName -> "unknown-name"; TypeMismatch -> "type-mismatch"
  Arity -> "arity"; NotCallable -> "not-callable"; NotStruct -> "not-struct"
  UnknownField -> "unknown-field"; MissingField -> "missing-field"
  DupField -> "dup-field"; NotIndexable -> "not-indexable"
  NotIterable -> "not-iterable"; NoMethod -> "no-method"
  AmbigMethod -> "ambig-method"; UnsatisfiedBound -> "unsatisfied-bound"
  NotEq -> "not-eq"; NotOrd -> "not-ord"; CannotInfer -> "cannot-infer"
  NonExhaustive -> "non-exhaustive"; Unreachable -> "unreachable"
  MissingReturn -> "missing-return"; BadValueRef -> "bad-value-ref"
  BadPattern -> "bad-pattern"; RefutablePattern -> "refutable-pattern"
  BreakOutside -> "break-outside"; AssignImmutable -> "assign-immutable"
  AssignCaptured -> "assign-captured"; BadTarget -> "bad-target"

-- | A compile-time error: its kind and where it was found.
data Diagnostic = Diagnostic { diagKind :: !Kind, diagPos :: !Pos }
  deriving (Eq, Show)

-- | @error: \<kind\> at \<line\>:\<col\>@ (without the trailing newline).
renderDiagnostic :: Diagnostic -> String
renderDiagnostic (Diagnostic k (Pos l c)) =
  "error: " ++ kindName k ++ " at " ++ show l ++ ":" ++ show c
