{-# LANGUAGE OverloadedStrings #-}

module Guild.Runtime.Machine
  ( runPipeline
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)

import Guild.Types (TeamSpec(..), Phase(..))
import Guild.Runtime.SlotStore (SlotStore, openSlotStore, pushSlot, pullSlot)

-- | Run a sequential pipeline: for each phase, invoke the agent via claude CLI,
-- collect stdout, and push it to the slot store under the phase name.
runPipeline :: TeamSpec -> FilePath -> IO ()
runPipeline spec runDir = do
  let dbPath = runDir ++ "/slots.db"
  store <- openSlotStore dbPath
  mapM_ (runPhase store (tsPhases spec)) (tsPhases spec)

-- | Execute a single phase.
runPhase :: SlotStore -> [Phase] -> Phase -> IO ()
runPhase store allPhases phase = do
  let name = phName phase
  putStrLn $ "[guild] Running phase: " ++ T.unpack name

  -- Build context from upstream phases (all phases before this one)
  context <- gatherContext store allPhases phase

  -- Build the prompt: phase name + upstream context
  let prompt = buildPrompt name context

  -- Get the agent name
  let agent = maybe name id (phAgent phase)

  putStrLn $ "[guild]   Agent: " ++ T.unpack agent
  putStrLn $ "[guild]   Invoking claude..."

  -- Invoke claude CLI
  (exitCode, stdout, stderr) <- readProcessWithExitCode
    "claude"
    ["--dangerously-skip-permissions", "-p", T.unpack prompt]
    ""

  case exitCode of
    ExitSuccess -> do
      let output = T.pack stdout
      pushSlot store name name output
      putStrLn $ "[guild]   Phase " ++ T.unpack name ++ " completed. Output: "
                 ++ show (T.length output) ++ " chars."
    ExitFailure code -> do
      let err = T.pack stderr
      pushSlot store name name ("[FAILED] " <> err)
      putStrLn $ "[guild]   Phase " ++ T.unpack name
                 ++ " FAILED (exit " ++ show code ++ "): "
                 ++ T.unpack (T.take 200 err)

-- | Gather context from all upstream phases (those appearing before this phase).
gatherContext :: SlotStore -> [Phase] -> Phase -> IO Text
gatherContext store allPhases currentPhase = do
  let upstream = takeWhile (\p -> phName p /= phName currentPhase) allPhases
  parts <- mapM (pullUpstream store) upstream
  pure (T.intercalate "\n\n" (filter (not . T.null) parts))

-- | Pull output from an upstream phase's slot.
pullUpstream :: SlotStore -> Phase -> IO Text
pullUpstream store phase = do
  let name = phName phase
  mVal <- pullSlot store name name
  pure $ case mVal of
    Just v  -> "## Context from " <> name <> "\n\n" <> v
    Nothing -> ""

-- | Build the prompt for a phase invocation.
buildPrompt :: Text -> Text -> Text
buildPrompt phaseName context
  | T.null context = "You are executing the '" <> phaseName <> "' phase."
  | otherwise      = "You are executing the '" <> phaseName <> "' phase.\n\n"
                     <> "Here is context from prior phases:\n\n" <> context
