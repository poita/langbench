-- |
-- Module      : Spreadsheet.Parser
-- Description : Parsing of cell names, cell contents and formulas.
--
-- Formulas are parsed once, by recursive descent, into an 'Expr' with all
-- references resolved.  Evaluation never looks at the source text again.
module Spreadsheet.Parser
  ( ParseError (..)
  , parseCellRef
  , parseContent
  , parseFormula
  , parseNumber
  ) where

import Data.Char (isAsciiUpper, isDigit)
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T

import Spreadsheet.Types

-- | A syntax error, with a human-readable message.
newtype ParseError = ParseError String
  deriving (Eq, Show)

-- | Parse a cell name such as @B12@.  Returns 'Nothing' unless it is a valid
-- reference: one or two uppercase letters followed by a row number 1..9999
-- without leading zeros.
parseCellRef :: Text -> Maybe CellRef
parseCellRef = resolveRef . T.unpack

resolveRef :: String -> Maybe CellRef
resolveRef s = case span isAsciiUpper s of
  (letters, digits)
    | n >= 1 && n <= 2
    , d0 : _ <- digits
    , d0 /= '0'
    , all isDigit digits
    , length digits <= 4 ->
        mkCellRef (foldl' (\a c -> a * 26 + (fromEnum c - 64)) 0 letters) (read digits)
    where
      n = length letters
  _ -> Nothing

-- | Convert @-?[0-9]+(\\.[0-9]+)?@ to the nearest double (correctly rounded,
-- ties to even).  @-0@ is the number zero.
parseNumber :: Text -> Maybe Double
parseNumber t = case T.unpack t of
  '-' : rest -> negate' <$> unsigned rest
  s -> unsigned s
  where
    negate' d = if d == 0 then 0 else negate d
    unsigned s = case span isDigit s of
      (ip@(_ : _), "") -> Just (decimal ip "")
      (ip@(_ : _), '.' : fp@(_ : _))
        | all isDigit fp -> Just (decimal ip fp)
      _ -> Nothing

decimal :: String -> String -> Double
decimal ip fp = fromRational (digitsToInteger (ip ++ fp) % (10 ^ length fp))

digitsToInteger :: String -> Integer
digitsToInteger = foldl' (\a c -> a * 10 + fromIntegral (fromEnum c - 48)) 0

-- | Parse the content of a cell as given after @set A1 @: a formula
-- (starting with @=@), a string literal (in double quotes) or a number.
parseContent :: Text -> Either ParseError Content
parseContent t = case T.uncons t of
  Just ('=', rest) -> CFormula <$> parseFormula rest
  Just ('"', rest)
    | Just (body, '"') <- T.unsnoc rest
    , not (T.any (== '"') body) -> Right (CText body)
    | otherwise -> Left (ParseError "malformed string literal")
  _ -> maybe (Left (ParseError ("invalid content: " ++ T.unpack t))) (Right . CNumber) (parseNumber t)

-- | Parse the text after the @=@ of a formula.  A formula that mentions an
-- invalid reference anywhere parses successfully to 'EInvalidRef'.
parseFormula :: Text -> Either ParseError Expr
parseFormula src = do
  toks <- tokenize (T.unpack src)
  (e, rest) <- runP pExpr toks
  case rest of
    [] -> Right (if hasInvalid e then EInvalidRef else e)
    t : _ -> Left (ParseError ("unexpected " ++ show t))

hasInvalid :: Expr -> Bool
hasInvalid e = case e of
  EInvalidRef -> True
  ENeg x -> hasInvalid x
  EBinary _ a b -> hasInvalid a || hasInvalid b
  EIf a b c -> hasInvalid a || hasInvalid b || hasInvalid c
  ECall _ args -> any argInvalid args
  _ -> False
  where
    argInvalid (ArgExpr x) = hasInvalid x
    argInvalid _ = False

------------------------------------------------------------------------------
-- Lexer

data Token
  = TNum Double
  | TStr Text
  | TRef String    -- letters followed by digits
  | TName String   -- letters only (a function name)
  | TSym String
  deriving (Eq, Show)

tokenize :: String -> Either ParseError [Token]
tokenize [] = Right []
tokenize s@(c : cs)
  | c == ' ' = tokenize cs
  | isDigit c =
      let (ip, r1) = span isDigit s
       in case r1 of
            '.' : r2@(d : _)
              | isDigit d ->
                  let (fp, r3) = span isDigit r2 in (TNum (decimal ip fp) :) <$> tokenize r3
            _ -> (TNum (decimal ip "") :) <$> tokenize r1
  | c == '"' = case break (== '"') cs of
      (body, _ : r) -> (TStr (T.pack body) :) <$> tokenize r
      _ -> Left (ParseError "unterminated string")
  | isAsciiUpper c =
      let (letters, r1) = span isAsciiUpper s
          (digits, r2) = span isDigit r1
       in ((if null digits then TName letters else TRef (letters ++ digits)) :) <$> tokenize r2
  | otherwise = case s of
      '<' : '>' : r -> sym "<>" r
      '<' : '=' : r -> sym "<=" r
      '>' : '=' : r -> sym ">=" r
      _
        | c `elem` "=<>&+-*/(),:" -> sym [c] cs
        | otherwise -> Left (ParseError ("unexpected character " ++ show c))
  where
    sym x r = (TSym x :) <$> tokenize r

------------------------------------------------------------------------------
-- Parser

newtype P a = P {runP :: [Token] -> Either ParseError (a, [Token])}

instance Functor P where
  fmap f (P p) = P $ \ts -> case p ts of
    Left e -> Left e
    Right (a, r) -> Right (f a, r)

instance Applicative P where
  pure a = P $ \ts -> Right (a, ts)
  P pf <*> P pa = P $ \ts -> case pf ts of
    Left e -> Left e
    Right (f, r) -> case pa r of
      Left e -> Left e
      Right (a, r') -> Right (f a, r')

instance Monad P where
  P p >>= f = P $ \ts -> case p ts of
    Left e -> Left e
    Right (a, r) -> runP (f a) r

failP :: String -> P a
failP msg = P $ \_ -> Left (ParseError msg)

peek :: P (Maybe Token)
peek = P $ \ts -> Right (case ts of [] -> Nothing; t : _ -> Just t, ts)

advance :: P ()
advance = P $ \ts -> Right ((), drop 1 ts)

expect :: String -> P ()
expect s = do
  t <- peek
  if t == Just (TSym s) then advance else failP ("expected " ++ show s)

-- | One left-associative precedence level.
level :: [(String, BinOp)] -> P Expr -> P Expr
level ops next = next >>= loop
  where
    loop l = do
      t <- peek
      case t of
        Just (TSym s) | Just op <- lookup s ops -> do
          advance
          r <- next
          loop (EBinary op l r)
        _ -> pure l

pExpr :: P Expr
pExpr = level [("=", Eq), ("<>", Ne), ("<", Lt), (">", Gt), ("<=", Le), (">=", Ge)] pCat

pCat, pAdd, pMul, pUnary, pPrimary :: P Expr
pCat = level [("&", Concat)] pAdd
pAdd = level [("+", Add), ("-", Sub)] pMul
pMul = level [("*", Mul), ("/", Div)] pUnary

pUnary = do
  t <- peek
  case t of
    Just (TSym "-") -> advance >> ENeg <$> pUnary
    _ -> pPrimary

pPrimary = do
  t <- peek
  case t of
    Just (TNum d) -> advance >> pure (ENumber d)
    Just (TStr s) -> advance >> pure (EString s)
    Just (TRef s) -> advance >> pure (maybe EInvalidRef ERef (resolveRef s))
    Just (TSym "(") -> do
      advance
      e <- pExpr
      expect ")"
      pure e
    Just (TName "IF") -> do
      advance
      expect "("
      c <- pExpr
      expect ","
      a <- pExpr
      expect ","
      b <- pExpr
      expect ")"
      pure (EIf c a b)
    Just (TName n) | Just f <- lookup n aggregates -> do
      advance
      expect "("
      args <- pArgs
      expect ")"
      pure (ECall f args)
    Just tok -> failP ("unexpected " ++ show tok)
    Nothing -> failP "unexpected end of formula"

aggregates :: [(String, AggFn)]
aggregates = [("SUM", Sum), ("MIN", Min), ("MAX", Max), ("AVG", Avg), ("COUNT", Count)]

pArgs :: P [Arg]
pArgs = do
  a <- pArg
  t <- peek
  case t of
    Just (TSym ",") -> advance >> (a :) <$> pArgs
    _ -> pure [a]

pArg :: P Arg
pArg = P $ \ts -> case ts of
  TRef a : TSym ":" : TRef b : rest ->
    Right
      ( case (resolveRef a, resolveRef b) of
          (Just x, Just y) -> ArgRange x y
          _ -> ArgExpr EInvalidRef
      , rest
      )
  _ -> runP (ArgExpr <$> pExpr) ts
