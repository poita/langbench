-- | A build step as produced by evaluating a build file.
module Kiln.Step
  ( Step (..)
  , stepPrimary
  , stepOutputs
  , stepFileInputs
  , isPhonyRef
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

import Kiln.Command
import Kiln.Workspace (Path)

data Step = Step
  { stepSerial :: !Int
    -- ^ creation order across the whole build
  , stepDeclaredOuts :: [Path]
  , stepDepfile :: Maybe Path
  , stepIns :: [B.ByteString]
    -- ^ declared inputs, including phony references
  , stepAfter :: [B.ByteString]
  , stepCommand :: Command
  , stepCost :: !Int
  }
  deriving (Show)

-- | The first declared output; the step's name in messages and the state.
stepPrimary :: Step -> Path
stepPrimary s = case stepDeclaredOuts s of
  p : _ -> p
  [] -> error "stepPrimary: a step always has an output"

-- | Declared outputs followed by the depfile.
stepOutputs :: Step -> [Path]
stepOutputs s = stepDeclaredOuts s ++ maybe [] pure (stepDepfile s)

-- | Declared inputs that are not phony references, in order.
stepFileInputs :: Step -> [Path]
stepFileInputs = filter (not . isPhonyRef) . stepIns

isPhonyRef :: B.ByteString -> Bool
isPhonyRef r = BC.take 1 r == "@"
