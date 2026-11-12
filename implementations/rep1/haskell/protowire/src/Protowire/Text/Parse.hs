{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Protowire.Text.Parse
-- Description : Parse the text form into a 'Message', checked against a schema.
--
-- The parser is a recursive descent over the raw bytes of the text.  It
-- accepts the canonical form plus the relaxations described in the README
-- (free spacing, any field order, explicit defaults, hex or case-insensitive
-- escapes) and rejects everything else.
module Protowire.Text.Parse
  ( parseMessage
  , TextError (..)
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU
import Data.Char (isDigit)
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import qualified Data.Sequence as Seq
import Data.Word (Word8)
import Protowire.Hex (decodeHex)
import Protowire.Schema
import Protowire.Utf8 (isValidUtf8)
import Protowire.Value

-- | A syntax or type error, with the byte offset where it was detected.
data TextError = TextError
  { errOffset :: !Int
  , errReason :: String
  }
  deriving (Eq, Show)

-- Parser state is the unconsumed input.  Errors carry the remaining length
-- and are converted to an offset at the top.
newtype P a = P {runP :: ByteString -> Either (Int, String) (a, ByteString)}

instance Functor P where
  fmap f (P g) = P $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> Right (f a, s')

instance Applicative P where
  pure a = P $ \s -> Right (a, s)
  P f <*> P g = P $ \s -> case f s of
    Left e -> Left e
    Right (h, s') -> case g s' of
      Left e -> Left e
      Right (a, s'') -> Right (h a, s'')

instance Monad P where
  P g >>= f = P $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> runP (f a) s'

failP :: String -> P a
failP msg = P $ \s -> Left (BS.length s, msg)

peek :: P (Maybe Char)
peek = P $ \s -> Right (fmap fst (BC.uncons s), s)

advance :: Int -> P ()
advance k = P $ \s -> Right ((), BU.unsafeDrop k s)

spaces :: P ()
spaces = P $ \s -> Right ((), BC.dropWhile (== ' ') s)

char :: Char -> P ()
char c = do
  m <- peek
  if m == Just c then advance 1 else failP ("expected " ++ show c)

-- | Parse a complete text-form message (surrounding spaces allowed) against
-- a message descriptor.
parseMessage :: MessageDesc -> ByteString -> Either TextError Message
parseMessage desc input =
  case runP (spaces *> pMessage desc <* spaces) input of
    Left (rest, msg) -> Left (TextError (BS.length input - rest) msg)
    Right (m, rest)
      | BS.null rest -> Right m
      | otherwise -> Left (TextError (BS.length input - BS.length rest) "trailing text")

isIdent :: Char -> Bool
isIdent c = c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit c

pMessage :: MessageDesc -> P Message
pMessage desc = do
  char '{'
  spaces
  m <- peek
  case m of
    Just '}' -> advance 1 >> pure emptyMessage
    _ -> fields IM.empty
  where
    fields !acc = do
      name <- P $ \s -> let (w, r) = BC.span isIdent s in Right (w, r)
      fd <- maybe (failP "unknown field") pure (M.lookup name (msgByName desc))
      spaces
      char ':'
      spaces
      let num = fieldNumber fd
      if IM.member num acc then failP "duplicate field" else pure ()
      slot <- pField fd
      let acc' = IM.insert num slot acc
      spaces
      c <- peek
      case c of
        Just ',' -> advance 1 >> spaces >> fields acc'
        Just '}' -> advance 1 >> pure (Message acc')
        _ -> failP "expected ',' or '}'"

pField :: FieldDesc -> P Slot
pField fd
  | fieldRepeated fd = Repeated <$> pList (pValue ty)
  | otherwise = Single <$> pValue ty
  where
    ty = fieldType fd

pList :: P a -> P (Seq.Seq a)
pList p = do
  char '['
  spaces
  c <- peek
  case c of
    Just ']' -> advance 1 >> pure Seq.empty
    _ -> go Seq.empty
  where
    go !acc = do
      v <- p
      spaces
      c <- peek
      let acc' = acc Seq.|> v
      case c of
        Just ',' -> advance 1 >> spaces >> go acc'
        Just ']' -> advance 1 >> pure acc'
        _ -> failP "expected ',' or ']'"

pValue :: FieldType -> P Value
pValue (FMessage d) = VMessage <$> pMessage d
pValue (FScalar s) = case s of
  TBool -> pBool
  TString -> VString <$> pStringLit
  TBytes -> VBytes <$> pBytesLit
  _ -> pInteger s

pBool :: P Value
pBool = P $ \s ->
  if BC.pack "true" `BS.isPrefixOf` s
    then Right (VBool True, BS.drop 4 s)
    else
      if BC.pack "false" `BS.isPrefixOf` s
        then Right (VBool False, BS.drop 5 s)
        else Left (BS.length s, "expected a bool")

pInteger :: ScalarType -> P Value
pInteger ty = do
  neg <- P $ \s -> case BC.uncons s of
    Just ('-', r) -> Right (True, r)
    _ -> Right (False, s)
  digits <- P $ \s -> let (d, r) = BC.span isDigit s in Right (d, r)
  if BS.null digits then failP "expected an integer" else pure ()
  if BS.length digits > 1 && BC.head digits == '0' then failP "leading zero" else pure ()
  if neg && digits == BC.pack "0" then failP "negative zero" else pure ()
  if BS.length digits > 20 then failP "integer out of range" else pure ()
  let mag = BS.foldl' (\a d -> a * 10 + fromIntegral (d - 48)) 0 digits :: Integer
      n = if neg then negate mag else mag
      (lo, hi) = range ty
  if n < lo || n > hi then failP "integer out of range" else pure ()
  pure $ case ty of
    TUInt32 -> VWord (fromInteger n)
    TUInt64 -> VWord (fromInteger n)
    TFixed32 -> VWord (fromInteger n)
    TFixed64 -> VWord (fromInteger n)
    _ -> VInt (fromInteger n)

range :: ScalarType -> (Integer, Integer)
range t = case t of
  TInt32 -> s 31
  TSInt32 -> s 31
  TSFixed32 -> s 31
  TInt64 -> s 63
  TSInt64 -> s 63
  TSFixed64 -> s 63
  TUInt32 -> u 32
  TFixed32 -> u 32
  _ -> u 64
  where
    s k = (negate (2 ^ (k :: Int)), 2 ^ k - 1)
    u k = (0, 2 ^ (k :: Int) - 1)

-- | @x"…"@: lowercase hex, even length.
pBytesLit :: P ByteString
pBytesLit = do
  char 'x'
  char '"'
  hex <- P $ \s -> let (h, r) = BS.break (== 0x22) s in Right (h, r)
  char '"'
  maybe (failP "invalid hex") pure (decodeHex hex)

-- | A string literal; escapes are resolved and the result must be UTF-8.
pStringLit :: P ByteString
pStringLit = do
  char '"'
  bytes <- P $ \s -> body [] s
  if isValidUtf8 bytes then pure bytes else failP "invalid UTF-8"
  where
    plain :: Word8 -> Bool
    plain w = w >= 0x20 && w /= 0x22 && w /= 0x5c
    body :: [ByteString] -> ByteString -> Either (Int, String) (ByteString, ByteString)
    body acc s =
      let (chunk, rest) = BS.span plain s
          acc' = chunk : acc
       in case BS.uncons rest of
            Nothing -> Left (0, "unterminated string")
            Just (0x22, r) -> Right (BS.concat (reverse acc'), r)
            Just (0x5c, r) -> case BS.uncons r of
              Nothing -> Left (0, "unterminated string")
              Just (c, r')
                | Just w <- simple c -> body (BS.singleton w : acc') r'
                | c == 0x78 -> case BS.unpack (BS.take 2 r') of
                    [a, b] | Just x <- hexVal a, Just y <- hexVal b ->
                      body (BS.singleton ((x `shiftL` 4) .|. y) : acc') (BS.drop 2 r')
                    _ -> Left (BS.length r', "bad \\x escape")
                | otherwise -> Left (BS.length r', "bad escape")
            Just _ -> Left (BS.length rest, "control character in string")
    simple c = case c of
      0x22 -> Just 0x22
      0x5c -> Just 0x5c
      0x6e -> Just 0x0a
      0x72 -> Just 0x0d
      0x74 -> Just 0x09
      _ -> Nothing
    hexVal :: Word8 -> Maybe Word8
    hexVal w
      | w >= 0x30 && w <= 0x39 = Just (w - 0x30)
      | w >= 0x61 && w <= 0x66 = Just (w - 0x61 + 10)
      | w >= 0x41 && w <= 0x46 = Just (w - 0x41 + 10)
      | otherwise = Nothing
