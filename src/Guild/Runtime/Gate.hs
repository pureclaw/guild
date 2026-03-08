{-# LANGUAGE OverloadedStrings #-}

module Guild.Runtime.Gate
  ( GateResult(..)
  , evaluateGate
  , evaluateGates
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

-- | Evaluate a gate against the output of the preceding phase.
-- The phaseOutput is available to llm_judge gates; shell gates ignore it.
evaluateGate :: Gate -> Text -> IO GateResult
evaluateGate gate phaseOutput = case gType gate of
  "shell"     -> case gCommand gate of
                    Nothing  -> pure (GateFail "Shell gate has no command")
                    Just cmd -> evaluateShellGate cmd
  "llm_judge" -> evaluateLlmJudgeGate (maybe "" id (gExpr gate)) phaseOutput
  "predicate" -> pure (GateFail "predicate gates are not yet implemented (need JSON eval)")
  other       -> pure (GateFail ("Unsupported gate type: " <> other))

-- | Evaluate a list of gates by name, looking them up in the global gate library.
-- Returns Nothing if all pass, or Just (gate name, error) on first failure.
evaluateGates :: [Gate] -> [Text] -> Text -> IO (Maybe Text)
evaluateGates _allGates [] _output = pure Nothing
evaluateGates allGates (gateName:rest) output = do
  case lookupGate allGates gateName of
    Nothing ->
      pure (Just ("Gate not found in gate library: " <> gateName))
    Just gate -> do
      result <- evaluateGate gate output
      case result of
        GatePass    -> evaluateGates allGates rest output
        GateFail msg ->
          pure (Just ("Gate '" <> gateName <> "' failed: " <> msg))

-- ---------------------------------------------------------------------------
-- Shell gate
-- ---------------------------------------------------------------------------

-- | Run a shell command; exit 0 = pass, anything else = fail with stderr.
evaluateShellGate :: Text -> IO GateResult
evaluateShellGate cmd = do
  (exitCode, _stdout, stderr) <- readProcessWithExitCode
    "/bin/sh" ["-c", T.unpack cmd] ""
  pure $ case exitCode of
    ExitSuccess   -> GatePass
    ExitFailure _ -> GateFail (T.pack stderr)

-- ---------------------------------------------------------------------------
-- LLM judge gate
-- ---------------------------------------------------------------------------

-- | Ask Claude to evaluate output against a rubric.
-- The rubric is in gExpr. Claude must respond with PASS or FAIL on the first line.
evaluateLlmJudgeGate :: Text -> Text -> IO GateResult
evaluateLlmJudgeGate rubric phaseOutput = do
  let prompt = T.intercalate "\n\n"
        [ "You are a quality evaluator for an AI agent pipeline."
        , "## Rubric"
        , rubric
        , "## Output to evaluate"
        , phaseOutput
        , "Respond with exactly one word on the first line: PASS or FAIL."
        , "Then provide your reasoning on subsequent lines."
        ]
  (exitCode, stdout, stderr) <- readProcessWithExitCode
    "claude"
    ["--dangerously-skip-permissions", "-p", T.unpack prompt]
    ""
  case exitCode of
    ExitFailure code ->
      pure (GateFail ("llm_judge: claude exited " <> T.pack (show code) <> ": " <> T.pack stderr))
    ExitSuccess -> do
      let response = T.strip (T.pack stdout)
      case T.lines response of
        [] -> pure (GateFail "llm_judge: empty response from claude")
        (l:_) -> do
          let firstLine = T.toUpper (T.strip l)
          case firstLine of
            "PASS" -> pure GatePass
            "FAIL" -> do
              let reason = T.unlines (drop 1 (T.lines response))
              pure (GateFail ("LLM judge failed: " <> T.strip reason))
            other  ->
              -- Be lenient: if response starts with PASS/FAIL, use that
              if "PASS" `T.isPrefixOf` other
                then pure GatePass
                else if "FAIL" `T.isPrefixOf` other
                  then pure (GateFail ("LLM judge: " <> response))
                  else pure (GateFail ("llm_judge: unexpected response (expected PASS/FAIL): " <> T.take 100 response))

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

lookupGate :: [Gate] -> Text -> Maybe Gate
lookupGate gates name = case filter (\g -> gName g == name) gates of
  (g:_) -> Just g
  []    -> Nothing
