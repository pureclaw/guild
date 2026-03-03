{-# LANGUAGE OverloadedStrings #-}

module Guild.Runtime.Machine
  ( PipelineResult(..)
  , runPipeline
  , runPipelineFrom
  , readCheckpoint
  , CheckpointState(..)
  ) where

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)

import Guild.Types (TeamSpec(..), Phase(..), Checkpoint(..))
import Guild.Runtime.SlotStore (SlotStore, openSlotStore, pushSlot, pullSlot)
import Guild.Runtime.Beads (BeadsContext(..))

-- ---------------------------------------------------------------------------
-- Result type
-- ---------------------------------------------------------------------------

data PipelineResult
  = Completed Text
    -- ^ All phases ran successfully; carries accumulated output.
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
runPipeline :: TeamSpec -> FilePath -> BeadsContext -> IO PipelineResult
runPipeline spec runDir beads = runPipelineFrom spec runDir beads 0

-- | Run a pipeline starting at the given 0-based phase index (for resume).
runPipelineFrom :: TeamSpec -> FilePath -> BeadsContext -> Int -> IO PipelineResult
runPipelineFrom spec runDir beads startIdx = do
  let dbPath = runDir ++ "/slots.db"
  store <- openSlotStore dbPath
  let allPhases = tsPhases spec
      toRun     = drop startIdx allPhases
      checkpts  = tsCheckpoints spec
  go store allPhases toRun checkpts startIdx T.empty

  where
    go _store _all []             _checkpts _idx acc = pure (Completed acc)
    go  store  all (phase:rest) checkpts  idx  acc = do
      output <- runPhase store all beads phase
      let acc' = if T.null acc then output else acc <> "\n\n" <> output

      -- Check whether a human checkpoint fires after this phase
      case findCheckpoint checkpts (phName phase) of
        Just cp | not (null rest) -> do
          -- Persist state and return Paused
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
          -- No checkpoint (or last phase) — continue
          go store all rest checkpts (idx + 1) acc'

findCheckpoint :: [Checkpoint] -> Text -> Maybe Checkpoint
findCheckpoint cps phaseName = find ((== phaseName) . cpAfter) cps

-- ---------------------------------------------------------------------------
-- Phase execution (unchanged from before)
-- ---------------------------------------------------------------------------

-- | Execute a single phase, returning its output text.
runPhase :: SlotStore -> [Phase] -> BeadsContext -> Phase -> IO Text
runPhase store allPhases beads phase = do
  let name = phName phase

  putStrLn $ "[guild] Running phase: " ++ T.unpack name

  context <- gatherContext store allPhases phase
  let prompt = buildPrompt name (beadsText beads) context
  let agent  = maybe name id (phAgent phase)

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
      let err       = T.pack stderr
          errOutput = "[FAILED] " <> err
      pushSlot store name name errOutput
      putStrLn $ "[guild]   Phase " ++ T.unpack name
                 ++ " FAILED (exit " ++ show code ++ "): "
                 ++ T.unpack (T.take 200 err)
      pure errOutput

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
    [ if T.null beadsKnowledge
        then T.empty
        else "## Prior Knowledge\n\n" <> beadsKnowledge
    , if T.null contextText
        then T.empty
        else "## Context from upstream phases\n\n" <> contextText
    , "## Task: " <> phaseName
    ]
