module Main (main) where

import Options.Applicative
import System.Directory (makeAbsolute, getCurrentDirectory, createDirectoryIfMissing,
                         listDirectory, doesDirectoryExist, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)

import Guild.Types (TeamSpec(..), ProjectConfig(..))
import Guild.Parser (parseTeamSpec)
import Guild.Resolver (resolveAgents)
import Guild.Generator (generateProject)
import Guild.Runtime.Machine (PipelineResult(..), runPipeline, runPipelineFrom,
                               readCheckpoint, CheckpointState(..))
import Guild.Runtime.Beads (primeContext, extractKnowledge)

-- ---------------------------------------------------------------------------
-- CLI definition
-- ---------------------------------------------------------------------------

data Command
  = Init FilePath (Maybe FilePath)
  | Validate FilePath
  | Run FilePath (Maybe FilePath)   -- spec, optional resume run-dir
  | Resume FilePath FilePath        -- spec, run-dir to resume
  | RunsList
  deriving (Show)

parseCommand :: Parser Command
parseCommand = subparser
  ( command "init"   (info initOpts   (progDesc "Initialize project from a team spec"))
 <> command "validate" (info validateOpts (progDesc "Validate a team spec"))
 <> command "run"    (info runOpts    (progDesc "Execute a pipeline from a team spec"))
 <> command "resume" (info resumeOpts (progDesc "Resume a paused pipeline run"))
 <> command "runs"   (info runsOpts   (progDesc "Manage pipeline runs"))
  )

initOpts :: Parser Command
initOpts = Init
  <$> argument str
      ( metavar "SPEC"
     <> help "Path to team.toml spec file"
      )
  <*> optional (strOption
      ( long "output"
     <> short 'o'
     <> metavar "DIR"
     <> help "Output directory (default: current directory)"
      ))

validateOpts :: Parser Command
validateOpts = Validate
  <$> argument str
      ( metavar "SPEC"
     <> help "Path to team.toml spec file"
      )

runOpts :: Parser Command
runOpts = Run
  <$> argument str
      ( metavar "SPEC"
     <> help "Path to team.toml spec file"
      )
  <*> optional (strOption
      ( long "resume"
     <> metavar "RUN_DIR"
     <> help "Resume a paused run from the given run directory"
      ))

resumeOpts :: Parser Command
resumeOpts = Resume
  <$> argument str
      ( metavar "SPEC"
     <> help "Path to team.toml spec file"
      )
  <*> argument str
      ( metavar "RUN_DIR"
     <> help "Path to the paused run directory"
      )

runsOpts :: Parser Command
runsOpts = subparser
  ( command "list" (info (pure RunsList) (progDesc "List all pipeline runs"))
  )

opts :: ParserInfo Command
opts = info (parseCommand <**> helper)
  ( fullDesc
  <> progDesc "Guild — agent team orchestration framework"
  <> header "guild — scaffold and manage agent team projects"
  )

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  cmd <- execParser opts
  case cmd of
    Init specPath mOutput    -> runInit specPath mOutput
    Validate specPath        -> runValidate specPath
    Run specPath Nothing     -> runRun specPath
    Run specPath (Just rdir) -> doResume specPath rdir
    Resume specPath runDir   -> doResume specPath runDir
    RunsList                 -> runRunsList

-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------

runInit :: FilePath -> Maybe FilePath -> IO ()
runInit specPath mOutput = do
  absSpec <- makeAbsolute specPath
  let specDir = takeDirectory absSpec

  outputDir <- case mOutput of
    Just d  -> makeAbsolute d
    Nothing -> getCurrentDirectory

  createDirectoryIfMissing True outputDir

  putStrLn $ "Parsing " ++ absSpec ++ " ..."
  result <- parseTeamSpec absSpec
  case result of
    Left err -> do
      putStrLn "Error parsing team spec:"
      putStrLn err
    Right spec -> do
      putStrLn $ "Resolving agents from " ++ tsAgentsDir spec ++ " ..."
      agentResult <- resolveAgents specDir (tsAgentsDir spec) (tsPhases spec)
      case agentResult of
        Left err -> do
          putStrLn "Error resolving agents:"
          putStrLn err
        Right agents -> do
          putStrLn $ "Resolved " ++ show (length agents) ++ " agents."
          putStrLn $ "Generating project in " ++ outputDir ++ " ..."
          generateProject absSpec spec agents outputDir
          putStrLn "Done. Generated:"
          putStrLn "  CLAUDE.md"
          putStrLn "  .claude/commands/          (slash commands)"
          putStrLn "  .claude/plugins/guild/     (agent skills)"
          putStrLn "  .beads/                    (knowledge system)"
          putStrLn "  .agentic/team.toml         (spec copy)"
          case tsBuild spec of
            Just _  -> putStrLn "  .coverage-thresholds.json"
            Nothing -> pure ()

-- ---------------------------------------------------------------------------
-- validate
-- ---------------------------------------------------------------------------

runValidate :: FilePath -> IO ()
runValidate specPath = do
  absSpec <- makeAbsolute specPath
  let specDir = takeDirectory absSpec

  putStrLn $ "Validating " ++ absSpec ++ " ..."
  result <- parseTeamSpec absSpec
  case result of
    Left err -> do
      putStrLn "INVALID — parse error:"
      putStrLn err
    Right spec -> do
      agentResult <- resolveAgents specDir (tsAgentsDir spec) (tsPhases spec)
      case agentResult of
        Left err -> do
          putStrLn "INVALID — agent resolution error:"
          putStrLn err
        Right agents -> do
          putStrLn "VALID"
          putStrLn ""
          putStrLn $ "  Project:    " ++ show (pcName (tsProject spec))
          putStrLn $ "  Agents dir: " ++ tsAgentsDir spec
          putStrLn $ "  Phases:     " ++ show (length (tsPhases spec))
          putStrLn $ "  Agents:     " ++ show (length agents)
          putStrLn $ "  Gates:      " ++ show (length (tsGates spec))
          putStrLn $ "  Checkpoints:" ++ show (length (tsCheckpoints spec))

-- ---------------------------------------------------------------------------
-- run (fresh start)
-- ---------------------------------------------------------------------------

runRun :: FilePath -> IO ()
runRun specPath = do
  absSpec <- makeAbsolute specPath

  putStrLn $ "Parsing " ++ absSpec ++ " ..."
  result <- parseTeamSpec absSpec
  case result of
    Left err -> do
      putStrLn "Error parsing team spec:"
      putStrLn err
    Right spec -> do
      runId <- toString <$> nextRandom
      now   <- getCurrentTime
      let timestamp = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now

      cwd <- getCurrentDirectory
      let runsBase = cwd </> ".agentic" </> "runs"
          runDir   = runsBase </> runId
      createDirectoryIfMissing True runDir

      putStrLn $ "Run ID:      " ++ runId
      putStrLn $ "Started:     " ++ timestamp
      putStrLn $ "Run dir:     " ++ runDir
      putStrLn $ "Phases:      " ++ show (length (tsPhases spec))
      putStrLn $ "Checkpoints: " ++ show (length (tsCheckpoints spec))
      putStrLn ""

      beads <- primeContext cwd
      putStrLn "[beads] Knowledge context primed."

      result' <- runPipeline spec runDir beads
      handleResult cwd timestamp spec result'

-- ---------------------------------------------------------------------------
-- resume (from checkpoint)
-- ---------------------------------------------------------------------------

doResume :: FilePath -> FilePath -> IO ()
doResume specPath runDir = do
  absSpec  <- makeAbsolute specPath
  absRunDir <- makeAbsolute runDir

  -- Verify checkpoint exists
  let cpFile = absRunDir ++ "/checkpoint.state"
  exists <- doesFileExist cpFile
  if not exists
    then putStrLn $ "No checkpoint found in: " ++ absRunDir
    else do
      cpResult <- readCheckpoint absRunDir
      case cpResult of
        Left err -> putStrLn $ "Error reading checkpoint: " ++ err
        Right cs -> do
          putStrLn $ "Resuming run:    " ++ absRunDir
          putStrLn $ "Paused after:    " ++ show (csPausedAfter cs)
          putStrLn $ "Resuming from:   phase index " ++ show (csNextIdx cs)
          putStrLn $ "Checkpoint desc: " ++ show (csDescription cs)
          putStrLn ""

          -- Parse the spec
          result <- parseTeamSpec absSpec
          case result of
            Left err -> do
              putStrLn "Error parsing team spec:"
              putStrLn err
            Right spec -> do
              now <- getCurrentTime
              let timestamp = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
              cwd <- getCurrentDirectory

              beads <- primeContext cwd
              putStrLn "[beads] Knowledge context primed."

              pResult <- runPipelineFrom spec absRunDir beads (csNextIdx cs)
              handleResult cwd timestamp spec pResult

-- ---------------------------------------------------------------------------
-- Shared result handler
-- ---------------------------------------------------------------------------

handleResult :: FilePath -> String -> TeamSpec -> PipelineResult -> IO ()
handleResult cwd timestamp _spec (Completed output) = do
  extractKnowledge cwd output timestamp
  putStrLn ""
  putStrLn "Pipeline complete. ✓"

handleResult _cwd _timestamp _spec (Paused runDir pausedAfter _nextIdx desc _output) = do
  putStrLn ""
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  putStrLn "  ⏸  Pipeline paused at human checkpoint"
  putStrLn $ "  After phase:   " ++ show pausedAfter
  putStrLn $ "  Description:   " ++ show desc
  putStrLn $ "  Run dir:       " ++ runDir
  putStrLn ""
  putStrLn "  Review the output above, then resume with:"
  putStrLn $ "    guild resume <spec.toml> " ++ runDir
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

-- ---------------------------------------------------------------------------
-- runs list
-- ---------------------------------------------------------------------------

runRunsList :: IO ()
runRunsList = do
  cwd <- getCurrentDirectory
  let runsBase = cwd </> ".agentic" </> "runs"
  exists <- doesDirectoryExist runsBase
  if not exists
    then putStrLn "No runs found. (.agentic/runs/ does not exist)"
    else do
      dirs <- listDirectory runsBase
      if null dirs
        then putStrLn "No runs found."
        else do
          putStrLn "Pipeline runs:"
          mapM_ (showRun runsBase) dirs

showRun :: FilePath -> FilePath -> IO ()
showRun runsBase runId = do
  let runDir = runsBase </> runId
      cpFile = runDir ++ "/checkpoint.state"
  cpExists <- doesFileExist cpFile
  if cpExists
    then do
      cpResult <- readCheckpoint runDir
      case cpResult of
        Right cs -> putStrLn $ "  " ++ runId ++ "  [PAUSED after '" ++ show (csPausedAfter cs) ++ "']"
        Left  _  -> putStrLn $ "  " ++ runId ++ "  [PAUSED — unreadable checkpoint]"
    else
      putStrLn $ "  " ++ runId ++ "  [COMPLETE]"
