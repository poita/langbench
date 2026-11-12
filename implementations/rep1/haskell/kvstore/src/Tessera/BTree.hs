{-# LANGUAGE OverloadedStrings #-}

-- | The B+tree of SPEC §12: search, insert/replace, split, delete with
-- borrow/merge repair, and ordered traversal.  The primary tree and every
-- index tree share this implementation; a 'Tree' says where the root lives
-- and which kind of leaf the tree uses.
module Tessera.BTree
  ( Tree
  , primaryTree
  , indexTree
  , treeRoot
  , lookupCell
  , insertCell
  , deleteKey
  , foldFrom
  , foldReverse
  , postOrderPages
  , treeHeight
  ) where

import Control.Monad (when)
import qualified Data.ByteString as BS
import qualified Data.IntMap.Strict as IntMap
import Tessera.Constants (capacity, minFill)
import Tessera.Page
import Tessera.Pager

-- | A handle on one tree.
data Tree = Tree
  { treeKind :: !LeafKind
  , treeRoot :: IO Int
  -- ^ current root page, 0 when empty
  , treeSetRoot :: Int -> IO ()
  }

-- | The primary tree, rooted in the header.
primaryTree :: Db -> Tree
primaryTree db =
  Tree PrimaryLeaf (hPrimaryRoot <$> getHeader db) (\r -> modifyHeader db (\h -> h {hPrimaryRoot = r}))

-- | The tree of the index in directory slot @s@.
indexTree :: Db -> Int -> Tree
indexTree db s =
  Tree
    IndexLeaf
    (maybe 0 slotRoot . IntMap.lookup s . hSlots <$> getHeader db)
    (\r -> modifyHeader db (\h -> h {hSlots = IntMap.adjust (\sl -> sl {slotRoot = r}) s (hSlots h)}))

readNode :: Db -> Int -> IO Node
readNode db p = decodeNode <$> readPage db p

writeNode :: Db -> Int -> Node -> IO ()
writeNode db p node = writePage db p (encodeNode node)

-- | An interior page visited on the way down: its number, cells, rightmost
-- child, and the child index taken.
data Step = Step !Int [(BS.ByteString, Int)] !Int !Int

data Located = Located !Int !LeafKind [Cell] !Int [Step]

chooseChild :: [(BS.ByteString, Int)] -> Int -> BS.ByteString -> (Int, Int)
chooseChild cells lnk key = go 0 cells
  where
    go !i ((k, c) : rest)
      | key <= k = (i, c)
      | otherwise = go (i + 1) rest
    go i [] = (i, lnk)

descend :: Db -> Int -> BS.ByteString -> IO Located
descend db root key = go root []
  where
    go p path = do
      node <- readNode db p
      case node of
        Interior cells lnk ->
          let (j, child) = chooseChild cells lnk key in go child (Step p cells lnk j : path)
        Leaf k cs nxt -> pure (Located p k cs nxt path)

-- | Find the cell with exactly this key.
lookupCell :: Db -> Tree -> BS.ByteString -> IO (Maybe Cell)
lookupCell db tree key = do
  root <- treeRoot tree
  if root == 0
    then pure Nothing
    else do
      Located _ _ cs _ _ <- descend db root key
      pure (case filter ((== key) . cellKey) cs of c : _ -> Just c; [] -> Nothing)

-- | Insert a cell, replacing any cell with the same key in place (SPEC §12.2).
insertCell :: Db -> Tree -> Cell -> IO ()
insertCell db tree cell = do
  root0 <- treeRoot tree
  root <-
    if root0 /= 0
      then pure root0
      else do
        r <- allocatePage db
        writeNode db r (Leaf (treeKind tree) [] 0)
        treeSetRoot tree r
        pure r
  Located p k cs nxt path <- descend db root (cellKey cell)
  let (before, after) = span ((< cellKey cell) . cellKey) cs
      cs' = case after of
        c : rest | cellKey c == cellKey cell -> before ++ cell : rest
        _ -> before ++ cell : after
  storeNode db tree p (Leaf k cs' nxt) path

-- | The split index @m@ of SPEC §12.3: the smallest @m >= 1@ with
-- @2 * P[m] >= T@.
splitPoint :: [Int] -> Int
splitPoint costs = go 1 (drop 1 (scanl (+) 0 costs))
  where
    total = sum costs
    go !m (pm : more)
      | 2 * pm >= total || null more = m
      | otherwise = go (m + 1) more
    go m [] = m

-- | Split an overflowing node; @right@ is the page number of the new sibling.
splitNode :: Node -> Int -> (Node, BS.ByteString, Node)
splitNode node right = case node of
  Leaf k cs nxt ->
    let (l, r) = splitAt m cs in (Leaf k l right, cellKey (last l), Leaf k r nxt)
  Interior cs lnk -> case splitAt (m - 1) cs of
    (l, (sepKey, sepChild) : r) -> (Interior l sepChild, sepKey, Interior r lnk)
    _ -> error "splitNode: interior page too small to split"
  where
    m = splitPoint (nodeCosts node)

-- | Store a node at page @p@, splitting it (and its ancestors) as needed.
storeNode :: Db -> Tree -> Int -> Node -> [Step] -> IO ()
storeNode db tree p node path
  | nodeUsed node <= capacity = writeNode db p node
  | otherwise = do
      right <- allocatePage db
      let (leftN, sep, rightN) = splitNode node right
      writeNode db p leftN
      writeNode db right rightN
      case path of
        [] -> do
          newRoot <- allocatePage db
          writeNode db newRoot (Interior [(sep, p)] right)
          treeSetRoot tree newRoot
        Step pp cells lnk j : rest
          | j == length cells -> storeNode db tree pp (Interior (cells ++ [(sep, p)]) right) rest
          | otherwise ->
              let (a, b) = splitAt j cells
               in case b of
                    (k, _) : b' -> storeNode db tree pp (Interior (a ++ (sep, p) : (k, right) : b') lnk) rest
                    [] -> error "storeNode: bad path"

-- | Delete a key; 'False' if it was absent (SPEC §12.4).
deleteKey :: Db -> Tree -> BS.ByteString -> IO Bool
deleteKey db tree key = do
  root <- treeRoot tree
  if root == 0
    then pure False
    else do
      Located p k cs nxt path <- descend db root key
      case break ((== key) . cellKey) cs of
        (_, []) -> pure False
        (a, _ : b) -> do
          let node = Leaf k (a ++ b) nxt
          case path of
            []
              | null (a ++ b) -> freePage db p >> treeSetRoot tree 0
              | otherwise -> writeNode db p node
            _
              | nodeUsed node >= minFill -> writeNode db p node
              | otherwise -> repair db tree p node path
          pure True

setSep :: Int -> BS.ByteString -> [(BS.ByteString, Int)] -> [(BS.ByteString, Int)]
setSep i k cells = [if idx == i then (k, c) else (kk, c) | (idx, (kk, c)) <- zip [0 ..] cells]

-- | Repair an underflowing page: borrow left, borrow right, merge left,
-- merge right (SPEC §12.5).  The node's page has not been written yet.
repair :: Db -> Tree -> Int -> Node -> [Step] -> IO ()
repair _ _ _ _ [] = error "repair: the root cannot underflow"
repair db tree pN nodeN (Step pp cells lnk j : rest) = do
  let n = length cells
      childAt i = if i < n then snd (cells !! i) else lnk
      sepAt i = fst (cells !! i)
      pL = childAt (j - 1)
      pR = childAt (j + 1)
  mL <- if j >= 1 then Just <$> readNode db pL else pure Nothing
  mR <- if j < n then Just <$> readNode db pR else pure Nothing
  let lendLeft = maybe False (\l -> nodeUsed l - last (nodeCosts l) >= minFill) mL
      lendRight = maybe False (\r -> nodeUsed r - sum (take 1 (nodeCosts r)) >= minFill) mR
  case (mL, mR) of
    (Just l, _) | lendLeft -> do
      let (l', n', newSep) = case (l, nodeN) of
            (Leaf k lcs lnx, Leaf _ ncs nnx) ->
              let lcs' = init lcs in (Leaf k lcs' lnx, Leaf k (last lcs : ncs) nnx, cellKey (last lcs'))
            (Interior lcs llink, Interior ncs nlink) ->
              let (kl, cl) = last lcs
               in (Interior (init lcs) cl, Interior ((sepAt (j - 1), llink) : ncs) nlink, kl)
            _ -> error "repair: sibling kinds differ"
      writeNode db pL l'
      writeNode db pN n'
      storeNode db tree pp (Interior (setSep (j - 1) newSep cells) lnk) rest
    (_, Just r) | lendRight -> do
      let (r', n', newSep) = case (r, nodeN) of
            (Leaf k (rc : rcs) rnx, Leaf _ ncs nnx) -> (Leaf k rcs rnx, Leaf k (ncs ++ [rc]) nnx, cellKey rc)
            (Interior ((kr, cr) : rcs) rlink, Interior ncs nlink) ->
              (Interior rcs rlink, Interior (ncs ++ [(sepAt j, nlink)]) cr, kr)
            _ -> error "repair: sibling kinds differ"
      writeNode db pR r'
      writeNode db pN n'
      storeNode db tree pp (Interior (setSep j newSep cells) lnk) rest
    (Just l, _) -> do
      let l' = case (l, nodeN) of
            (Leaf k lcs _, Leaf _ ncs nnx) -> Leaf k (lcs ++ ncs) nnx
            (Interior lcs llink, Interior ncs nlink) -> Interior (lcs ++ [(sepAt (j - 1), llink)] ++ ncs) nlink
            _ -> error "repair: sibling kinds differ"
      writeNode db pL l'
      freePage db pN
      let (cells', lnk')
            | j == n = (take (j - 1) cells, pL)
            | otherwise = (take (j - 1) cells ++ [(sepAt j, pL)] ++ drop (j + 1) cells, lnk)
      afterMerge pp cells' lnk'
    (Nothing, Just r) -> do
      let n' = case (nodeN, r) of
            (Leaf k ncs _, Leaf _ rcs rnx) -> Leaf k (ncs ++ rcs) rnx
            (Interior ncs nlink, Interior rcs rlink) -> Interior (ncs ++ [(sepAt j, nlink)] ++ rcs) rlink
            _ -> error "repair: sibling kinds differ"
      writeNode db pN n'
      freePage db pR
      let (cells', lnk')
            | j + 1 == n = (take j cells, pN)
            | otherwise = (take j cells ++ [(sepAt (j + 1), pN)] ++ drop (j + 2) cells, lnk)
      afterMerge pp cells' lnk'
    (Nothing, Nothing) -> error "repair: page without siblings"
  where
    afterMerge pp' cells' lnk' = do
      let node = Interior cells' lnk'
      case rest of
        []
          | null cells' -> treeSetRoot tree lnk' >> freePage db pp'
          | otherwise -> writeNode db pp' node
        _
          | nodeUsed node >= minFill -> writeNode db pp' node
          | otherwise -> repair db tree pp' node rest

-- | Visit cells in ascending key order starting at the first key @>= start@.
-- The callback returns 'False' to stop.  One descent, then the leaf chain.
foldFrom :: Db -> Tree -> BS.ByteString -> (Cell -> IO Bool) -> IO ()
foldFrom db tree start f = do
  root <- treeRoot tree
  when (root /= 0) $ do
    Located _ _ cs nxt _ <- descend db root start
    walk (dropWhile ((< start) . cellKey) cs) nxt
  where
    walk [] 0 = pure ()
    walk [] nxt = do
      node <- readNode db nxt
      case node of
        Leaf _ cs nxt' -> walk cs nxt'
        Interior _ _ -> pure ()
    walk (c : cs) nxt = do
      continue <- f c
      when continue (walk cs nxt)

-- | Visit cells in descending key order, restricted to keys @>= lower@ and
-- @< upper@, pruning subtrees outside the range with the separators.
foldReverse :: Db -> Tree -> Maybe BS.ByteString -> Maybe BS.ByteString -> (Cell -> IO Bool) -> IO ()
foldReverse db tree lower upper f = do
  root <- treeRoot tree
  when (root /= 0) (() <$ go root)
  where
    go p = do
      node <- readNode db p
      case node of
        Leaf _ cs _ -> leafLoop (reverse cs)
        Interior cells lnk ->
          let ks = map fst cells
              items = reverse (zip3 (map snd cells ++ [lnk]) (Nothing : map Just ks) (map Just ks ++ [Nothing]))
           in loop items
    loop [] = pure True
    loop ((c, lo, hi) : rest)
      | belowRange hi = pure False
      | aboveRange lo = loop rest
      | otherwise = do
          continue <- go c
          if continue then loop rest else pure False
    belowRange hi = case (lower, hi) of
      (Just l, Just h) -> h < l
      _ -> False
    aboveRange lo = case (upper, lo) of
      (Just u, Just l) -> l >= u
      _ -> False
    leafLoop [] = pure True
    leafLoop (c : cs)
      | maybe False (cellKey c >=) upper = leafLoop cs
      | maybe False (cellKey c <) lower = pure False
      | otherwise = do
          continue <- f c
          if continue then leafLoop cs else pure False

-- | Every page of the tree rooted at the given page, in post-order (SPEC §12.6).
postOrderPages :: Db -> Int -> IO [Int]
postOrderPages _ 0 = pure []
postOrderPages db root = go root
  where
    go p = do
      node <- readNode db p
      case node of
        Leaf {} -> pure [p]
        Interior cells lnk -> do
          below <- concat <$> mapM go (map snd cells ++ [lnk])
          pure (below ++ [p])

-- | Height of a tree: 0 when empty, 1 for a lone leaf (SPEC §12.7).
treeHeight :: Db -> Tree -> IO Int
treeHeight db tree = do
  root <- treeRoot tree
  if root == 0 then pure 0 else go root 1
  where
    go p !h = do
      node <- readNode db p
      case node of
        Leaf {} -> pure h
        Interior cells lnk -> go (case cells of (_, c) : _ -> c; [] -> lnk) (h + 1)
