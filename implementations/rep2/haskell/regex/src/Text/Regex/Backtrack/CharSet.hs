-- |
-- Module      : Text.Regex.Backtrack.CharSet
-- Description : Immutable sets of 8-bit characters with O(1) membership.
--
-- A 'CharSet' is a 256-entry lookup table. Only code points 0..255 can be
-- members; anything larger is never a member (and is a member of the
-- complement of any set, see 'complement').
module Text.Regex.Backtrack.CharSet
  ( CharSet
  , empty
  , full
  , singleton
  , range
  , fromList
  , union
  , unions
  , complement
  , member
  , memberByte
  , null
  , toList
  ) where

import Prelude hiding (null)

import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Char (chr, ord)
import Data.Word (Word8)

-- | A set of characters in the range @'\\0'..'\\255'@.
newtype CharSet = CharSet B.ByteString
  deriving (Eq, Ord)

instance Show CharSet where
  showsPrec d s = showParen (d > 10) $ showString "fromList " . shows (toList s)

table :: (Int -> Bool) -> CharSet
table p = CharSet (B.pack [if p i then 1 else 0 | i <- [0 .. 255]])

-- | The empty set.
empty :: CharSet
empty = table (const False)

-- | Every character 0..255.
full :: CharSet
full = table (const True)

-- | A set with one member.
singleton :: Char -> CharSet
singleton c = table (== ord c)

-- | @range lo hi@ contains every character @c@ with @lo <= c <= hi@.
range :: Char -> Char -> CharSet
range lo hi = table (\i -> i >= ord lo && i <= ord hi)

-- | Build a set from a list of members.
fromList :: [Char] -> CharSet
fromList cs = table (`elem` map ord cs)

-- | Set union.
union :: CharSet -> CharSet -> CharSet
union (CharSet a) (CharSet b) = CharSet (B.pack (B.zipWith max a b))

-- | Union of many sets.
unions :: [CharSet] -> CharSet
unions = foldr union empty

-- | Complement with respect to 'full' (characters 0..255).
complement :: CharSet -> CharSet
complement (CharSet a) = CharSet (B.map (1 -) a)

-- | Membership test.
member :: Char -> CharSet -> Bool
member c (CharSet a) = let i = ord c in i < 256 && i >= 0 && BU.unsafeIndex a i /= 0

-- | Membership test on a byte; no bounds check needed.
memberByte :: Word8 -> CharSet -> Bool
memberByte w (CharSet a) = BU.unsafeIndex a (fromIntegral w) /= 0
{-# INLINE memberByte #-}

-- | Is the set empty?
null :: CharSet -> Bool
null (CharSet a) = B.all (== 0) a

-- | Members in ascending order.
toList :: CharSet -> [Char]
toList (CharSet a) = [chr i | i <- [0 .. 255], BU.unsafeIndex a i /= 0]
