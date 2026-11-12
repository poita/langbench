-- |
-- Module      : Protowire.Value
-- Description : The value tree shared by the decoder, encoder and text form.
module Protowire.Value
  ( Value (..)
  , Slot (..)
  , Message (..)
  , emptyMessage
  , isDefault
  , normalize
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Word (Word64)

-- | A single field value.
--
-- Integer kinds are widened: @int32@, @int64@, @sint32@, @sint64@,
-- @sfixed32@ and @sfixed64@ are held as 'VInt'; @uint32@, @uint64@,
-- @fixed32@ and @fixed64@ as 'VWord'.  Which one applies is determined by
-- the field's schema type.  Strings are held as their (valid) UTF-8 bytes.
data Value
  = VInt !Int64
  | VWord !Word64
  | VBool !Bool
  | VString !ByteString
  | VBytes !ByteString
  | VMessage !Message
  deriving (Eq, Show)

-- | What a message holds for one field number.
data Slot
  = -- | A singular field.
    Single !Value
  | -- | A repeated field, in order.
    Repeated !(Seq Value)
  deriving (Eq, Show)

-- | A message instance: its fields keyed by field number.  Fields that are
-- not present are absent from the map.
newtype Message = Message {messageFields :: IntMap Slot}
  deriving (Eq, Show)

-- | The message with no fields present.
emptyMessage :: Message
emptyMessage = Message IM.empty

-- | Is this the proto3 default for a scalar (zero, false, empty)?  Messages
-- are never default: a present sub-message is always significant.
isDefault :: Value -> Bool
isDefault v = case v of
  VInt n -> n == 0
  VWord n -> n == 0
  VBool b -> not b
  VString s -> BS.null s
  VBytes s -> BS.null s
  VMessage _ -> False

-- | Drop what canonical encoding drops: default singular scalars and empty
-- repeated fields (recursively).  @encode@ is invariant under 'normalize',
-- and so is the canonical text form.
normalize :: Message -> Message
normalize (Message m) = Message (IM.mapMaybe slot m)
  where
    slot (Single v)
      | isDefault v = Nothing
      | otherwise = Just (Single (value v))
    slot (Repeated vs)
      | Seq.null vs = Nothing
      | otherwise = Just (Repeated (fmap value vs))
    value (VMessage x) = VMessage (normalize x)
    value v = v
