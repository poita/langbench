-- | Runtime values of the virtual machine.
module Langvm.Value
  ( Value (..)
  , Str
  , strFromString
  , strToString
  , strLength
  , strAt
  , strFromList
  , strConcat
  , strSlice
  , strEq
  , strCompare
  , ListObj (..)
  , LState (..)
  , MapObj (..)
  , MapTab (..)
  , Panic (..)
  , panic
  , valueHead
  , unitValue
  , boolValue
  , fieldsArray
  ) where

import Control.Exception (Exception, throwIO)
import Data.Array.Base (unsafeAt, unsafeWrite)
import Data.Array.ST (newArray_, runSTUArray)
import Data.Array.IO (IOArray, IOUArray)
import Data.Array.Unboxed (UArray, listArray)
import Data.Array.Base (numElements)
import Data.IORef (IORef)

import Langvm.SmallArray

-- | A string: a sequence of Unicode scalar values with O(1) indexing.
newtype Str = Str (UArray Int Char)

strFromString :: String -> Str
strFromString s = let n = length s in Str (listArray (0, n - 1) s)

strFromList :: Int -> String -> Str
strFromList n s = Str (listArray (0, n - 1) s)

strToString :: Str -> String
strToString (Str a) = [unsafeAt a i | i <- [0 .. numElements a - 1]]

strLength :: Str -> Int
strLength (Str a) = numElements a
{-# INLINE strLength #-}

strAt :: Str -> Int -> Char
strAt (Str a) i = unsafeAt a i
{-# INLINE strAt #-}

strConcat :: Str -> Str -> Str
strConcat a b
  | strLength a == 0 = b
  | strLength b == 0 = a
  | otherwise =
      let la = strLength a
          lb = strLength b
      in Str (runSTUArray (do
           arr <- newArray_ (0, la + lb - 1)
           let copy src off n = go 0
                 where go i | i >= n = return ()
                            | otherwise = unsafeWrite arr (off + i) (strAt src i) >> go (i + 1)
           copy a 0 la
           copy b la lb
           return arr))

-- | @strSlice s from to@: the scalars @from .. to-1@ (indices already checked).
strSlice :: Str -> Int -> Int -> Str
strSlice s from to
  | from == 0 && to == strLength s = s
  | otherwise =
      let n = to - from
      in Str (runSTUArray (do
           arr <- newArray_ (0, n - 1)
           let go i | i >= n = return ()
                    | otherwise = unsafeWrite arr i (strAt s (from + i)) >> go (i + 1)
           go 0
           return arr))

strEq :: Str -> Str -> Bool
strEq a b = n == strLength b && go 0
  where
    n = strLength a
    go i | i >= n = True
         | strAt a i /= strAt b i = False
         | otherwise = go (i + 1)

strCompare :: Str -> Str -> Ordering
strCompare a b = go 0
  where
    la = strLength a
    lb = strLength b
    go i
      | i >= la = if i >= lb then EQ else LT
      | i >= lb = GT
      | otherwise = case compare (strAt a i) (strAt b i) of
          EQ -> go (i + 1)
          o -> o

-- | The state of a list: its length and its backing array (capacity >= length).
data LState = LState !Int !(IOArray Int Value)

newtype ListObj = ListObj (IORef LState)

-- | The hash table behind a map (see "Langvm.Collections").
data MapTab = MapTab
  { mtCap :: !Int
  , mtIndex :: !(IOUArray Int Int)
  , mtHash :: !(IOUArray Int Int)
  , mtKeys :: !(IOArray Int Value)
  , mtVals :: !(IOArray Int Value)
  }

-- | A map: its table and a two-element counter array (entries used, entries live).
data MapObj = MapObj !(IORef MapTab) !(IOUArray Int Int)

data Value
  = VInt {-# UNPACK #-} !Int
  | VFloat {-# UNPACK #-} !Double
  | VBool !Bool
  | VChar {-# UNPACK #-} !Char
  | VStr !Str
  | VUnit
  | VTuple !(SmallArray Value)
  | VStruct !Int !(SmallArray Value)       -- ^ declaration id, fields
  | VEnum !Int !Int !(SmallArray Value)    -- ^ declaration id, variant, payloads
  | VClosure !Int !(SmallArray Value)      -- ^ function index, upvalues
  | VList !ListObj
  | VMap !MapObj

-- | A runtime error: the message after @panic: @.
newtype Panic = Panic String
  deriving (Show)

instance Exception Panic

panic :: String -> IO a
panic = throwIO . Panic

-- | The head constructor of a value, for method dispatch ('Langvm.Types.tyHead').
valueHead :: Value -> Int
valueHead v = case v of
  VInt _ -> 0
  VFloat _ -> 1
  VBool _ -> 2
  VChar _ -> 3
  VStr _ -> 4
  VUnit -> 5
  VList _ -> 6
  VMap _ -> 7
  VStruct d _ -> 8 + d
  VEnum d _ _ -> 8 + d
  _ -> -1

unitValue :: Value
unitValue = VUnit

boolValue :: Bool -> Value
boolValue = VBool

fieldsArray :: [Value] -> SmallArray Value
fieldsArray vs = fromListA (length vs) vs
