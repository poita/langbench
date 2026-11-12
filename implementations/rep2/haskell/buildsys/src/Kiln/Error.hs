-- | The thirty kinds of build error and their log rendering.
module Kiln.Error
  ( BuildError (..)
  , Expected
  , renderError
  , errorKind
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

-- | A type token such as @str@ or @str|list@ as it appears in @E_TYPE@.
type Expected = B.ByteString

-- | Every way a build can fail. A build fails with exactly one of these.
data BuildError
  = EParse !B.ByteString !Int
    -- ^ build file path, 1-based line
  | EUnknownVar !B.ByteString
  | ERedefine !B.ByteString
  | ESetUndefined !B.ByteString
  | EType !B.ByteString !Expected !B.ByteString
    -- ^ site, expected, actual
  | EArity !B.ByteString !B.ByteString !B.ByteString !Int
    -- ^ kind (@fn@, @cmd@, @rule@), name, expected text, got
  | EUnknownFunc !B.ByteString
  | EUnknownRule !B.ByteString
  | EUnknownCmd !B.ByteString
  | EArg !B.ByteString !B.ByteString !B.ByteString
    -- ^ kind, name, reason
  | EIncludeMissing !B.ByteString
  | EIncludeCycle !B.ByteString
  | EBadPath !B.ByteString
  | EOutputPath !B.ByteString
  | EStepField !B.ByteString
  | ECmdShape !B.ByteString !B.ByteString
    -- ^ command name, reason
  | EDupOutput !B.ByteString
  | EDupPhony !B.ByteString
  | EMissingInput !B.ByteString !B.ByteString
    -- ^ target, requiring node
  | EUnknownTarget !B.ByteString
  | ECycle [B.ByteString]
  | ENoDefault
  | ERuleRecursion !B.ByteString
  | EDivZero
  | EInterp
  | EAbort !B.ByteString
  | ENoBuildFile
  | ENeedPath !B.ByteString
  | ENeedMissing !B.ByteString !B.ByteString
  | ENeedCycle !B.ByteString
  deriving (Eq, Show)

-- | The @E_…@ kind name.
errorKind :: BuildError -> B.ByteString
errorKind e = case e of
  EParse {} -> "E_PARSE"
  EUnknownVar {} -> "E_UNKNOWN_VAR"
  ERedefine {} -> "E_REDEFINE"
  ESetUndefined {} -> "E_SET_UNDEFINED"
  EType {} -> "E_TYPE"
  EArity {} -> "E_ARITY"
  EUnknownFunc {} -> "E_UNKNOWN_FUNC"
  EUnknownRule {} -> "E_UNKNOWN_RULE"
  EUnknownCmd {} -> "E_UNKNOWN_CMD"
  EArg {} -> "E_ARG"
  EIncludeMissing {} -> "E_INCLUDE_MISSING"
  EIncludeCycle {} -> "E_INCLUDE_CYCLE"
  EBadPath {} -> "E_BAD_PATH"
  EOutputPath {} -> "E_OUTPUT_PATH"
  EStepField {} -> "E_STEP_FIELD"
  ECmdShape {} -> "E_CMD_SHAPE"
  EDupOutput {} -> "E_DUP_OUTPUT"
  EDupPhony {} -> "E_DUP_PHONY"
  EMissingInput {} -> "E_MISSING_INPUT"
  EUnknownTarget {} -> "E_UNKNOWN_TARGET"
  ECycle {} -> "E_CYCLE"
  ENoDefault -> "E_NO_DEFAULT"
  ERuleRecursion {} -> "E_RULE_RECURSION"
  EDivZero -> "E_DIV_ZERO"
  EInterp -> "E_INTERP"
  EAbort {} -> "E_ABORT"
  ENoBuildFile -> "E_NO_BUILD_FILE"
  ENeedPath {} -> "E_NEED_PATH"
  ENeedMissing {} -> "E_NEED_MISSING"
  ENeedCycle {} -> "E_NEED_CYCLE"

-- | Render the @<KIND> <detail>@ part of a log @error@ line.
renderError :: BuildError -> B.ByteString
renderError e = case detail of
  Nothing -> errorKind e
  Just d -> B.concat [errorKind e, " ", d]
  where
    detail = case e of
      EParse f l -> Just (B.concat [f, ":", BC.pack (show l)])
      EUnknownVar n -> Just n
      ERedefine n -> Just n
      ESetUndefined n -> Just n
      EType site expected actual ->
        Just (B.concat [site, ": expected ", expected, ", got ", actual])
      EArity kind name expected got ->
        Just (B.concat [kind, " ", name, ": expected ", expected, ", got ", BC.pack (show got)])
      EUnknownFunc n -> Just n
      EUnknownRule n -> Just n
      EUnknownCmd n -> Just n
      EArg kind name reason -> Just (B.concat [kind, " ", name, ": ", reason])
      EIncludeMissing p -> Just p
      EIncludeCycle p -> Just p
      EBadPath s -> Just s
      EOutputPath p -> Just p
      EStepField r -> Just r
      ECmdShape n r -> Just (B.concat [n, ": ", r])
      EDupOutput p -> Just p
      EDupPhony n -> Just n
      EMissingInput t n -> Just (B.concat [t, " required by ", n])
      EUnknownTarget t -> Just t
      ECycle ns -> Just (B.intercalate " -> " ns)
      ENoDefault -> Nothing
      ERuleRecursion n -> Just n
      EDivZero -> Nothing
      EInterp -> Just "list"
      EAbort m -> Just m
      ENoBuildFile -> Just "main.kiln"
      ENeedPath r -> Just r
      ENeedMissing p by -> Just (B.concat [p, " needed by ", by])
      ENeedCycle p -> Just p
