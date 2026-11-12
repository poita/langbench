-- | The step graph: whole-graph validation, target resolution, cycle
-- detection and reachability.
module Kiln.Graph
  ( Node (..)
  , Index (..)
  , buildIndex
  , resolveRef
  , nodeName
  , successors
  , requestedTargets
  , reachable
  ) where

import Control.Monad (foldM, forM_, unless)
import Data.Array
import qualified Data.ByteString as B
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Kiln.Error
import Kiln.Eval
import Kiln.Step
import Kiln.Workspace

-- | A node of the dependency graph.
data Node
  = NStep !Int
    -- ^ by serial number
  | NPhony !B.ByteString
    -- ^ by name, without the @\@@
  | NSource !Path
  deriving (Eq, Ord, Show)

-- | Everything needed to resolve references and walk the graph.
data Index = Index
  { ixSteps :: Array Int Step
  , ixPhonies :: M.Map B.ByteString [B.ByteString]
  , ixPhonyOrder :: [B.ByteString]
  , ixOutputs :: M.Map Path Int
    -- ^ every output path (declared and depfile) to its step's serial
  , ixDefaults :: [B.ByteString]
  , ixWorkspace :: Workspace
  }

-- | Whole-graph validation: duplicate outputs, then reference resolution,
-- then the default list.
buildIndex :: Workspace -> Program -> Either BuildError Index
buildIndex ws prog = do
  let steps = progSteps prog
      n = length steps
      stepArr = listArray (0, n - 1) steps
  outs <- foldM claim M.empty [(stepSerial s, p) | s <- steps, p <- stepOutputs s]
  let ix =
        Index
          { ixSteps = stepArr
          , ixPhonies = M.fromList (progPhonies prog)
          , ixPhonyOrder = map fst (progPhonies prog)
          , ixOutputs = outs
          , ixDefaults = progDefaults prog
          , ixWorkspace = ws
          }
  forM_ steps $ \s ->
    forM_ (stepIns s ++ stepAfter s) $ \r ->
      unless (resolves ix r) (Left (EMissingInput r (stepPrimary s)))
  forM_ (progPhonies prog) $ \(name, deps) ->
    forM_ deps $ \r ->
      unless (resolves ix r) (Left (EMissingInput r ("@" <> name)))
  forM_ (progDefaults prog) $ \r ->
    unless (resolves ix r) (Left (EUnknownTarget r))
  pure ix
  where
    claim m (serial, p)
      | M.member p m = Left (EDupOutput p)
      | otherwise = Right (M.insert p serial m)

resolves :: Index -> B.ByteString -> Bool
resolves ix r = case resolveRef ix r of Just _ -> True; Nothing -> False

-- | Resolve a target reference to a node.
resolveRef :: Index -> B.ByteString -> Maybe Node
resolveRef ix r = case B.uncons r of
  Just (64, name) -> NPhony name <$ M.lookup name (ixPhonies ix)
  _ -> case M.lookup r (ixOutputs ix) of
    Just serial -> Just (NStep serial)
    Nothing
      | member r (ixWorkspace ix) -> Just (NSource r)
      | otherwise -> Nothing

-- | The name of a node in messages.
nodeName :: Index -> Node -> B.ByteString
nodeName ix n = case n of
  NStep s -> stepPrimary (ixSteps ix ! s)
  NPhony p -> "@" <> p
  NSource p -> p

-- | The distinct nodes a node depends on, in first-occurrence order.
successors :: Index -> Node -> [Node]
successors ix n = dedup $ case n of
  NStep s ->
    let st = ixSteps ix ! s
     in map res (stepIns st ++ stepAfter st)
  NPhony p -> map res (fromMaybe [] (M.lookup p (ixPhonies ix)))
  NSource _ -> []
  where
    res r = fromMaybe (error "successors: unresolved reference") (resolveRef ix r)
    dedup = go S.empty
      where
        go _ [] = []
        go seen (x : xs)
          | S.member x seen = go seen xs
          | otherwise = x : go (S.insert x seen) xs

-- | The requested targets as nodes: the named targets, or the default list,
-- with duplicates removed keeping the first.
requestedTargets :: Index -> [B.ByteString] -> Either BuildError [Node]
requestedTargets ix named = do
  let names = dedupe (if null named then ixDefaults ix else named)
  if null names
    then Left ENoDefault
    else mapM (\r -> maybe (Left (EUnknownTarget r)) Right (resolveRef ix r)) names
  where
    dedupe = go S.empty
      where
        go _ [] = []
        go seen (x : xs)
          | S.member x seen = go seen xs
          | otherwise = x : go (S.insert x seen) xs

data Colour = Grey | Black

-- | Depth-first search from the requested nodes using the specified order.
-- 'Left' is a cycle (as node names); 'Right' is the reachable set.
reachable :: Index -> [Node] -> Either BuildError (S.Set Node)
reachable ix roots = go M.empty roots
  where
    go colour [] = Right (M.keysSet colour)
    go colour (r : rs)
      | M.member r colour = go colour rs
      | otherwise = do
          colour' <- walk (M.insert r Grey colour) [(r, successors ix r)]
          go colour' rs
    walk colour [] = Right colour
    walk colour ((n, []) : rest) = walk (M.insert n Black colour) rest
    walk colour ((n, m : ms) : rest) = case M.lookup m colour of
      Just Grey ->
        let path = reverse (takeThrough m (n : map fst rest))
         in Left (ECycle (map (nodeName ix) (path ++ [m])))
      Just Black -> walk colour ((n, ms) : rest)
      Nothing -> walk (M.insert m Grey colour) ((m, successors ix m) : (n, ms) : rest)
    -- stack nodes from the top down to and including the target
    takeThrough m (x : xs)
      | x == m = [x]
      | otherwise = x : takeThrough m xs
    takeThrough _ [] = []
