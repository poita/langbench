-- | The JSON value model: immutable values, insertion-ordered objects and
-- jq's total ordering.
module Jq.Value
  ( Value (..)
  , Object
  , truthy
  , typeName
  , compareValues
    -- * Objects
  , emptyObject
  , objInsert
  , objLookup
  , objSize
  , objFromList
  , objToList
  , objValues
  , objKeysSorted
  , objMerge
  , objDeepMerge
  ) where

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Data.Sequence (Seq)
import Data.Text (Text)

-- | A JSON value.  Values are immutable and share structure freely.
data Value
  = VNull
  | VBool !Bool
  | VNumber !Double
  | VString !Text
  | VArray !(Seq Value)
  | VObject !Object

-- | An insertion-ordered map from string keys to values.
--
-- Lookup is a balanced-tree search; the keys are kept in code-point order by
-- the underlying 'Map', so the sorted key list is available without sorting.
-- Insertion positions are tracked separately in an 'IntMap'.
--
-- Fields: key -> (insertion position, value); insertion position -> key;
-- next free insertion position.
data Object = Object !(Map Text (Int, Value)) !(IntMap Text) !Int

objIndex :: Object -> Map Text (Int, Value)
objIndex (Object i _ _) = i

objOrder :: Object -> IntMap Text
objOrder (Object _ o _) = o

instance Eq Value where
  a == b = compareValues a b == EQ

instance Ord Value where
  compare = compareValues

instance Show Value where
  showsPrec _ VNull = showString "null"
  showsPrec _ (VBool b) = showString (if b then "true" else "false")
  showsPrec _ (VNumber n) = shows n
  showsPrec _ (VString s) = shows s
  showsPrec _ (VArray a) = shows (foldr (:) [] a)
  showsPrec _ (VObject o) = showString "{" . go (objToList o) . showString "}"
    where
      go [] = id
      go [(k, v)] = shows k . showString ":" . shows v
      go ((k, v) : r) = shows k . showString ":" . shows v . showString "," . go r

-- | jq truthiness: everything except @false@ and @null@ is true.
truthy :: Value -> Bool
truthy VNull = False
truthy (VBool False) = False
truthy _ = True

-- | The result of jq's @type@.
typeName :: Value -> Text
typeName v = case v of
  VNull -> "null"
  VBool _ -> "boolean"
  VNumber _ -> "number"
  VString _ -> "string"
  VArray _ -> "array"
  VObject _ -> "object"

rank :: Value -> Int
rank v = case v of
  VNull -> 0
  VBool False -> 1
  VBool True -> 2
  VNumber _ -> 3
  VString _ -> 4
  VArray _ -> 5
  VObject _ -> 6

-- | jq's total order: @null < false < true < numbers < strings < arrays <
-- objects@, with the usual order inside each type.  Objects compare by their
-- sorted key lists first and then by their values in sorted key order.
compareValues :: Value -> Value -> Ordering
compareValues (VNumber a) (VNumber b) = compare a b
compareValues (VString a) (VString b) = compare a b
compareValues (VArray a) (VArray b) = compare a b
compareValues (VObject a) (VObject b) =
  compare (M.keys (objIndex a)) (M.keys (objIndex b))
    <> compare (map snd (M.elems (objIndex a))) (map snd (M.elems (objIndex b)))
compareValues a b = compare (rank a) (rank b)

-- | The empty object.
emptyObject :: Object
emptyObject = Object M.empty IM.empty 0

-- | Set a key.  An existing key keeps its position; a new key is appended.
objInsert :: Text -> Value -> Object -> Object
objInsert k v (Object idx ord next) = case M.lookup k idx of
  Just (p, _) -> Object (M.insert k (p, v) idx) ord next
  Nothing -> Object (M.insert k (next, v) idx) (IM.insert next k ord) (next + 1)

-- | Look a key up.
objLookup :: Text -> Object -> Maybe Value
objLookup k o = snd <$> M.lookup k (objIndex o)

-- | Number of keys.
objSize :: Object -> Int
objSize = M.size . objIndex

-- | Build an object from key/value pairs; a repeated key keeps its first
-- position and takes its last value.
objFromList :: [(Text, Value)] -> Object
objFromList = foldl' (\o (k, v) -> objInsert k v o) emptyObject

-- | Entries in insertion order.
objToList :: Object -> [(Text, Value)]
objToList o = mapMaybe entry (IM.elems (objOrder o))
  where
    entry k = (,) k . snd <$> M.lookup k (objIndex o)

-- | Values in insertion order.
objValues :: Object -> [Value]
objValues = map snd . objToList

-- | Keys sorted by code point.
objKeysSorted :: Object -> [Text]
objKeysSorted = M.keys . objIndex

-- | @a + b@: the keys of @b@ are set into @a@ in order.
objMerge :: Object -> Object -> Object
objMerge a b = foldl' (\o (k, v) -> objInsert k v o) a (objToList b)

-- | @a * b@: like 'objMerge' but recursing when both values are objects.
objDeepMerge :: Object -> Object -> Object
objDeepMerge a b = foldl' step a (objToList b)
  where
    step o (k, vb) = case (objLookup k o, vb) of
      (Just (VObject xa), VObject xb) -> objInsert k (VObject (objDeepMerge xa xb)) o
      _ -> objInsert k vb o
