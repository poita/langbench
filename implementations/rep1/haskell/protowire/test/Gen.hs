-- | QuickCheck generators for schema-conforming messages.
module Gen
  ( testSchemaSource
  , testSchema
  , rootDesc
  , genMessage
  , genUtf8
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString (ByteString)
import Data.Int (Int32)
import qualified Data.IntMap.Strict as IM
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word32)
import Protowire
import Test.QuickCheck

-- | A schema exercising every scalar type, repeated fields, and recursion.
testSchemaSource :: ByteString
testSchemaSource =
  BC.pack $
    unlines
      [ "message Root {"
      , "  int32 i32 = 1; int64 i64 = 2; uint32 u32 = 3; uint64 u64 = 4;"
      , "  sint32 s32 = 5; sint64 s64 = 6; bool b = 7;"
      , "  fixed32 f32 = 8; fixed64 f64 = 9; sfixed32 sf32 = 10; sfixed64 sf64 = 11;"
      , "  string str = 12; bytes by = 13; Node node = 14;"
      , "  repeated int32 ri32 = 21; repeated int64 ri64 = 22; repeated uint32 ru32 = 23;"
      , "  repeated uint64 ru64 = 24; repeated sint32 rs32 = 25; repeated sint64 rs64 = 26;"
      , "  repeated bool rb = 27; repeated fixed32 rf32 = 28; repeated fixed64 rf64 = 29;"
      , "  repeated sfixed32 rsf32 = 30; repeated sfixed64 rsf64 = 31;"
      , "  repeated string rstr = 32; repeated bytes rby = 33; repeated Node rnode = 34;"
      , "}"
      , "message Node { int32 v = 1; repeated Node kids = 2; string name = 3; Root root = 4; }"
      ]

testSchema :: Schema
testSchema = either (error . show) id (parseSchema testSchemaSource)

rootDesc :: MessageDesc
rootDesc = maybe (error "Root") id (lookupMessage (BC.pack "Root") testSchema)

-- | Valid UTF-8, biased towards interesting characters.
genUtf8 :: Gen ByteString
genUtf8 = TE.encodeUtf8 . T.pack <$> listOf (frequency [(6, choose ('a', 'z')), (2, elements "\"\\\n\r\t\0\DEL\US "), (1, elements "é€😀\x10FFFF")])

genScalar :: ScalarType -> Gen Value
genScalar t = case t of
  TInt32 -> VInt . fromIntegral <$> (arbitrary :: Gen Int32)
  TSInt32 -> VInt . fromIntegral <$> (arbitrary :: Gen Int32)
  TSFixed32 -> VInt . fromIntegral <$> (arbitrary :: Gen Int32)
  TInt64 -> VInt <$> arbitrary
  TSInt64 -> VInt <$> arbitrary
  TSFixed64 -> VInt <$> arbitrary
  TUInt32 -> VWord . fromIntegral <$> (arbitrary :: Gen Word32)
  TFixed32 -> VWord . fromIntegral <$> (arbitrary :: Gen Word32)
  TUInt64 -> VWord <$> arbitrary
  TFixed64 -> VWord <$> arbitrary
  TBool -> VBool <$> arbitrary
  TString -> VString <$> genUtf8
  TBytes -> VBytes . BS.pack <$> arbitrary

genValue :: Int -> FieldType -> Gen Value
genValue _ (FScalar t) = frequency [(1, pure (zero t)), (4, genScalar t)]
  where
    zero TBool = VBool False
    zero TString = VString BS.empty
    zero TBytes = VBytes BS.empty
    zero s | s `elem` [TUInt32, TUInt64, TFixed32, TFixed64] = VWord 0
    zero _ = VInt 0
genValue depth (FMessage d) = VMessage <$> genMessageDepth (depth - 1) d

genMessageDepth :: Int -> MessageDesc -> Gen Message
genMessageDepth depth d = Message . IM.fromList . concat <$> mapM field (msgFields d)
  where
    field fd = do
      present <- frequency [(1, pure False), (2, pure True)]
      let isMsg = case fieldType fd of FMessage _ -> True; _ -> False
      if not present || (isMsg && depth <= 0)
        then pure []
        else
          if fieldRepeated fd
            then do
              vs <- resize 6 (listOf (genValue depth (fieldType fd)))
              pure [(fieldNumber fd, Repeated (Seq.fromList vs))]
            else do
              v <- genValue depth (fieldType fd)
              pure [(fieldNumber fd, Single v)]

genMessage :: Gen Message
genMessage = genMessageDepth 3 rootDesc
