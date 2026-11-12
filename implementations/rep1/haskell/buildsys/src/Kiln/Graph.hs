-- | The dependency graph: whole-graph validation, target resolution,
-- deterministic cycle detection and reachability.
module Kiln.Graph
  ( Graph (..)
  , Node
  , buildGraph
  , resolveRequested
  , findReachable
  , nodeName
  , isStepNode
  ) where

import Data.Array (Array, bounds, listArray, (!))
import qualified Data.ByteString as BS
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Kiln.Error
import Kiln.Eval (Decls (..))
import Kiln.Path (isPhonyRef)
import Kiln.Step (Phony (..), Step (..), stepFullOutputs, stepPrimary)
import Kiln.Workspace (Workspace, member)

-- | A graph node: steps are numbered by serial @0..S-1@, phony targets
-- @S..S+P-1@.  Source files never block anything and cannot lie on a cycle,
-- so they are not nodes; they only matter for reference resolution.
type Node = Int

data Graph = Graph
  { grSteps :: Array Int Step
  , grPhonies :: Array Int Phony
  , grNumSteps :: !Int
  , grSucc :: Array Int [Node]
    -- ^ ordering dependencies (sources dropped, duplicates removed), for every node
  , grDefaults :: [BS.ByteString]
  , grResolve :: BS.ByteString -> Maybe (Maybe Node)
    -- ^ resolve a target reference: @Nothing@ = unresolvable, @Just Nothing@ = a
    -- source file, @Just (Just n)@ = a node
  }

isStepNode :: Graph -> Node -> Bool
isStepNode g n = n < grNumSteps g

-- | The name used for a node in messages and cycle reports.
nodeName :: Graph -> Node -> BS.ByteString
nodeName g n
  | isStepNode g n = stepPrimary (grSteps g ! n)
  | otherwise = "@" <> phonyName (grPhonies g ! (n - grNumSteps g))

-- | Whole-graph validation (duplicate outputs, reference resolution, default
-- list), producing the graph.
buildGraph :: Workspace -> Decls -> Either KilnError Graph
buildGraph ws decls = do
  checkDuplicates
  stepSuccs <- mapM stepDeps steps
  phonySuccs <- mapM phonyEdges phonies
  mapM_ (\t -> maybe (Left (EUnknownTarget t)) (const (Right ())) (resolve t)) (declDefaults decls)
  let succs = map dedup (stepSuccs ++ phonySuccs)
  Right
    Graph
      { grSteps = arr nSteps steps
      , grPhonies = arr (length phonies) phonies
      , grNumSteps = nSteps
      , grSucc = arr (nSteps + length phonies) succs
      , grDefaults = declDefaults decls
      , grResolve = resolve
      }
  where
    steps = declSteps decls
    phonies = declPhonies decls
    nSteps = length steps
    arr n xs = listArray (0, n - 1) xs
    outMap = Map.fromList [(o, stepSerial s) | s <- steps, o <- stepFullOutputs s]
    phonyMap = Map.fromList (zip (map phonyName phonies) [nSteps ..])
    resolve :: BS.ByteString -> Maybe (Maybe Node)
    resolve t
      | isPhonyRef t = Just <$> Map.lookup (BS.drop 1 t) phonyMap
      | otherwise = case Map.lookup t outMap of
          Just n -> Just (Just n)
          Nothing -> if member t ws then Just Nothing else Nothing
    checkDuplicates = go Set.empty [o | s <- steps, o <- stepFullOutputs s]
      where
        go _ [] = Right ()
        go seen (o : os)
          | Set.member o seen = Left (EDupOutput o)
          | otherwise = go (Set.insert o seen) os
    resolveAll by refs = fmap (concatMap (maybe [] pure)) $ mapM (\r -> maybe (Left (EMissingInput r by)) Right (resolve r)) refs
    stepDeps s = resolveAll (stepPrimary s) (stepInputs s ++ stepAfter s)
    phonyEdges p = resolveAll ("@" <> phonyName p) (phonyDeps p)
    dedup = go IS.empty
      where
        go _ [] = []
        go seen (x : xs)
          | IS.member x seen = go seen xs
          | otherwise = x : go (IS.insert x seen) xs

-- | Resolve the requested targets: those on the build line, or the default
-- list; deduplicated keeping first occurrences.
resolveRequested :: Graph -> [BS.ByteString] -> Either KilnError [Node]
resolveRequested g named = do
  names <- case named of
    [] -> if null (grDefaults g) then Left ENoDefault else Right (nubKeep (grDefaults g))
    _ -> Right (nubKeep named)
  fmap (concatMap (maybe [] pure)) $
    mapM (\t -> maybe (Left (EUnknownTarget t)) Right (grResolve g t)) names

nubKeep :: [BS.ByteString] -> [BS.ByteString]
nubKeep = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member x seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs

data Colour = Grey | Black

-- | Depth-first cycle search from the roots, exactly as specified.  On success
-- returns the reachable set; on failure the nodes of the cycle, first and last equal.
findReachable :: Graph -> [Node] -> Either [Node] IS.IntSet
findReachable g roots = IM.keysSet <$> foldlE visit IM.empty roots
  where
    (_, hi) = bounds (grSucc g)
    succs n = if n >= 0 && n <= hi then grSucc g ! n else []
    foldlE f z xs = case xs of
      [] -> Right z
      x : rest -> f z x >>= \z' -> foldlE f z' rest
    visit :: IntMap Colour -> Node -> Either [Node] (IntMap Colour)
    visit col root = case IM.lookup root col of
      Just _ -> Right col
      Nothing -> dfs (IM.insert root Grey col) [(root, succs root)]
    dfs col [] = Right col
    dfs col ((n, []) : rest) = dfs (IM.insert n Black col) rest
    dfs col stack@((n, m : ms) : rest) = case IM.lookup m col of
      Just Grey -> Left (dropWhile (/= m) (reverse (map fst stack)) ++ [m])
      Just Black -> dfs col ((n, ms) : rest)
      Nothing -> dfs (IM.insert m Grey col) ((m, succs m) : (n, ms) : rest)
