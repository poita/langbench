-- | The JSON data model used throughout the library.
--
-- Values are immutable and shared: building, indexing and iterating never
-- copies a value. Objects remember insertion order (see 'Object').
module Jq.Value
  ( -- * Values
    Value (..)
  , typeName
  , isTruthy
  , compareValues
    -- * Objects
  , Object
  , emptyObject
  , objectFromList
  , objectInsert
  , objectLookup
  , objectMember
  , objectSize
  , objectToList
  , objectKeys
  , objectValues
  , objectSortedKeys
  , objectSortedToList
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import Data.Sequence (Seq)
import Data.Text (Text)

-- | A JSON value. Numbers are IEEE-754 doubles.
data Value
  = VNull
  | VBool !Bool
  | VNum !Double
  | VStr !Text
  | VArr !(Seq Value)
  | VObj !Object
  deriving (Show)

-- | Equality is "compares equal under 'compareValues'" (so key order of
-- objects is irrelevant and @0 == -0@).
instance Eq Value where
  a == b = compareValues a b == EQ

-- | The jq total order, see 'compareValues'.
instance Ord Value where
  compare = compareValues

-- | An insertion-ordered string-keyed map.
--
-- Keys are kept in a 'M.Map' (so they are sorted exactly once, structurally,
-- and lookup is logarithmic) together with an 'IM.IntMap' of slots that
-- records insertion order. Re-inserting an existing key keeps its position.
data Object = Object
  !(M.Map Text Int)             -- key -> slot
  !(IM.IntMap (Text, Value))    -- slot -> entry, in insertion order
  !Int                          -- next free slot

instance Show Object where
  showsPrec d o = showParen (d > 10) $ showString "objectFromList " . shows (objectToList o)

emptyObject :: Object
emptyObject = Object M.empty IM.empty 0

-- | Set a key. An existing key keeps its position and takes the new value;
-- a new key is appended.
objectInsert :: Text -> Value -> Object -> Object
objectInsert k v (Object ix sl n) = case M.lookup k ix of
  Just i  -> Object ix (IM.insert i (k, v) sl) n
  Nothing -> Object (M.insert k n ix) (IM.insert n (k, v) sl) (n + 1)

-- | Build an object by inserting left to right (later duplicates win but
-- keep the first position).
objectFromList :: [(Text, Value)] -> Object
objectFromList = foldl (\o (k, v) -> objectInsert k v o) emptyObject

objectLookup :: Text -> Object -> Maybe Value
objectLookup k (Object ix sl _) = do
  i <- M.lookup k ix
  snd <$> IM.lookup i sl

objectMember :: Text -> Object -> Bool
objectMember k (Object ix _ _) = M.member k ix

objectSize :: Object -> Int
objectSize (Object ix _ _) = M.size ix

-- | Entries in insertion order.
objectToList :: Object -> [(Text, Value)]
objectToList (Object _ sl _) = IM.elems sl

-- | Keys in insertion order.
objectKeys :: Object -> [Text]
objectKeys = map fst . objectToList

-- | Values in insertion order.
objectValues :: Object -> [Value]
objectValues = map snd . objectToList

-- | Keys sorted by code point.
objectSortedKeys :: Object -> [Text]
objectSortedKeys (Object ix _ _) = M.keys ix

-- | Entries sorted by key.
objectSortedToList :: Object -> [(Text, Value)]
objectSortedToList (Object ix sl _) = [sl IM.! i | i <- M.elems ix]

-- | The jq type name of a value.
typeName :: Value -> Text
typeName v = case v of
  VNull   -> "null"
  VBool _ -> "boolean"
  VNum _  -> "number"
  VStr _  -> "string"
  VArr _  -> "array"
  VObj _  -> "object"

-- | @false@ and @null@ are falsy; everything else is truthy.
isTruthy :: Value -> Bool
isTruthy VNull = False
isTruthy (VBool b) = b
isTruthy _ = True

rank :: Value -> Int
rank v = case v of
  VNull         -> 0
  VBool False   -> 1
  VBool True    -> 2
  VNum _        -> 3
  VStr _        -> 4
  VArr _        -> 5
  VObj _        -> 6

-- | The jq ordering: @null < false < true < numbers < strings < arrays <
-- objects@; numbers numerically, strings by code point, arrays
-- lexicographically, objects by sorted key list and then by values in sorted
-- key order.
compareValues :: Value -> Value -> Ordering
compareValues (VNum a) (VNum b) = compare a b
compareValues (VStr a) (VStr b) = compare a b
compareValues (VArr a) (VArr b) = compare a b
compareValues (VObj a) (VObj b) =
  let ea = objectSortedToList a
      eb = objectSortedToList b
  in compare (map fst ea) (map fst eb) <> compare (map snd ea) (map snd eb)
compareValues a b = compare (rank a) (rank b)

