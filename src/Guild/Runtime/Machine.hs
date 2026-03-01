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
import Guild.Runtime.Beads (BeadsContext(..))

-- | Run a sequential pipeline: for each phase, invoke the agent via claude CLI,
-- collect stdout, push it to the slot store, and accumulate a run history.
--
-- Returns the concatenated output of all phases (for beads knowledge extraction).
-- 'beads' is the primed knowledge context injected into every phase prompt.
runPipeline :: TeamSpec -> FilePath -> BeadsContext -> IO Text
runPipeline spec runDir beads = do
  let dbPath = runDir ++ "/slots.db"
  store <- openSlotStore dbPath
  outputs <- mapM (runPhase store (tsPhases spec) beads) (tsPhases spec)
  pure (T.intercalate "\n\n" outputs)

-- | Execute a single phase, returning its output text.
runPhase :: SlotStore -> [Phase] -> BeadsContext -> Phase -> IO Text
runPhase store allPhases beads phase = do
  let name = phName phase
  putStrLn $ "[guild] Running phase: " ++ T.unpack name

  context <- gatherContext store allPhases phase
  let prompt = buildPrompt name (beadsText beads) context
  let agent = maybe name id (phAgent phase)

  putStrLn $ "[guild]   Agent: " ++ T.unpack agent
  putStrLn $ "[guild]   Invoking claude..."

  (exitCode, stdout, stderr) <- readProcessWithExitCode
    "claude"
    ["--dangerously-skip-permissions", "-p", T.unpack prompt]
    ""

  case exitCode of
    ExitSuccess -> do
      let output = T.pack stdout
      pushSlot store name name output
      putStrLn $ "[guild]   Phase " ++ T.unpack name ++ " completed ("
                 ++ show (T.length output) ++ " chars)."
      pure output
    ExitFailure code -> do
      let err = T.pack stderr
      let errOutput = "[FAILED] " <> err
      pushSlot store name name errOutput
      putStrLn $ "[guild]   Phase " ++ T.unpack name
                 ++ " FAILED (exit " ++ show code ++ "): "
                 ++ T.unpack (T.take 200 err)
      pure errOutput

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

-- | Build the prompt for a phase invocation, prepending beads knowledge if present.
buildPrompt :: Text   -- ^ Phase name
            -> Text   -- ^ Beads knowledge context (empty if none)
            -> Text   -- ^ Upstream phase context
            -> Text
buildPrompt phaseName beads upstream =
  let beadsSection
        | T.null beads = T.empty
        | otherwise    = beads <> "\n"
      upstreamSection
        | T.null upstream = T.empty
        | otherwise       = "Here is context from prior phases:\n\n" <> upstream <> "\n\n"
  in beadsSection
     <> upstreamSection
     <> "You are executing the '" <> phaseName <> "' phase."
