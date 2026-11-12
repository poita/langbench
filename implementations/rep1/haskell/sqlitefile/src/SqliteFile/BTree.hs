-- | Walking table and index B-trees.
--
-- All traversals are lazy: a consumer that stops early (for example after
-- @LIMIT@ rows) does not read the rest of the tree.
module SqliteFile.BTree
  ( tableRows
  , tableCount
  , tableLookup
  , indexLookup
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import SqliteFile.Error (corrupt)
import SqliteFile.Pager
import SqliteFile.Varint (getBE, getVarint)

maxDepth :: Int
maxDepth = 64

page' :: Database -> Int -> Int -> Page
page' db depth n
  | depth > maxDepth = corrupt "B-tree is too deep (cycle?)"
  | otherwise = readPage db n

-- Table-leaf cell: payload size, rowid, payload.
tableLeafCell :: Database -> Page -> Int -> (Int64, ByteString)
tableLeafCell db p i =
  let off = cellOffset p i
      (size, n1) = getVarint (pageBytes p) off
      (rowid, n2) = getVarint (pageBytes p) (off + n1)
   in (rowid, cellPayload db p (off + n1 + n2) (fromIntegral size))

-- Table-interior cell: left child page and rowid key.
tableInteriorCell :: Page -> Int -> (Int, Int64)
tableInteriorCell p i =
  let off = cellOffset p i
   in (getBE (pageBytes p) off 4, fst (getVarint (pageBytes p) (off + 4)))

-- Index cell: optional left child, and the payload.
indexCell :: Database -> Page -> Int -> (Int, ByteString)
indexCell db p i =
  let off = cellOffset p i
      pg = pageBytes p
   in if isInterior (pageKind p)
        then
          let (size, n) = getVarint pg (off + 4)
           in (getBE pg off 4, cellPayload db p (off + 4 + n) (fromIntegral size))
        else
          let (size, n) = getVarint pg off
           in (0, cellPayload db p (off + n) (fromIntegral size))

-- | All rows of the table B-tree rooted at the given page, as
-- @(rowid, record payload)@ in ascending rowid order.
tableRows :: Database -> Int -> [(Int64, ByteString)]
tableRows db root = go 0 root []
  where
    go depth n rest =
      let p = page' db depth n
       in case pageKind p of
            LeafTable -> [tableLeafCell db p i | i <- [0 .. pageCells p - 1]] ++ rest
            InteriorTable ->
              foldr
                (\i acc -> go (depth + 1) (fst (tableInteriorCell p i)) acc)
                (go (depth + 1) (pageRightChild p) rest)
                [0 .. pageCells p - 1]
            _ -> corrupt "index page found in a table B-tree"

-- | Number of rows in a table B-tree: the sum of the leaf pages' cell
-- counts. No cell or record is decoded.
tableCount :: Database -> Int -> Int
tableCount db = go 0
  where
    go depth n =
      let p = page' db depth n
       in case pageKind p of
            LeafTable -> pageCells p
            InteriorTable ->
              sum [go (depth + 1) (fst (tableInteriorCell p i)) | i <- [0 .. pageCells p - 1]]
                + go (depth + 1) (pageRightChild p)
            _ -> corrupt "index page found in a table B-tree"

-- | Find the record payload of the row with the given rowid by a binary
-- search down the tree.
tableLookup :: Database -> Int -> Int64 -> Maybe ByteString
tableLookup db root target = go 0 root
  where
    go depth n =
      let p = page' db depth n
          cnt = pageCells p
       in case pageKind p of
            LeafTable ->
              let i = firstIndex cnt (\j -> fst (tableLeafCell db p j) >= target)
               in if i < cnt
                    then let (r, payload) = tableLeafCell db p i
                          in if r == target then Just payload else Nothing
                    else Nothing
            InteriorTable ->
              let i = firstIndex cnt (\j -> snd (tableInteriorCell p j) >= target)
               in go (depth + 1) (if i < cnt then fst (tableInteriorCell p i) else pageRightChild p)
            _ -> corrupt "index page found in a table B-tree"

-- | Smallest @i@ in @[0, n]@ such that @pred i@ holds (@n@ if none), given a
-- monotone predicate.
firstIndex :: Int -> (Int -> Bool) -> Int
firstIndex n predicate = go 0 n
  where
    go lo hi
      | lo >= hi = lo
      | predicate mid = go lo mid
      | otherwise = go (mid + 1) hi
      where mid = (lo + hi) `div` 2

-- | Payloads of every index entry equal to a key, in key order.
--
-- The comparator receives an entry's payload and says how the entry orders
-- relative to the sought key (@LT@: entry is smaller). Entries for which it
-- returns @EQ@ are returned. The search descends only into subtrees that can
-- contain matches, so it costs O(depth * log fanout + matches).
indexLookup :: Database -> Int -> (ByteString -> Ordering) -> [ByteString]
indexLookup db root cmp = go 0 root
  where
    go depth n =
      let p = page' db depth n
          cnt = pageCells p
          payloadAt j = snd (indexCell db p j)
          -- first cell whose entry is >= the key
          start = firstIndex cnt (\j -> cmp (payloadAt j) /= LT)
       in case pageKind p of
            LeafIndex -> takeWhileEq [payloadAt j | j <- [start .. cnt - 1]]
            InteriorIndex ->
              let child j = go (depth + 1) (fst (indexCell db p j))
                  walk j
                    | j >= cnt = go (depth + 1) (pageRightChild p)
                    | otherwise =
                        let payload = payloadAt j
                         in case cmp payload of
                              EQ -> child j ++ payload : walk (j + 1)
                              _ -> child j -- entry > key: nothing further right matters
               in walk start
            _ -> corrupt "table page found in an index B-tree"
    takeWhileEq = takeWhile (\x -> cmp x == EQ)
