{-# LANGUAGE OverloadedStrings #-}

module Guild.Runtime.Machine
  ( PipelineResult(..)
  , runPipeline
  , runPipelineFrom
  , readCheckpoint
  , CheckpointState(..)
  ) where

import Control.Concurrent.Async (mapConcurrently)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

import Guild.Types (TeamSpec(..), Phase(..), Gate(..), Checkpoint(..))
import Guild.Runtime.SlotStore (SlotStore, openSlotStore, pushSlot, pullSlot)
import Guild.Runtime.Beads (BeadsContext(..))
import Guild.Runtime.Gate (evaluateGates)

-- ---------------------------------------------------------------------------
-- Result type
-- ---------------------------------------------------------------------------

data PipelineResult
  = Completed Text
    -- ^ All phases ran successfully; carries accumulated output.
  | GateFailed Text Text
    -- ^ Pipeline halted because a gate failed. Carries (phase name, error message).
  | Paused
      { prRunDir      :: FilePath
      , prPausedAfter :: Text     -- ^ phase name we paused after
      , prNextIdx     :: Int      -- ^ 0-based index of the NEXT phase to run
      , prDescription :: Text     -- ^ human-readable checkpoint description
      , prOutput      :: Text     -- ^ accumulated output so far
      }
    -- ^ Pipeline hit a human checkpoint; state persisted for resume.
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Checkpoint persistence
-- ---------------------------------------------------------------------------

data CheckpointState = CheckpointState
  { csRunDir      :: FilePath
  , csPausedAfter :: Text
  , csNextIdx     :: Int
  , csDescription :: Text
  } deriving (Show)

checkpointFile :: FilePath -> FilePath
checkpointFile runDir = runDir ++ "/checkpoint.state"

writeCheckpoint :: FilePath -> Text -> Int -> Text -> IO ()
writeCheckpoint runDir pausedAfter nextIdx description =
  TIO.writeFile (checkpointFile runDir)
    $  "pausedAfter=" <> pausedAfter  <> "\n"
    <> "nextIdx="     <> T.pack (show nextIdx) <> "\n"
    <> "description=" <> T.filter (/= '\n') description <> "\n"

readCheckpoint :: FilePath -> IO (Either String CheckpointState)
readCheckpoint runDir = do
  let path = checkpointFile runDir
  contents <- TIO.readFile path
  let pairs = parsePairs (T.lines contents)
  case (lookup "pausedAfter" pairs, lookup "nextIdx" pairs, lookup "description" pairs) of
    (Just pa, Just ni, Just desc) ->
      case reads (T.unpack ni) of
        [(n, "")] -> Right <$> pure CheckpointState
          { csRunDir      = runDir
          , csPausedAfter = pa
          , csNextIdx     = n
          , csDescription = desc
          }
        _ -> pure $ Left $ "Could not parse nextIdx: " ++ T.unpack ni
    _ -> pure $ Left "Malformed checkpoint.state — missing required keys"

parsePairs :: [Text] -> [(Text, Text)]
parsePairs = concatMap parseLine
  where
    parseLine line =
      let (k, rest) = T.break (== '=') line
      in if T.null rest then [] else [(T.strip k, T.drop 1 rest)]

-- ---------------------------------------------------------------------------
-- Pipeline execution
-- ---------------------------------------------------------------------------

-- | Run a full pipeline from the beginning.
-- agentsBaseDir: absolute path to the agents directory (for loading SOUL.md).
runPipeline :: TeamSpec -> FilePath -> BeadsContext -> FilePath -> IO PipelineResult
runPipeline spec runDir beads agentsBaseDir = runPipelineFrom spec runDir beads agentsBaseDir 0

-- | Run a pipeline starting at the given 0-based phase index (for resume).
runPipelineFrom :: TeamSpec -> FilePath -> BeadsContext -> FilePath -> Int -> IO PipelineResult
runPipelineFrom spec runDir beads agentsBaseDir startIdx = do
  let dbPath = runDir ++ "/slots.db"
  store <- openSlotStore dbPath
  let allPhases = tsPhases spec
      toRun     = drop startIdx allPhases
      checkpts  = tsCheckpoints spec
      allGates  = tsGates spec
  go store allPhases toRun checkpts allGates startIdx T.empty
  where
    go _store _phases []           _checkpts _gates _idx acc = pure (Completed acc)
    go  store  phases (phase:rest)  checkpts  gates  idx  acc = do

      -- Run phase (single-agent or parallel multi-agent)
      output <- runPhase store phases beads agentsBaseDir phase

      let acc' = if T.null acc then output else acc <> "\n\n" <> output

      -- Evaluate any gates declared on this phase
      gateResult <- evaluateGates gates (phGates phase) output
      case gateResult of
        Just errMsg -> do
          let phaseName = phName phase
          putStrLn $ "[guild] ⛔ Gate check failed after phase '"
                  ++ T.unpack phaseName ++ "': " ++ T.unpack errMsg
          pure (GateFailed phaseName errMsg)
        Nothing -> do
          -- Check whether a human checkpoint fires after this phase
          case findCheckpoint checkpts (phName phase) of
            Just cp | not (null rest) -> do
              let nextIdx = idx + 1
              writeCheckpoint runDir (phName phase) nextIdx (cpDescription cp)
              pure Paused
                { prRunDir      = runDir
                , prPausedAfter = phName phase
                , prNextIdx     = nextIdx
                , prDescription = cpDescription cp
                , prOutput      = acc'
                }
            _ ->
              go store phases rest checkpts gates (idx + 1) acc'

findCheckpoint :: [Checkpoint] -> Text -> Maybe Checkpoint
findCheckpoint cps phaseName = find ((== phaseName) . cpAfter) cps

-- ---------------------------------------------------------------------------
-- Phase dispatch: single-agent vs parallel multi-agent
-- ---------------------------------------------------------------------------

-- | Execute a phase. Dispatches to parallel or single-agent execution.
runPhase :: SlotStore -> [Phase] -> BeadsContext -> FilePath -> Phase -> IO Text
runPhase store allPhases beads agentsDir phase =
  case phAgents phase of
    Just agentList -> runParallelPhase store allPhases beads agentsDir phase agentList
    Nothing        -> runSingleAgentPhase store allPhases beads agentsDir phase

-- ---------------------------------------------------------------------------
-- Parallel fan-out: run multiple agents concurrently, then aggregate
-- ---------------------------------------------------------------------------

-- | Run a multi-agent phase: fan out to all agents in parallel, fan in by aggregating.
runParallelPhase :: SlotStore -> [Phase] -> BeadsContext -> FilePath -> Phase -> [Text] -> IO Text
runParallelPhase store allPhases beads agentsDir phase agentList = do
  let name = phName phase
  putStrLn $ "[guild] Running parallel phase: " ++ T.unpack name
  putStrLn $ "[guild]   Agents (" ++ show (length agentList) ++ "): "
          ++ T.unpack (T.intercalate ", " agentList)

  context <- gatherContext store allPhases phase
  let prompt = buildPrompt name (beadsText beads) context

  -- Fan out: run all agents concurrently, each with their own SOUL.md + model
  results <- mapConcurrently (\agent -> do
    mSoul  <- loadSoulMd agentsDir agent
    mModel <- loadAgentModel agentsDir agent
    runAgent agent prompt mSoul mModel
    ) agentList

  -- Store individual results per-agent slot
  let indexedResults = zip agentList results
  mapM_ (\(agent, output) -> do
    pushSlot store name agent output
    putStrLn $ "[guild]   Agent '" ++ T.unpack agent ++ "' complete ("
            ++ show (T.length output) ++ " chars)."
    ) indexedResults

  -- Fan in: aggregate results
  let combined = aggregateResults (phRequire phase) indexedResults
  pushSlot store name name combined

  putStrLn $ "[guild] Parallel phase '" ++ T.unpack name ++ "' complete ("
          ++ show (length agentList) ++ " agents)."
  pure combined

-- | Aggregate multiple agent outputs into a single combined output.
aggregateResults :: Maybe Text -> [(Text, Text)] -> Text
aggregateResults mRequire results =
  let header = case mRequire of
        Just req -> "## Parallel Review Results (require: " <> req <> ")\n\n"
        Nothing  -> "## Parallel Results\n\n"
      sections = map (\(agent, output) ->
        "### " <> agent <> "\n\n" <> output
        ) results
  in header <> T.intercalate "\n\n---\n\n" sections

-- ---------------------------------------------------------------------------
-- Single-agent phase execution
-- ---------------------------------------------------------------------------

-- | Execute a single-agent phase, returning its output text.
runSingleAgentPhase :: SlotStore -> [Phase] -> BeadsContext -> FilePath -> Phase -> IO Text
runSingleAgentPhase store allPhases beads agentsDir phase = do
  let name  = phName phase
      agent = fromMaybe name (phAgent phase)

  putStrLn $ "[guild] Running phase: " ++ T.unpack name
  putStrLn $ "[guild]   Agent: " ++ T.unpack agent

  context <- gatherContext store allPhases phase
  let prompt = buildPrompt name (beadsText beads) context

  mSoul  <- loadSoulMd agentsDir agent
  mModel <- loadAgentModel agentsDir agent
  output <- runAgent agent prompt mSoul mModel
  pushSlot store name name output
  putStrLn $ "[guild]   Phase '" ++ T.unpack name ++ "' complete ("
          ++ show (T.length output) ++ " chars)."
  pure output

-- ---------------------------------------------------------------------------
-- Agent invocation (shared by single and parallel)
-- ---------------------------------------------------------------------------

-- | Load an agent's SOUL.md system prompt, if present.
loadSoulMd :: FilePath -> Text -> IO (Maybe Text)
loadSoulMd agentsDir agentName = do
  let soulPath = agentsDir </> T.unpack agentName </> "SOUL.md"
  exists <- doesFileExist soulPath
  if exists
    then Just <$> TIO.readFile soulPath
    else pure Nothing

-- | Invoke claude with a task prompt, optional system prompt (SOUL.md), and optional model.
-- When SOUL.md is present, it becomes the system prompt (agent persona).
-- When model is specified (from config.yaml), it overrides the default.
runAgent :: Text -> Text -> Maybe Text -> Maybe Text -> IO Text
runAgent _agentName prompt mSoulMd mModel = do
  let baseArgs = ["--dangerously-skip-permissions", "-p", T.unpack prompt]
      withSoul = case mSoulMd of
        Just soul -> baseArgs ++ ["--system-prompt", T.unpack soul]
        Nothing   -> baseArgs
      withModel = case mModel of
        Just model -> withSoul ++ ["--model", T.unpack model]
        Nothing    -> withSoul
  (exitCode, stdout, stderr) <- readProcessWithExitCode "claude" withModel ""
  case exitCode of
    ExitSuccess ->
      pure (T.pack stdout)
    ExitFailure code ->
      pure ("[FAILED exit=" <> T.pack (show code) <> "] " <> T.pack stderr)

-- ---------------------------------------------------------------------------
-- Context gathering and prompt building
-- ---------------------------------------------------------------------------

-- | Gather output from all phases that precede this one in the pipeline.
gatherContext :: SlotStore -> [Phase] -> Phase -> IO Text
gatherContext store allPhases currentPhase = do
  let upstream = takeWhile (\p -> phName p /= phName currentPhase) allPhases
  parts <- mapM (pullUpstream store) upstream
  pure (T.intercalate "\n\n" (filter (not . T.null) parts))

pullUpstream :: SlotStore -> Phase -> IO Text
pullUpstream store phase = do
  let name = phName phase
  mVal <- pullSlot store name name
  pure $ case mVal of
    Just v  -> "## Context from " <> name <> "\n\n" <> v
    Nothing -> T.empty

buildPrompt :: Text -> Text -> Text -> Text
buildPrompt phaseName beadsKnowledge contextText =
  T.intercalate "\n\n"
    $ filter (not . T.null)
    [ if T.null beadsKnowledge then T.empty
      else "## Prior Knowledge\n\n" <> beadsKnowledge
    , if T.null contextText then T.empty
      else "## Context from upstream phases\n\n" <> contextText
    , "## Task: " <> phaseName
    ]

-- ---------------------------------------------------------------------------
-- Agent config loading
-- ---------------------------------------------------------------------------

-- | Load model name from agent's config.yaml (if present).
-- Looks for a line containing "model:" and extracts the value.
-- Returns Nothing if config.yaml doesn't exist or model is not specified.
loadAgentModel :: FilePath -> Text -> IO (Maybe Text)
loadAgentModel agentsDir agentName = do
  let configPath = agentsDir </> T.unpack agentName </> "config.yaml"
  exists <- doesFileExist configPath
  if not exists
    then pure Nothing
    else do
      contents <- TIO.readFile configPath
      pure (extractModelField (T.lines contents))

-- | Extract the model value from YAML lines.
-- Handles: "model: claude-opus-4-20250514" or "  model: sonnet"
extractModelField :: [Text] -> Maybe Text
extractModelField [] = Nothing
extractModelField (line:rest)
  | "model:" `T.isInfixOf` line =
      let val = T.strip (T.dropWhile (/= ':') line)
          stripped = T.strip (T.drop 1 val)
      in if T.null stripped then Nothing else Just stripped
  | otherwise = extractModelField rest
