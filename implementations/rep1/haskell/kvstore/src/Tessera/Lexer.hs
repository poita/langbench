{-# LANGUAGE OverloadedStrings #-}

-- | The lexer of SPEC §6.1.
module Tessera.Lexer
  ( Token (..)
  , lexLine
  ) where

import Data.Bits (shiftR, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (isDigit, isHexDigit, digitToInt)
import Tessera.Error (ErrorKind (..))
import Tessera.Query (CmpOp (..))

-- | A token.  A string token whose escapes contain an unpaired surrogate is
-- lexically fine but carries 'Nothing'; the parser turns it into @bad-utf8@
-- only when it actually consumes the token (SPEC §6.1, §18.2).
data Token
  = TWord !BS.ByteString
  | TInt !Integer
  | TString !(Maybe BS.ByteString)
  | TPunct !Char
  | TOp !CmpOp
  deriving (Eq, Show)

-- | Tokenise a whole line.  The only possible failure is 'Syntax'.
lexLine :: BS.ByteString -> Either ErrorKind [Token]
lexLine = go []
  where
    go acc s = case BC.uncons s of
      Nothing -> Right (reverse acc)
      Just (c, r)
        | c == ' ' || c == '\t' -> go acc r
        | wordStart c ->
            let (w, r') = BC.span wordChar s in go (TWord w : acc) r'
        | isDigit c || c == '-' -> do
            (t, r') <- lexInt s
            go (t : acc) r'
        | c == '"' -> do
            (t, r') <- lexString r
            go (TString t : acc) r'
        | c `elem` ("{}[](),:." :: String) -> go (TPunct c : acc) r
        | c == '=' -> case BC.uncons r of
            Just ('=', r') -> go (TOp OpEq : acc) r'
            _ -> Left Syntax
        | c == '!' -> case BC.uncons r of
            Just ('=', r') -> go (TOp OpNe : acc) r'
            _ -> Left Syntax
        | c == '<' -> case BC.uncons r of
            Just ('=', r') -> go (TOp OpLe : acc) r'
            _ -> go (TOp OpLt : acc) r
        | c == '>' -> case BC.uncons r of
            Just ('=', r') -> go (TOp OpGe : acc) r'
            _ -> go (TOp OpGt : acc) r
        | otherwise -> Left Syntax

wordStart, wordChar :: Char -> Bool
wordStart c = c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
wordChar c = wordStart c || (c >= '0' && c <= '9')

lexInt :: BS.ByteString -> Either ErrorKind (Token, BS.ByteString)
lexInt s
  | BS.null ds = Left Syntax
  | BS.length ds > 1 && BC.head ds == '0' = Left Syntax
  | neg && ds == "0" = Left Syntax
  | otherwise = Right (TInt (if neg then negate n else n), rest)
  where
    (neg, afterSign) = case BC.uncons s of
      Just ('-', r) -> (True, r)
      _ -> (False, s)
    (ds, rest) = BC.span isDigit afterSign
    n = BC.foldl' (\a d -> a * 10 + fromIntegral (digitToInt d)) 0 ds

-- | Lex the body of a string literal (the opening quote already consumed).
lexString :: BS.ByteString -> Either ErrorKind (Maybe BS.ByteString, BS.ByteString)
lexString = go False []
  where
    plain c = c /= '"' && c /= '\\' && c >= ' '
    go bad acc s =
      let (lit, r) = BC.span plain s
          acc' = if BS.null lit then acc else lit : acc
       in case BC.uncons r of
            Nothing -> Left Syntax
            Just ('"', r') -> Right (if bad then Nothing else Just (BS.concat (reverse acc')), r')
            Just ('\\', r') -> escape bad acc' r'
            Just _ -> Left Syntax -- a control byte
    escape bad acc r = case BC.uncons r of
      Nothing -> Left Syntax
      Just (e, r') -> case e of
        '"' -> go bad (BS.singleton 0x22 : acc) r'
        '\\' -> go bad (BS.singleton 0x5C : acc) r'
        '/' -> go bad (BS.singleton 0x2F : acc) r'
        'b' -> go bad (BS.singleton 0x08 : acc) r'
        'f' -> go bad (BS.singleton 0x0C : acc) r'
        'n' -> go bad (BS.singleton 0x0A : acc) r'
        'r' -> go bad (BS.singleton 0x0D : acc) r'
        't' -> go bad (BS.singleton 0x09 : acc) r'
        'u' -> case hex4 r' of
          Nothing -> Left Syntax
          Just (cu, r'')
            | cu >= 0xD800 && cu <= 0xDBFF -> case lowSurrogate r'' of
                Just (lo, r3) ->
                  go bad (utf8 (0x10000 + ((cu - 0xD800) * 0x400) + (lo - 0xDC00)) : acc) r3
                Nothing -> go True acc r''
            | cu >= 0xDC00 && cu <= 0xDFFF -> go True acc r''
            | otherwise -> go bad (utf8 cu : acc) r''
        _ -> Left Syntax
    lowSurrogate r = case BC.uncons r of
      Just ('\\', r1) -> case BC.uncons r1 of
        Just ('u', r2) -> case hex4 r2 of
          Just (lo, r3) | lo >= 0xDC00 && lo <= 0xDFFF -> Just (lo, r3)
          _ -> Nothing
        _ -> Nothing
      _ -> Nothing

hex4 :: BS.ByteString -> Maybe (Int, BS.ByteString)
hex4 s
  | BS.length h == 4 && BC.all isHexDigit h = Just (foldl' (\a d -> a * 16 + digitToInt d) 0 (BC.unpack h), r)
  | otherwise = Nothing
  where
    (h, r) = BS.splitAt 4 s

-- | UTF-8 encoding of a Unicode scalar value.
utf8 :: Int -> BS.ByteString
utf8 c
  | c < 0x80 = BS.pack [b c]
  | c < 0x800 = BS.pack [0xC0 .|. b (c `shiftR` 6), cont c]
  | c < 0x10000 = BS.pack [0xE0 .|. b (c `shiftR` 12), cont (c `shiftR` 6), cont c]
  | otherwise = BS.pack [0xF0 .|. b (c `shiftR` 18), cont (c `shiftR` 12), cont (c `shiftR` 6), cont c]
  where
    b = fromIntegral
    cont x = 0x80 .|. fromIntegral (x .&. 0x3F)
