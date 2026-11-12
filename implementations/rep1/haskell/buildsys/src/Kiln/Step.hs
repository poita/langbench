-- | Build steps and phony targets, and the validation applied when a @step@
-- block closes.
module Kiln.Step
  ( Step (..)
  , Phony (..)
  , StepDraft (..)
  , emptyDraft
  , validateStep
  , validateReference
  , stepPrimary
  , stepFullOutputs
  , stepFileInputs
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (maybeToList)

import Kiln.Command
import Kiln.Error
import Kiln.Path

-- | A validated build step.
data Step = Step
  { stepSerial :: !Int
  , stepOutputs :: [BS.ByteString]
    -- ^ declared outputs (non-empty)
  , stepDepfile :: Maybe BS.ByteString
  , stepInputs :: [BS.ByteString]
    -- ^ declared @in@ entries, phony references included
  , stepAfter :: [BS.ByteString]
  , stepCommand :: Command
  , stepCost :: !Int
  }
  deriving (Show)

-- | A phony target: a name (without the @\@@) and its ordering-only dependencies.
data Phony = Phony
  { phonyName :: !BS.ByteString
  , phonyDeps :: [BS.ByteString]
  }
  deriving (Show)

-- | A step under construction while its fields are processed.
data StepDraft = StepDraft
  { draftOuts :: [BS.ByteString]
  , draftIns :: [BS.ByteString]
  , draftAfter :: [BS.ByteString]
  , draftCost :: Maybe Int
  , draftDepfile :: Maybe BS.ByteString
  , draftCmd :: Maybe Command
  }

emptyDraft :: StepDraft
emptyDraft = StepDraft [] [] [] Nothing Nothing Nothing

-- | The first declared output.
stepPrimary :: Step -> BS.ByteString
stepPrimary s = case stepOutputs s of
  p : _ -> p
  [] -> BS.empty

-- | Declared outputs followed by the depfile, if any.
stepFullOutputs :: Step -> [BS.ByteString]
stepFullOutputs s = stepOutputs s ++ maybeToList (stepDepfile s)

-- | The declared inputs that are not phony references, in order.
stepFileInputs :: Step -> [BS.ByteString]
stepFileInputs = filter (not . isPhonyRef) . stepInputs

-- | A reference in @in@, @after@ or a phony's dependency list must be @\@name@
-- or a workspace path.
validateReference :: BS.ByteString -> Either KilnError ()
validateReference r
  | isPhonyRef r = if isIdentifierShaped (BS.drop 1 r) then Right () else Left (EBadPath r)
  | isWorkspacePath r = Right ()
  | otherwise = Left (EBadPath r)

-- | Validate a finished draft, in the specified order, assigning a serial.
validateStep :: Int -> StepDraft -> Either KilnError Step
validateStep serial d = do
  cmd <- maybe (Left (EStepField "missing cmd")) Right (draftCmd d)
  if null (draftOuts d) then Left (EStepField "missing out") else Right ()
  mapM_ outputPath (draftOuts d ++ maybeToList (draftDepfile d))
  mapM_ validateReference (draftIns d ++ draftAfter d)
  let kind = cmdKind cmd
      name = cmdName kind
      fileIns = length (filter (not . isPhonyRef) (draftIns d))
      (lo, hi) = cmdInputRange kind
      tooMany = maybe False (fileIns >) hi
  if fileIns < lo || tooMany
    then
      Left
        ( ECmdShape name $
            "expected inputs " <> BC.pack (show lo) <> "-" <> maybe "N" (BC.pack . show) hi
              <> ", got " <> BC.pack (show fileIns)
        )
    else Right ()
  if length (draftOuts d) /= 1
    then Left (ECmdShape name ("expected outputs 1, got " <> BC.pack (show (length (draftOuts d)))))
    else Right ()
  case (cmdUsesDepfile kind, draftDepfile d) of
    (True, Nothing) -> Left (ECmdShape name "depfile required")
    (False, Just _) -> Left (ECmdShape name "depfile not allowed")
    _ -> Right ()
  case (kind, cmdArgs cmd) of
    (CmdReplace, CStr f : _) | BS.null f -> Left (EArg "cmd" "replace" "empty pattern")
    (CmdIndent, CInt n : _) | n < 0 -> Left (EArg "cmd" "indent" "negative")
    _ -> Right ()
  Right
    Step
      { stepSerial = serial
      , stepOutputs = draftOuts d
      , stepDepfile = draftDepfile d
      , stepInputs = draftIns d
      , stepAfter = draftAfter d
      , stepCommand = cmd
      , stepCost = maybe (cmdDefaultCost kind) id (draftCost d)
      }
  where
    outputPath p
      | not (isWorkspacePath p) = Left (EBadPath p)
      | not (isGenerated p) = Left (EOutputPath p)
      | otherwise = Right ()
