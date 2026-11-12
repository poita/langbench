-- | Mutable lists and insertion-ordered hash maps, plus structural equality
-- and ordering of values.
module Langvm.Collections
  ( -- * Lists
    newList
  , listFromList
  , listLength
  , listRead
  , listWrite
  , listPush
  , listPop
  , listInsert
  , listRemoveAt
  , listClear
  , listToList
  , listSlice
    -- * Maps
  , newMap
  , mapSize
  , mapLookup
  , mapInsert
  , mapDelete
  , mapEntries
  , mapClearAll
  , mapCopyObj
    -- * Equality and ordering
  , valueEq
  , compareValues
  , Cmp (..)
  ) where

import Control.Monad (forM_)
import Data.Array.Base (unsafeRead, unsafeWrite, getNumElements)
import Data.Array.IO (newArray, newArray_)
import Data.Bits (shiftR, xor, (.&.))
import Data.IORef

import Langvm.SmallArray
import Langvm.Value

-- Lists ---------------------------------------------------------------------------

newList :: Int -> IO ListObj
newList cap = do
  arr <- newArray (0, max 4 cap - 1) VUnit
  ListObj <$> newIORef (LState 0 arr)

listFromList :: [Value] -> IO ListObj
listFromList vs = do
  let n = length vs
  arr <- newArray (0, max 4 n - 1) VUnit
  forM_ (zip [0 ..] vs) $ \(i, v) -> unsafeWrite arr i v
  ListObj <$> newIORef (LState n arr)

listLength :: ListObj -> IO Int
listLength (ListObj r) = do
  LState n _ <- readIORef r
  return n
{-# INLINE listLength #-}

-- | Read an element; the index must be in range.
listRead :: ListObj -> Int -> IO Value
listRead (ListObj r) i = do
  LState _ arr <- readIORef r
  unsafeRead arr i
{-# INLINE listRead #-}

listWrite :: ListObj -> Int -> Value -> IO ()
listWrite (ListObj r) i v = do
  LState _ arr <- readIORef r
  unsafeWrite arr i v
{-# INLINE listWrite #-}

listPush :: ListObj -> Value -> IO ()
listPush (ListObj r) v = do
  LState n arr <- readIORef r
  cap <- getNumElements arr
  if n < cap
    then unsafeWrite arr n v >> writeIORef r (LState (n + 1) arr)
    else do
      arr' <- newArray_ (0, cap * 2 - 1)
      forM_ [0 .. n - 1] $ \i -> unsafeRead arr i >>= unsafeWrite arr' i
      unsafeWrite arr' n v
      writeIORef r (LState (n + 1) arr')

-- | Remove and return the last element; the list must be non-empty.
listPop :: ListObj -> IO Value
listPop (ListObj r) = do
  LState n arr <- readIORef r
  v <- unsafeRead arr (n - 1)
  unsafeWrite arr (n - 1) VUnit
  writeIORef r (LState (n - 1) arr)
  return v

-- | Insert before an index in @0 .. length@.
listInsert :: ListObj -> Int -> Value -> IO ()
listInsert l@(ListObj r) i v = do
  listPush l v
  LState n arr <- readIORef r
  let go j | j <= i = return ()
           | otherwise = unsafeRead arr (j - 1) >>= unsafeWrite arr j >> go (j - 1)
  go (n - 1)
  unsafeWrite arr i v

listRemoveAt :: ListObj -> Int -> IO Value
listRemoveAt (ListObj r) i = do
  LState n arr <- readIORef r
  v <- unsafeRead arr i
  let go j | j >= n - 1 = return ()
           | otherwise = unsafeRead arr (j + 1) >>= unsafeWrite arr j >> go (j + 1)
  go i
  unsafeWrite arr (n - 1) VUnit
  writeIORef r (LState (n - 1) arr)
  return v

listClear :: ListObj -> IO ()
listClear (ListObj r) = do
  arr <- newArray (0, 3) VUnit
  writeIORef r (LState 0 arr)

listToList :: ListObj -> IO [Value]
listToList (ListObj r) = do
  LState n arr <- readIORef r
  mapM (unsafeRead arr) [0 .. n - 1]

-- | A new list of the elements @from .. to-1@.
listSlice :: ListObj -> Int -> Int -> IO ListObj
listSlice (ListObj r) from to = do
  LState _ arr <- readIORef r
  let n = to - from
  arr' <- newArray (0, max 4 n - 1) VUnit
  forM_ [0 .. n - 1] $ \i -> unsafeRead arr (from + i) >>= unsafeWrite arr' i
  ListObj <$> newIORef (LState n arr')

-- Maps ----------------------------------------------------------------------------

emptyTab :: Int -> IO MapTab
emptyTab cap = do
  idx <- newArray (0, 2 * cap - 1) (-1)
  hs <- newArray (0, cap - 1) (-1)
  ks <- newArray (0, cap - 1) VUnit
  vs <- newArray (0, cap - 1) VUnit
  return (MapTab cap idx hs ks vs)

newMap :: IO MapObj
newMap = do
  tab <- emptyTab 8
  ref <- newIORef tab
  counters <- newArray (0, 1) 0
  return (MapObj ref counters)

mapSize :: MapObj -> IO Int
mapSize (MapObj _ c) = unsafeRead c 1

hashKey :: Value -> Int
hashKey v = case v of
  VInt n -> mix n
  VChar c -> mix (fromEnum c)
  VBool b -> if b then 1 else 2
  VStr s -> go 0 5381
    where n = strLength s
          go i h | i >= n = mix h
                 | otherwise = go (i + 1) ((h `xor` fromEnum (strAt s i)) * 1099511628211)
  _ -> 0
  where
    mix x = let a = (x `xor` (x `shiftR` 33)) * 0x5851f42d4c957f2d
                b = (a `xor` (a `shiftR` 29)) * 0x2545F4914F6CDD1D
            in (b `xor` (b `shiftR` 32)) .&. 0x3fffffffffffffff

keyEq :: Value -> Value -> Bool
keyEq a b = case (a, b) of
  (VInt x, VInt y) -> x == y
  (VChar x, VChar y) -> x == y
  (VBool x, VBool y) -> x == y
  (VStr x, VStr y) -> strEq x y
  _ -> False

-- | The index slot and entry of a key, or @(-1, -1)@.
findSlot :: MapTab -> Value -> Int -> IO (Int, Int)
findSlot tab k h = go (h .&. mask)
  where
    mask = 2 * mtCap tab - 1
    go s = do
      e <- unsafeRead (mtIndex tab) s
      if e == -1 then return (-1, -1)
      else if e == -2 then go ((s + 1) .&. mask)
      else do
        eh <- unsafeRead (mtHash tab) e
        if eh == h
          then do
            k' <- unsafeRead (mtKeys tab) e
            if keyEq k k' then return (s, e) else go ((s + 1) .&. mask)
          else go ((s + 1) .&. mask)

mapLookup :: MapObj -> Value -> IO (Maybe Value)
mapLookup (MapObj ref _) k = do
  tab <- readIORef ref
  (_, e) <- findSlot tab k (hashKey k)
  if e < 0 then return Nothing else Just <$> unsafeRead (mtVals tab) e

placeIndex :: MapTab -> Int -> Int -> IO ()
placeIndex tab h e = go (h .&. mask)
  where
    mask = 2 * mtCap tab - 1
    go s = do
      x <- unsafeRead (mtIndex tab) s
      if x < 0 then unsafeWrite (mtIndex tab) s e else go ((s + 1) .&. mask)

mapInsert :: MapObj -> Value -> Value -> IO ()
mapInsert m@(MapObj ref counters) k v = do
  tab <- readIORef ref
  let h = hashKey k
  (_, e) <- findSlot tab k h
  if e >= 0
    then unsafeWrite (mtVals tab) e v
    else do
      used <- unsafeRead counters 0
      tab' <- if used >= mtCap tab then rebuild m else return tab
      used' <- unsafeRead counters 0
      live <- unsafeRead counters 1
      unsafeWrite (mtHash tab') used' h
      unsafeWrite (mtKeys tab') used' k
      unsafeWrite (mtVals tab') used' v
      placeIndex tab' h used'
      unsafeWrite counters 0 (used' + 1)
      unsafeWrite counters 1 (live + 1)

-- | Compact (or grow) the table, keeping insertion order.
rebuild :: MapObj -> IO MapTab
rebuild (MapObj ref counters) = do
  tab <- readIORef ref
  used <- unsafeRead counters 0
  live <- unsafeRead counters 1
  let cap' = if live * 2 >= mtCap tab then mtCap tab * 2 else mtCap tab
  tab' <- emptyTab cap'
  let go i j
        | i >= used = return j
        | otherwise = do
            h <- unsafeRead (mtHash tab) i
            if h < 0 then go (i + 1) j else do
              k <- unsafeRead (mtKeys tab) i
              v <- unsafeRead (mtVals tab) i
              unsafeWrite (mtHash tab') j h
              unsafeWrite (mtKeys tab') j k
              unsafeWrite (mtVals tab') j v
              placeIndex tab' h j
              go (i + 1) (j + 1)
  n <- go 0 0
  unsafeWrite counters 0 n
  unsafeWrite counters 1 n
  writeIORef ref tab'
  return tab'

mapDelete :: MapObj -> Value -> IO Bool
mapDelete (MapObj ref counters) k = do
  tab <- readIORef ref
  (s, e) <- findSlot tab k (hashKey k)
  if e < 0 then return False else do
    unsafeWrite (mtIndex tab) s (-2)
    unsafeWrite (mtHash tab) e (-1)
    unsafeWrite (mtKeys tab) e VUnit
    unsafeWrite (mtVals tab) e VUnit
    live <- unsafeRead counters 1
    unsafeWrite counters 1 (live - 1)
    return True

-- | The live entries in insertion order.
mapEntries :: MapObj -> IO [(Value, Value)]
mapEntries (MapObj ref counters) = do
  tab <- readIORef ref
  used <- unsafeRead counters 0
  let go i acc
        | i < 0 = return acc
        | otherwise = do
            h <- unsafeRead (mtHash tab) i
            if h < 0 then go (i - 1) acc else do
              k <- unsafeRead (mtKeys tab) i
              v <- unsafeRead (mtVals tab) i
              go (i - 1) ((k, v) : acc)
  go (used - 1) []

mapClearAll :: MapObj -> IO ()
mapClearAll (MapObj ref counters) = do
  tab <- emptyTab 8
  writeIORef ref tab
  unsafeWrite counters 0 0
  unsafeWrite counters 1 0

mapCopyObj :: MapObj -> IO MapObj
mapCopyObj m = do
  es <- mapEntries m
  m' <- newMap
  forM_ es $ \(k, v) -> mapInsert m' k v
  return m'

-- Equality and ordering -----------------------------------------------------------------

-- | Structural equality (section 10.4).
valueEq :: Value -> Value -> IO Bool
valueEq a b = case (a, b) of
  (VInt x, VInt y) -> return (x == y)
  (VFloat x, VFloat y) -> return (x == y)
  (VBool x, VBool y) -> return (x == y)
  (VChar x, VChar y) -> return (x == y)
  (VStr x, VStr y) -> return (strEq x y)
  (VUnit, VUnit) -> return True
  (VTuple x, VTuple y) -> arrEq x y
  (VStruct _ x, VStruct _ y) -> arrEq x y
  (VEnum _ i x, VEnum _ j y) -> if i /= j then return False else arrEq x y
  (VList x, VList y) -> do
    nx <- listLength x
    ny <- listLength y
    if nx /= ny then return False else
      let go i | i >= nx = return True
               | otherwise = do
                   p <- listRead x i
                   q <- listRead y i
                   e <- valueEq p q
                   if e then go (i + 1) else return False
      in go 0
  (VMap x, VMap y) -> do
    nx <- mapSize x
    ny <- mapSize y
    if nx /= ny then return False else do
      es <- mapEntries x
      let go [] = return True
          go ((k, v) : r) = do
            m <- mapLookup y k
            case m of
              Nothing -> return False
              Just v' -> do
                e <- valueEq v v'
                if e then go r else return False
      go es
  _ -> return False
  where
    arrEq x y = go 0
      where
        n = sizeA x
        go i | i >= n = return True
             | otherwise = do
                 e <- valueEq (indexA x i) (indexA y i)
                 if e then go (i + 1) else return False

-- | The result of an ordering comparison: IEEE comparisons can be unordered.
data Cmp = CLT | CEQ | CGT | CUN
  deriving (Eq, Show)

compareValues :: Value -> Value -> Cmp
compareValues a b = case (a, b) of
  (VInt x, VInt y) -> ord' (compare x y)
  (VFloat x, VFloat y)
    | x < y -> CLT
    | x > y -> CGT
    | x == y -> CEQ
    | otherwise -> CUN
  (VBool x, VBool y) -> ord' (compare x y)
  (VChar x, VChar y) -> ord' (compare x y)
  (VStr x, VStr y) -> ord' (strCompare x y)
  _ -> CUN
  where
    ord' o = case o of LT -> CLT; EQ -> CEQ; GT -> CGT
