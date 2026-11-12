-- | Helpers shared by the test modules.
module Support
  ( ws
  , runLog
  , buildLog
  , evalExpr
  ) where

import qualified Data.ByteString.Char8 as BC

import Kiln

-- | A workspace from (path, content) pairs.
ws :: [(String, String)] -> Workspace
ws kvs = fromFiles [(BC.pack p, BC.pack c) | (p, c) <- kvs]

-- | Run a session script against a workspace and return the log lines.
runLog :: [(String, String)] -> String -> [String]
runLog files session =
  lines . BC.unpack . fst $ runSession (ws files) (parseSession (BC.pack session))

-- | Run a single default @build@ of a @main.kiln@ plus extra files and
-- return the log lines without the header.
buildLog :: String -> [(String, String)] -> [String]
buildLog mainKiln extra = drop 1 (runLog (("main.kiln", mainKiln) : extra) "build")

-- | Evaluate a KBL expression by writing it to @out/x@. 'Left' is the
-- rendered error (@E_… detail@); 'Right' is the text written.
evalExpr :: String -> Either String String
evalExpr e =
  case [drop 8 l | l <- lines (BC.unpack logText), take 8 l == "  error "] of
    (err : _) -> Left err
    [] -> Right (maybe "" (BC.unpack . fileContent) (lookupFile "out/x" final))
  where
    prog = "step {\n out \"out/x\"\n cmd write(" ++ e ++ ")\n}\ndefault \"out/x\"\n"
    (logText, final) = runSession (ws [("main.kiln", prog)]) [SBuild [] 1]
