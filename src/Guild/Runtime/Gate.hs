{-# LANGUAGE OverloadedStrings #-}

module Guild.Runtime.Gate
  ( GateResult(..)
  , evaluateGate
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)

import Guild.Types (Gate(..))

-- | Result of evaluating a gate.
data GateResult
  = GatePass
  | GateFail Text
  deriving (Show, Eq)

-- | Evaluate a gate spec. Currently supports shell gates only.
evaluateGate :: Gate -> IO GateResult
evaluateGate gate = case gType gate of
  "shell" -> case gCommand gate of
    Nothing  -> pure (GateFail "Shell gate has no command")
    Just cmd -> evaluateShellGate cmd
  other -> pure (GateFail ("Unsupported gate type: " <> other))

-- | Run a shell command; exit 0 = pass, anything else = fail with stderr.
evaluateShellGate :: Text -> IO GateResult
evaluateShellGate cmd = do
  (exitCode, _stdout, stderr) <- readProcessWithExitCode
    "/bin/sh" ["-c", T.unpack cmd] ""
  pure $ case exitCode of
    ExitSuccess   -> GatePass
    ExitFailure _ -> GateFail (T.pack stderr)
