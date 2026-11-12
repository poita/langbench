-- | The @.kiln-state@ file: strict parsing, canonical rendering and the
-- freshness decision.
module Kiln.State
  ( Entry (..)
  , StateMap
  , parseState
  , renderState
  , isFresh
  ) where

import Control.Monad (guard)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as M

import Kiln.Hash
import Kiln.Workspace

-- | What Kiln remembers about one executed step.
data Entry = Entry
  { entCmd :: !B.ByteString
  , entIns :: [(Path, Hash)]
  , entDeps :: [(Path, Hash)]
  , entOuts :: [(Path, Hash)]
  }
  deriving (Eq, Show)

-- | Entries keyed by primary output path.
type StateMap = M.Map Path Entry

-- | Parse a state file. Anything that deviates from the grammar yields the
-- empty state.
parseState :: B.ByteString -> StateMap
parseState bs
  | B.null bs || B.last bs /= 10 = M.empty
  | otherwise = case init (B.split 10 bs) of
      "kiln-state 1" : rest -> maybe M.empty id (entries rest M.empty)
      _ -> M.empty
  where
    entries [] m = Just m
    entries ls m = do
      (key, e, rest) <- entry ls
      if M.member key m then Nothing else entries rest (M.insert key e m)

entry :: [B.ByteString] -> Maybe (Path, Entry, [B.ByteString])
entry (s : c : rest) = do
  key <- B.stripPrefix "step " s
  guard (isWorkspacePath key)
  cmd <- B.stripPrefix "cmd " c
  guard (not (B.null cmd))
  let (ins, r1) = spanFiles "in " rest
      (deps, r2) = spanFiles "dep " r1
      (outs, r3) = spanFiles "out " r2
  case r3 of
    "end" : r4 -> case outs of
      (p, _) : _ | p == key -> Just (key, Entry cmd ins deps outs, r4)
      _ -> Nothing
    _ -> Nothing
entry _ = Nothing

spanFiles :: B.ByteString -> [B.ByteString] -> ([(Path, Hash)], [B.ByteString])
spanFiles pfx = go []
  where
    go acc (l : ls)
      | Just r <- B.stripPrefix pfx l, Just x <- fileLine r = go (x : acc) ls
    go acc ls = (reverse acc, ls)

fileLine :: B.ByteString -> Maybe (Path, Hash)
fileLine r = case B.split 32 r of
  [p, h] | isWorkspacePath p -> (,) p <$> parseHash h
  _ -> Nothing

-- | Render the state file: entries sorted by primary output.
renderState :: StateMap -> B.ByteString
renderState m =
  B.concat ("kiln-state 1\n" : concatMap one (M.toAscList m))
  where
    one (key, Entry cmd ins deps outs) =
      ["step ", key, "\ncmd ", cmd, "\n"]
        ++ concatMap (line "in ") ins
        ++ concatMap (line "dep ") deps
        ++ concatMap (line "out ") outs
        ++ ["end\n"]
    line k (p, h) = [k, p, " ", renderHash h, "\n"]

-- | Decide whether a step is fresh: given its recorded entry (if any), its
-- canonical command, full output list and file-input list, and the
-- workspace as it stands now.
isFresh :: Workspace -> Maybe Entry -> B.ByteString -> [Path] -> [Path] -> Bool
isFresh _ Nothing _ _ _ = False
isFresh ws (Just e) cmd outs ins =
  entCmd e == cmd
    && map fst (entOuts e) == outs
    && map fst (entIns e) == ins
    && all same (entIns e)
    && all same (entDeps e)
    && all same (entOuts e)
  where
    same (p, h) = maybe False ((== h) . fileHash) (lookupFile p ws)
