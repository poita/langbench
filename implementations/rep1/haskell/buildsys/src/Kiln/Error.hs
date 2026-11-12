-- | The thirty error kinds of a Kiln build.
module Kiln.Error
  ( KilnError (..)
  , renderError
  , isExecutionError
  ) where

import Control.Exception (Exception)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC

-- | A build error.  Everything except the three @ENeed*@ constructors is a
-- configuration error; those three are raised while executing @preprocess@.
data KilnError
  = EParse !BS.ByteString !Int          -- ^ file, line
  | EUnknownVar !BS.ByteString
  | ERedefine !BS.ByteString
  | ESetUndefined !BS.ByteString
  | EType !BS.ByteString !BS.ByteString !BS.ByteString
    -- ^ site, expected, actual
  | EArity !BS.ByteString !BS.ByteString !BS.ByteString !Int
    -- ^ kind, name, expected (rendered), got
  | EUnknownFunc !BS.ByteString
  | EUnknownRule !BS.ByteString
  | EUnknownCmd !BS.ByteString
  | EArg !BS.ByteString !BS.ByteString !BS.ByteString
    -- ^ kind, name, reason
  | EIncludeMissing !BS.ByteString
  | EIncludeCycle !BS.ByteString
  | EBadPath !BS.ByteString
  | EOutputPath !BS.ByteString
  | EStepField !BS.ByteString
  | ECmdShape !BS.ByteString !BS.ByteString
    -- ^ command name, reason
  | EDupOutput !BS.ByteString
  | EDupPhony !BS.ByteString
  | EMissingInput !BS.ByteString !BS.ByteString
    -- ^ target, depending node
  | EUnknownTarget !BS.ByteString
  | ECycle [BS.ByteString]
  | ENoDefault
  | ERuleRecursion !BS.ByteString
  | EDivZero
  | EInterpList
  | EAbort !BS.ByteString
  | ENoBuildFile
  | ENeedPath !BS.ByteString
  | ENeedMissing !BS.ByteString !BS.ByteString
    -- ^ needed path, file containing the directive
  | ENeedCycle !BS.ByteString
  | EInternal !BS.ByteString
    -- ^ a violated internal invariant (never raised on valid input)
  deriving (Eq, Show)

instance Exception KilnError

-- | Is this one of the errors raised during command execution?
isExecutionError :: KilnError -> Bool
isExecutionError e = case e of
  ENeedPath _ -> True
  ENeedMissing _ _ -> True
  ENeedCycle _ -> True
  _ -> False

-- | The text after @  error @ in a log line: the kind and its detail.
renderError :: KilnError -> BS.ByteString
renderError e = case e of
  EParse f l -> k "E_PARSE" (f <> ":" <> int l)
  EUnknownVar n -> k "E_UNKNOWN_VAR" n
  ERedefine n -> k "E_REDEFINE" n
  ESetUndefined n -> k "E_SET_UNDEFINED" n
  EType site expected actual ->
    k "E_TYPE" (site <> ": expected " <> expected <> ", got " <> actual)
  EArity kind name expected got ->
    k "E_ARITY" (kind <> " " <> name <> ": expected " <> expected <> ", got " <> int got)
  EUnknownFunc n -> k "E_UNKNOWN_FUNC" n
  EUnknownRule n -> k "E_UNKNOWN_RULE" n
  EUnknownCmd n -> k "E_UNKNOWN_CMD" n
  EArg kind name reason -> k "E_ARG" (kind <> " " <> name <> ": " <> reason)
  EIncludeMissing p -> k "E_INCLUDE_MISSING" p
  EIncludeCycle p -> k "E_INCLUDE_CYCLE" p
  EBadPath s -> k "E_BAD_PATH" s
  EOutputPath p -> k "E_OUTPUT_PATH" p
  EStepField r -> k "E_STEP_FIELD" r
  ECmdShape name reason -> k "E_CMD_SHAPE" (name <> ": " <> reason)
  EDupOutput p -> k "E_DUP_OUTPUT" p
  EDupPhony n -> k "E_DUP_PHONY" n
  EMissingInput t by -> k "E_MISSING_INPUT" (t <> " required by " <> by)
  EUnknownTarget t -> k "E_UNKNOWN_TARGET" t
  ECycle ns -> k "E_CYCLE" (BS.intercalate " -> " ns)
  ENoDefault -> "E_NO_DEFAULT"
  ERuleRecursion n -> k "E_RULE_RECURSION" n
  EDivZero -> "E_DIV_ZERO"
  EInterpList -> "E_INTERP list"
  EAbort m -> k "E_ABORT" m
  ENoBuildFile -> "E_NO_BUILD_FILE main.kiln"
  ENeedPath r -> k "E_NEED_PATH" r
  ENeedMissing p by -> k "E_NEED_MISSING" (p <> " needed by " <> by)
  ENeedCycle p -> k "E_NEED_CYCLE" p
  EInternal m -> k "E_INTERNAL" m
  where
    k kind detail = kind <> " " <> detail
    int = BC.pack . show
