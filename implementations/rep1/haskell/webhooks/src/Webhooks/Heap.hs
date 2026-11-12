-- | A leftist min-heap: O(log n) insertion and removal of the minimum.
module Webhooks.Heap
  ( Heap
  , empty
  , insert
  , popMin
  , fromList
  , toAscList
  , size
  ) where


-- | A min-heap of ordered elements.
data Heap a = Leaf | Node !Int a (Heap a) (Heap a)

-- | The empty heap.
empty :: Heap a
empty = Leaf

rank :: Heap a -> Int
rank Leaf = 0
rank (Node r _ _ _) = r

merge :: Ord a => Heap a -> Heap a -> Heap a
merge Leaf h = h
merge h Leaf = h
merge h1@(Node _ x l1 r1) h2@(Node _ y l2 r2)
  | x <= y = make x l1 (merge r1 h2)
  | otherwise = make y l2 (merge h1 r2)

make :: a -> Heap a -> Heap a -> Heap a
make x a b
  | rank a >= rank b = Node (rank b + 1) x a b
  | otherwise = Node (rank a + 1) x b a

-- | Add an element.
insert :: Ord a => a -> Heap a -> Heap a
insert x = merge (Node 1 x Leaf Leaf)

-- | Remove and return the smallest element.
popMin :: Ord a => Heap a -> Maybe (a, Heap a)
popMin Leaf = Nothing
popMin (Node _ x l r) = Just (x, merge l r)

-- | Build a heap from a list.
fromList :: Ord a => [a] -> Heap a
fromList = foldl' (flip insert) Leaf

-- | All elements in ascending order.
toAscList :: Ord a => Heap a -> [a]
toAscList h = case popMin h of
  Nothing -> []
  Just (x, h') -> x : toAscList h'

-- | Number of elements (O(n)).
size :: Heap a -> Int
size Leaf = 0
size (Node _ _ l r) = 1 + size l + size r
