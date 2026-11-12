-- | The @.kiln-state@ file: strict parsing, canonical rendering and the
-- freshness decision.
module Kiln.State
  ( Entry (..)
  , StateMap
  , parseState
  , renderState
  , isFresh
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Kiln.Command (renderCommand)
import Kiln.Hash (Hash, hashHex, parseHashHex)
import Kiln.Path (isWorkspacePath)
import Kiln.Step
import Kiln.Workspace (Workspace, fileHash, lookupFile)

-- | What was recorded about one executed step.
data Entry = Entry
  { entCmd :: !BS.ByteString
  , entIns :: [(BS.ByteString, Hash)]
  , entDeps :: [(BS.ByteString, Hash)]
  , entOuts :: [(BS.ByteString, Hash)]
  }
  deriving (Eq, Show)

-- | Entries keyed by primary output path.
type StateMap = Map BS.ByteString Entry

-- | Parse a state file.  Anything that deviates from the grammar yields the
-- empty state.
parseState :: BS.ByteString -> StateMap
parseState content
  | BS.null content || BS.last content /= 0x0a = Map.empty
  | otherwise = case BS.split 0x0a (BS.init content) of
      "kiln-state 1" : rest -> maybe Map.empty id (entries Map.empty rest)
      _ -> Map.empty
  where
    entries acc [] = Just acc
    entries acc (l : ls) = do
      key <- field "step " l
      if not (isWorkspacePath key) then Nothing else Just ()
      (cmdLine, ls1) <- uncons' ls
      cmd <- field "cmd " cmdLine
      if BS.null cmd then Nothing else Just ()
      (ins, ls2) <- hashed "in " ls1
      (deps, ls3) <- hashed "dep " ls2
      (outs, ls4) <- hashed "out " ls3
      case ls4 of
        "end" : rest -> do
          case outs of
            (o, _) : _ | o == key && not (Map.member key acc) -> Just ()
            _ -> Nothing
          entries (Map.insert key (Entry cmd ins deps outs) acc) rest
        _ -> Nothing
    uncons' xs = case xs of
      [] -> Nothing
      y : ys -> Just (y, ys)
    field prefix l
      | prefix `BS.isPrefixOf` l = Just (BS.drop (BS.length prefix) l)
      | otherwise = Nothing
    -- zero or more lines with the given prefix, each "<path> <hash>"
    hashed prefix ls = case ls of
      l : rest | Just r <- field prefix l -> do
        pair <- pathHash r
        (more, rest') <- hashed prefix rest
        Just (pair : more, rest')
      _ -> Just ([], ls)
    pathHash r = case BC.break (== ' ') r of
      (p, h)
        | isWorkspacePath p, Just h' <- BS.stripPrefix " " h, Just hv <- parseHashHex h' -> Just (p, hv)
      _ -> Nothing

-- | Render the state canonically: entries sorted by key.
renderState :: StateMap -> BS.ByteString
renderState m =
  BS.concat $
    "kiln-state 1\n"
      : concat
        [ ["step ", k, "\n", "cmd ", entCmd e, "\n"]
            ++ concat [["in ", p, " ", hashHex h, "\n"] | (p, h) <- entIns e]
            ++ concat [["dep ", p, " ", hashHex h, "\n"] | (p, h) <- entDeps e]
            ++ concat [["out ", p, " ", hashHex h, "\n"] | (p, h) <- entOuts e]
            ++ ["end\n"]
        | (k, e) <- Map.toAscList m
        ]

-- | The change-detection decision: is the step fresh given its recorded entry?
isFresh :: Workspace -> Step -> Maybe Entry -> Bool
isFresh _ _ Nothing = False
isFresh ws step (Just e) =
  entCmd e == renderCommand (stepCommand step)
    && map fst (entOuts e) == stepFullOutputs step
    && map fst (entIns e) == stepFileInputs step
    && all same (entIns e)
    && all same (entDeps e)
    && all same (entOuts e)
  where
    same (p, h) = maybe False ((== h) . fileHash) (lookupFile p ws)
