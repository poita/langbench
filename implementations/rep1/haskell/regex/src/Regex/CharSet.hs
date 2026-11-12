-- | Immutable sets of byte-valued characters, with O(1) membership.
module Regex.CharSet
  ( CharSet
  , empty
  , full
  , singleton
  , range
  , union
  , unions
  , complement
  , member
  , null
  , digits
  , wordChars
  , spaceChars
  ) where

import Prelude hiding (null)

import Data.Array.Base (unsafeAt)
import Data.Array.Unboxed (UArray, accumArray, listArray, elems)
import Data.Word (Word8)

-- | A set of characters in the range 0..255, stored as a 256-entry table.
newtype CharSet = CharSet (UArray Int Bool)
  deriving (Eq)

instance Show CharSet where
  show (CharSet a) = "CharSet " ++ show [i | (i, True) <- zip [0 :: Int ..] (elems a)]

-- | The empty set.
empty :: CharSet
empty = CharSet (listArray (0, 255) (replicate 256 False))

-- | The set of every byte.
full :: CharSet
full = complement empty

-- | A one-element set.
singleton :: Word8 -> CharSet
singleton c = range c c

-- | The inclusive range @lo .. hi@ (empty when @lo > hi@).
range :: Word8 -> Word8 -> CharSet
range lo hi =
  CharSet (accumArray (\_ b -> b) False (0, 255)
             [(fromIntegral c, True) | c <- [fromIntegral lo .. fromIntegral hi :: Int]])

-- | Set union.
union :: CharSet -> CharSet -> CharSet
union (CharSet a) (CharSet b) = CharSet (listArray (0, 255) (zipWith (||) (elems a) (elems b)))

-- | Union of many sets.
unions :: [CharSet] -> CharSet
unions = foldr union empty

-- | Complement with respect to 0..255.
complement :: CharSet -> CharSet
complement (CharSet a) = CharSet (listArray (0, 255) (map not (elems a)))

-- | Membership test.
member :: Word8 -> CharSet -> Bool
member c (CharSet a) = unsafeAt a (fromIntegral c)
{-# INLINE member #-}

-- | Is the set empty?
null :: CharSet -> Bool
null (CharSet a) = not (or (elems a))

-- | @[0-9]@
digits :: CharSet
digits = range 48 57

-- | @[A-Za-z0-9_]@
wordChars :: CharSet
wordChars = unions [range 65 90, range 97 122, digits, singleton 95]

-- | Space, tab, newline, carriage return, form feed, vertical tab.
spaceChars :: CharSet
spaceChars = unions [singleton 32, range 9 13]
