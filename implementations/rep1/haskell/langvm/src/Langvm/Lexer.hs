-- | The lexer (SPEC.md section 3).
module Langvm.Lexer
  ( Tok (..)
  , Token (..)
  , lexModule
  ) where

import Data.Char (chr, digitToInt, isAsciiLower, isAsciiUpper, isDigit, isHexDigit)

import Langvm.Diagnostic
import Langvm.Number (decimalToDouble)

data Tok
  = TIdent String
  | TKw String
  | TSym String      -- ^ operators, punctuation and the wildcard @_@
  | TInt Int
  | TFloat Double
  | TStr String
  | TChar Char
  deriving (Eq, Show)

data Token = Token { tokTok :: !Tok, tokPos :: !Pos }
  deriving (Show)

keywordSet :: [String]
keywordSet =
  [ "as", "break", "continue", "else", "enum", "false", "fn", "for", "if"
  , "impl", "in", "let", "match", "pub", "return", "self", "struct", "trait"
  , "true", "use", "var", "when", "while" ]

twoChar :: [String]
twoChar = ["#[", "::", "..", "->", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "++"]

oneChar :: String
oneChar = "()[]{},;:.|+-*/%!~&^<>="

isIdStart, isIdChar :: Char -> Bool
isIdStart c = isAsciiLower c || isAsciiUpper c || c == '_'
isIdChar c = isIdStart c || isDigit c

-- | Lex a module body (given as its lines) into tokens.
lexModule :: [String] -> Either Diagnostic [Token]
lexModule ls = go 1 1 (joinLines ls)
  where
    joinLines [] = []
    joinLines [l] = l
    joinLines (l : r) = l ++ "\n" ++ joinLines r

    err k l c = Left (Diagnostic k (Pos l c))

    go :: Int -> Int -> String -> Either Diagnostic [Token]
    go _ _ [] = Right []
    go l c s@(ch : rest)
      | ch == '\n' = go (l + 1) 1 rest
      | ch == ' ' || ch == '\t' || ch == '\r' = go l (c + 1) rest
      | ch == '/', ('/' : r) <- rest =
          let (cm, r') = break (== '\n') r in go l (c + 2 + length cm) r'
      | ch == '/', ('*' : r) <- rest = blockComment l c l (c + 2) (1 :: Int) r
      | isIdStart ch =
          let (name, r) = span isIdChar s
              n = length name
          in if name == "_" then emit (TSym "_") l c n r
             else if n > 200 then err BadToken l c
             else if name `elem` keywordSet then emit (TKw name) l c n r
             else emit (TIdent name) l c n r
      | isDigit ch = number l c s
      | ch == '"' = string l c rest l (c + 1) []
      | ch == '\'' = charLit l c rest
      | ch == '#' = case rest of
          ('[' : r) -> emit (TSym "#[") l c 2 r
          _ -> err BadToken l c
      | otherwise = case s of
          (a : b : r) | [a, b] `elem` twoChar -> emit (TSym [a, b]) l c 2 r
          _ | ch `elem` oneChar -> emit (TSym [ch]) l c 1 rest
            | otherwise -> err BadToken l c

    emit t l c n r = (Token t (Pos l c) :) <$> go l (c + n) r

    -- Block comment: (line, col) of the outermost opener, current position.
    blockComment ol oc l c depth s = case s of
      [] -> err Unterminated ol oc
      ('*' : '/' : r)
        | depth == 1 -> go l (c + 2) r
        | otherwise -> blockComment ol oc l (c + 2) (depth - 1) r
      ('/' : '*' : r) -> blockComment ol oc l (c + 2) (depth + 1) r
      ('\n' : r) -> blockComment ol oc (l + 1) 1 depth r
      (_ : r) -> blockComment ol oc l (c + 1) depth r

    -- Numbers -------------------------------------------------------------
    number l c s = case s of
      ('0' : 'x' : r) -> radix 16 isHexDigit 2 r
      ('0' : 'b' : r) -> radix 2 (`elem` "01") 2 r
      _ -> decimal
      where
        radix :: Integer -> (Char -> Bool) -> Int -> String -> Either Diagnostic [Token]
        radix base isD pre r = case r of
          (d : _) | isD d ->
            let (run, r') = span (\x -> isD x || x == '_') r
                v = foldl (\a x -> a * base + toInteger (digitToInt x)) 0 (filter (/= '_') run)
            in intTok v (pre + length run) r'
          _ -> err BadToken l c
        intTok v n r
          | v > 9223372036854775807 = err IntRange l c
          | otherwise = emit (TInt (fromInteger v)) l c n r
        digitsRun = span (\x -> isDigit x || x == '_')
        decimal =
          let (ip, r1) = digitsRun s
              (fp, r2, hasFrac) = case r1 of
                ('.' : r@(d : _)) | isDigit d -> let (f, r') = digitsRun r in (f, r', True)
                _ -> ("", r1, False)
              expo = case r2 of
                (e : r) | e == 'e' || e == 'E' -> case r of
                  (sg : r'@(d : _)) | (sg == '+' || sg == '-') && isDigit d ->
                    let (xs, r'') = digitsRun r' in Just (sg == '-', xs, 2 + length xs, r'')
                  (d : _) | isDigit d ->
                    let (xs, r'') = digitsRun r in Just (False, xs, 1 + length xs, r'')
                  _ -> Nothing
                _ -> Nothing
              clean = filter (/= '_')
          in case (hasFrac, expo) of
               (False, Nothing) ->
                 intTok (read (clean ip)) (length ip) r1
               _ ->
                 let (eneg, ex, elen, rEnd) = case expo of
                       Just (n, xs, k, rr) -> (n, clean xs, k, rr)
                       Nothing -> (False, "0", 0, r2)
                     fracD = clean fp
                     mant = read (clean ip ++ fracD) :: Integer
                     e10 = (if eneg then negate else id) (read ex :: Integer)
                           - toInteger (length fracD)
                     v = decimalToDouble mant e10
                     n = length ip + (if hasFrac then 1 + length fp else 0) + elen
                 in emit (TFloat v) l c n rEnd

    -- Strings and characters -------------------------------------------------
    -- Strings: (opening position), the text after the quote, current position.
    string ol oc s l c acc = case s of
      [] -> err Unterminated ol oc
      ('"' : r) -> (Token (TStr (reverse acc)) (Pos ol oc) :) <$> go l (c + 1) r
      ('\n' : _) -> err Unterminated ol oc
      ('\r' : _) -> err Unterminated ol oc
      ('\\' : r) -> case escape r of
        Nothing -> err BadEscape l c
        Just (ch, used, r') -> string ol oc r' l (c + 1 + used) (ch : acc)
      (ch : r) -> string ol oc r l (c + 1) (ch : acc)

    charLit l c s = case s of
      [] -> err Unterminated l c
      ('\\' : r) -> case escape r of
        Nothing -> err BadEscape l (c + 1)
        Just (ch, used, r') -> closeChar ch (c + 2 + used) r'
      (ch : r)
        | ch `elem` "'\n\r" -> err Unterminated l c
        | otherwise -> closeChar ch (c + 2) r
      where
        closeChar ch c' r = case r of
          ('\'' : r') -> (Token (TChar ch) (Pos l c) :) <$> go l (c' + 1) r'
          _ -> err Unterminated l c

    -- After a backslash: the character, the number of characters consumed
    -- after the backslash, and the rest.
    escape :: String -> Maybe (Char, Int, String)
    escape s = case s of
      ('n' : r) -> Just ('\n', 1, r)
      ('t' : r) -> Just ('\t', 1, r)
      ('r' : r) -> Just ('\r', 1, r)
      ('0' : r) -> Just ('\0', 1, r)
      ('\\' : r) -> Just ('\\', 1, r)
      ('\'' : r) -> Just ('\'', 1, r)
      ('"' : r) -> Just ('"', 1, r)
      ('u' : '{' : r) ->
        let (hs, r') = span isHexDigit r
        in case r' of
             ('}' : r'')
               | not (null hs), length hs <= 6
               , let v = foldl (\a x -> a * 16 + digitToInt x) 0 hs
               , v <= 0x10FFFF, not (v >= 0xD800 && v <= 0xDFFF)
               -> Just (chr v, 3 + length hs, r'')
             _ -> Nothing
      _ -> Nothing
