-- |
-- Module      : Protowire.Schema
-- Description : Message schemas: descriptors and the schema parser.
--
-- A schema is a set of @message@ definitions.  'parseSchema' turns schema
-- source text into a 'Schema' whose field types are fully resolved: a field
-- of message type points directly at the 'MessageDesc' of that message
-- (recursive types give a cyclic, lazily built structure), and each message
-- offers field lookup by number and by name.
--
-- The accepted syntax is the one described in the project README:
--
-- > message Name { [repeated] type name = number; ... }
module Protowire.Schema
  ( -- * Descriptors
    Schema
  , MessageDesc (..)
  , FieldDesc (..)
  , FieldType (..)
  , ScalarType (..)
    -- * Parsing
  , parseSchema
  , SchemaError (..)
    -- * Queries
  , lookupMessage
  , messageNames
  , WireType
  , wireTypeOf
  , scalarWireType
  , isPackable
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Char (isAlphaNum, isSpace)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M

-- | The scalar field types.
data ScalarType
  = TInt32
  | TInt64
  | TUInt32
  | TUInt64
  | TSInt32
  | TSInt64
  | TBool
  | TFixed32
  | TFixed64
  | TSFixed32
  | TSFixed64
  | TString
  | TBytes
  deriving (Eq, Show, Enum, Bounded)

-- | The type of a field: a scalar or (a reference to) a message.
data FieldType
  = FScalar !ScalarType
  | -- | A message-typed field.  The descriptor is shared with the schema and
    -- may be cyclic, so it is lazy and 'Show' does not descend into it.
    FMessage MessageDesc

instance Show FieldType where
  showsPrec d (FScalar s) = showParen (d > 10) $ showString "FScalar " . showsPrec 11 s
  showsPrec d (FMessage m) =
    showParen (d > 10) $ showString "FMessage " . showsPrec 11 (msgName m)

-- | One field of a message.
data FieldDesc = FieldDesc
  { fieldName :: !ByteString
  , fieldNumber :: !Int
  , fieldRepeated :: !Bool
  , fieldType :: FieldType
  }
  deriving (Show)

-- | A message definition with its fields indexed for lookup.
data MessageDesc = MessageDesc
  { msgName :: !ByteString
  , msgFields :: [FieldDesc]
  -- ^ In increasing field-number order.
  , msgByNumber :: !(IntMap FieldDesc)
  , msgByName :: !(Map ByteString FieldDesc)
  }
  deriving (Show)

-- | A set of message definitions, by name.
newtype Schema = Schema (Map ByteString MessageDesc)
  deriving (Show)

-- | Why a schema failed to parse.
data SchemaError
  = -- | A token other than the expected one was found.
    UnexpectedToken String
  | -- | The input ended inside a definition.
    UnexpectedEnd
  | -- | A character that cannot start a token.
    BadCharacter Char
  | -- | A field refers to a type that is neither scalar nor a defined message.
    UnknownType ByteString
  | -- | Two messages share a name.
    DuplicateMessage ByteString
  deriving (Eq, Show)

-- | Look a message up by name.
lookupMessage :: ByteString -> Schema -> Maybe MessageDesc
lookupMessage n (Schema m) = M.lookup n m

-- | All message names, in sorted order.
messageNames :: Schema -> [ByteString]
messageNames (Schema m) = M.keys m

-- | A wire type number (0, 1, 2, 3, 4 or 5).
type WireType = Int

-- | The wire type used to encode a value of the given scalar type.
scalarWireType :: ScalarType -> WireType
scalarWireType t = case t of
  TFixed64 -> 1
  TSFixed64 -> 1
  TFixed32 -> 5
  TSFixed32 -> 5
  TString -> 2
  TBytes -> 2
  _ -> 0

-- | The wire type of a field's elements (2 for messages).
wireTypeOf :: FieldType -> WireType
wireTypeOf (FScalar s) = scalarWireType s
wireTypeOf (FMessage _) = 2

-- | Whether a repeated field of this type may be packed (all numeric types).
isPackable :: FieldType -> Bool
isPackable (FScalar TString) = False
isPackable (FScalar TBytes) = False
isPackable (FScalar _) = True
isPackable (FMessage _) = False

scalarNames :: Map ByteString ScalarType
scalarNames =
  M.fromList
    [ (BC.pack "int32", TInt32)
    , (BC.pack "int64", TInt64)
    , (BC.pack "uint32", TUInt32)
    , (BC.pack "uint64", TUInt64)
    , (BC.pack "sint32", TSInt32)
    , (BC.pack "sint64", TSInt64)
    , (BC.pack "bool", TBool)
    , (BC.pack "fixed32", TFixed32)
    , (BC.pack "fixed64", TFixed64)
    , (BC.pack "sfixed32", TSFixed32)
    , (BC.pack "sfixed64", TSFixed64)
    , (BC.pack "string", TString)
    , (BC.pack "bytes", TBytes)
    ]

------------------------------------------------------------------------------
-- Tokenizer

isWordChar :: Char -> Bool
isWordChar c = c == '_' || (c < '\x80' && isAlphaNum c)

isPunct :: Char -> Bool
isPunct c = c `elem` "{};="

tokenize :: ByteString -> Either SchemaError [ByteString]
tokenize s = case BC.uncons (BC.dropWhile isSpace' s) of
  Nothing -> Right []
  Just (c, rest)
    | isPunct c -> (BC.singleton c :) <$> tokenize rest
    | isWordChar c ->
        let (w, rest') = BC.span isWordChar (BC.cons c rest)
         in (w :) <$> tokenize rest'
    | otherwise -> Left (BadCharacter c)
  where
    isSpace' c = c == ' ' || c == '\t' || c == '\r' || c == '\n' || (c < '\x80' && isSpace c)

------------------------------------------------------------------------------
-- Parser

data RawField = RawField
  { rfRepeated :: Bool
  , rfType :: ByteString
  , rfName :: ByteString
  , rfNumber :: Int
  }

type Raw = (ByteString, [RawField])

expect :: String -> [ByteString] -> Either SchemaError [ByteString]
expect w (t : ts) | t == BC.pack w = Right ts
expect _ (t : _) = Left (UnexpectedToken (BC.unpack t))
expect _ [] = Left UnexpectedEnd

parseMessages :: [ByteString] -> Either SchemaError [Raw]
parseMessages [] = Right []
parseMessages ts = do
  ts1 <- expect "message" ts
  (name, ts2) <- word ts1
  ts3 <- expect "{" ts2
  (fields, ts4) <- parseFields ts3
  ((name, fields) :) <$> parseMessages ts4

word :: [ByteString] -> Either SchemaError (ByteString, [ByteString])
word (t : ts) | not (BC.null t), isWordChar (BC.head t) = Right (t, ts)
word (t : _) = Left (UnexpectedToken (BC.unpack t))
word [] = Left UnexpectedEnd

parseFields :: [ByteString] -> Either SchemaError ([RawField], [ByteString])
parseFields (t : ts) | t == BC.pack "}" = Right ([], ts)
parseFields ts0 = do
  let (rep, ts1) = case ts0 of
        (t : r) | t == BC.pack "repeated" -> (True, r)
        _ -> (False, ts0)
  (ty, ts2) <- word ts1
  (nm, ts3) <- word ts2
  ts4 <- expect "=" ts3
  (numTok, ts5) <- word ts4
  num <- case BC.readInt numTok of
    Just (n, r) | BC.null r -> Right n
    _ -> Left (UnexpectedToken (BC.unpack numTok))
  ts6 <- expect ";" ts5
  (rest, ts7) <- parseFields ts6
  Right (RawField rep ty nm num : rest, ts7)

-- | Parse schema source text.
--
-- The schema is assumed to be well-formed in the sense of the specification
-- (unique names and numbers, valid number ranges); only syntax and type
-- resolution are checked.
parseSchema :: ByteString -> Either SchemaError Schema
parseSchema src = do
  raws <- tokenize src >>= parseMessages
  let names = M.fromList [(n, ()) | (n, _) <- raws]
  checkDuplicates raws
  mapM_ (checkTypes names) raws
  -- Knot-tying: field types refer back into the schema being built.
  let schema = M.fromList [(n, build n fs) | (n, fs) <- raws]
      build n fs =
        let fds = sortOn fieldNumber [mkField f | f <- fs]
         in MessageDesc
              { msgName = n
              , msgFields = fds
              , msgByNumber = IM.fromList [(fieldNumber f, f) | f <- fds]
              , msgByName = M.fromList [(fieldName f, f) | f <- fds]
              }
      mkField f =
        FieldDesc
          { fieldName = rfName f
          , fieldNumber = rfNumber f
          , fieldRepeated = rfRepeated f
          , fieldType = case M.lookup (rfType f) scalarNames of
              Just s -> FScalar s
              Nothing -> FMessage (schema M.! rfType f)
          }
  Right (Schema schema)
  where
    checkDuplicates = go M.empty
      where
        go _ [] = Right ()
        go seen ((n, _) : r)
          | M.member n seen = Left (DuplicateMessage n)
          | otherwise = go (M.insert n () seen) r
    checkTypes names (_, fs) = mapM_ check fs
      where
        check f
          | M.member (rfType f) scalarNames || M.member (rfType f) names = Right ()
          | otherwise = Left (UnknownType (rfType f))
