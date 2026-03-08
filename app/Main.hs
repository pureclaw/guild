module Main (main) where

import Control.Monad (filterM)
import Data.List (sort)
import qualified Data.Text as T
import Options.Applicative
import System.Directory (makeAbsolute, getCurrentDirectory, createDirectoryIfMissing,
                         listDirectory, doesDirectoryExist, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)

import Guild.Types (TeamSpec(..), ProjectConfig(..), Phase(..))
import Guild.Parser (parseTeamSpec)
import Guild.Resolver (resolveAgents, expandTilde)
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
  | AgentsList FilePath             -- spec; list agents in agents_dir
  deriving (Show)

parseCommand :: Parser Command
parseCommand = subparser
  ( command "init"     (info initOpts     (progDesc "Initialize project from a team spec"))
 <> command "validate" (info validateOpts (progDesc "Validate a team spec"))
 <> command "run"      (info runOpts      (progDesc "Execute a pipeline from a team spec"))
 <> command "resume"   (info resumeOpts   (progDesc "Resume a paused pipeline run"))
 <> command "runs"     (info runsOpts     (progDesc "Manage pipeline runs"))
 <> command "agents"   (info agentsOpts   (progDesc "Manage agent library"))
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

agentsOpts :: Parser Command
agentsOpts = subparser
  ( command "list" (info agentsListOpts (progDesc "List available agents in the agents_dir"))
  )

agentsListOpts :: Parser Command
agentsListOpts = AgentsList
  <$> argument str
      ( metavar "SPEC"
     <> help "Path to team.toml spec (to locate agents_dir)"
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
    AgentsList specPath      -> runAgentsList specPath

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

      agentsBaseDir <- resolveAgentsDir cwd (tsAgentsDir spec)

      beads <- primeContext cwd
      putStrLn "[beads] Knowledge context primed."
      putStrLn $ "[guild] Agents dir: " ++ agentsBaseDir

      result' <- runPipeline spec runDir beads agentsBaseDir
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
          putStrLn $ "Paused after:    " ++ T.unpack (csPausedAfter cs)
          putStrLn $ "Resuming from:   phase index " ++ show (csNextIdx cs)
          putStrLn $ "Checkpoint desc: " ++ T.unpack (csDescription cs)
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

              agentsBaseDir <- resolveAgentsDir cwd (tsAgentsDir spec)

              beads <- primeContext cwd
              putStrLn "[beads] Knowledge context primed."

              pResult <- runPipelineFrom spec absRunDir beads agentsBaseDir (csNextIdx cs)
              handleResult cwd timestamp spec pResult

-- ---------------------------------------------------------------------------
-- Shared result handler
-- ---------------------------------------------------------------------------

handleResult :: FilePath -> String -> TeamSpec -> PipelineResult -> IO ()
handleResult cwd timestamp _spec (Completed output) = do
  extractKnowledge cwd output timestamp
  putStrLn ""
  putStrLn "Pipeline complete. ✓"

handleResult _cwd _timestamp _spec (GateFailed phaseName errMsg) = do
  putStrLn ""
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  putStrLn "  ⛔  Pipeline halted — gate check failed"
  putStrLn $ "  Phase:   " ++ T.unpack phaseName
  putStrLn $ "  Reason:  " ++ T.unpack errMsg
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

handleResult _cwd _timestamp _spec (Paused runDir pausedAfter _nextIdx desc _output) = do
  putStrLn ""
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  putStrLn "  ⏸  Pipeline paused at human checkpoint"
  putStrLn $ "  After phase:   " ++ T.unpack pausedAfter
  putStrLn $ "  Description:   " ++ T.unpack desc
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

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- | Resolve an agents_dir from a spec to an absolute path.
-- agents_dir is treated as relative to CWD if not absolute or ~-prefixed.
resolveAgentsDir :: FilePath -> FilePath -> IO FilePath
resolveAgentsDir cwd agentsDir = do
  expanded <- expandTilde agentsDir
  if isAbsolutePath expanded
    then pure expanded
    else pure (cwd </> expanded)

isAbsolutePath :: FilePath -> Bool
isAbsolutePath ('/':_) = True
isAbsolutePath _       = False

-- ---------------------------------------------------------------------------
-- agents list
-- ---------------------------------------------------------------------------

runAgentsList :: FilePath -> IO ()
runAgentsList specPath = do
  absSpec <- makeAbsolute specPath
  cwd     <- getCurrentDirectory

  result <- parseTeamSpec absSpec
  case result of
    Left err -> do
      putStrLn "Error parsing team spec:"
      putStrLn err
    Right spec -> do
      agentsDir <- resolveAgentsDir cwd (tsAgentsDir spec)
      exists <- doesDirectoryExist agentsDir
      if not exists
        then putStrLn $ "agents_dir not found: " ++ agentsDir
        else do
          entries <- listDirectory agentsDir
          agentDirs <- filterM (doesDirectoryExist . (agentsDir </>)) entries
          putStrLn $ "Agents in " ++ agentsDir ++ " (" ++ show (length agentDirs) ++ " found):"
          putStrLn ""
          mapM_ (showAgent agentsDir) (sort agentDirs)
          putStrLn ""
          -- Highlight agents referenced in the spec
          let specAgents = concatMap phaseAgents (tsPhases spec)
          putStrLn $ "Agents referenced in spec (" ++ show (length specAgents) ++ "):"
          mapM_ (\a -> putStrLn $ "  • " ++ a) specAgents

phaseAgents :: Phase -> [String]
phaseAgents p =
  let single = maybe [] (\a -> [T.unpack a]) (phAgent p)
      multi  = maybe [] (map T.unpack) (phAgents p)
  in single ++ multi

showAgent :: FilePath -> FilePath -> IO ()
showAgent agentsDir agentName = do
  let agentDir = agentsDir </> agentName
  hasSoul   <- doesFileExist (agentDir </> "SOUL.md")
  hasConfig <- doesFileExist (agentDir </> "config.yaml")
  let (icon, note) = case (hasSoul, hasConfig) of
        (True, True)  -> ("✓", "")
        (True, False) -> ("⚠", " (missing config.yaml)")
        (False, True) -> ("⚠", " (missing SOUL.md)")
        (False, False)-> ("✗", " (missing SOUL.md + config.yaml)")
  putStrLn $ "  " ++ icon ++ " " ++ agentName ++ note

showRun :: FilePath -> FilePath -> IO ()
showRun runsBase runId = do
  let runDir = runsBase </> runId
      cpFile = runDir ++ "/checkpoint.state"
  cpExists <- doesFileExist cpFile
  if cpExists
    then do
      cpResult <- readCheckpoint runDir
      case cpResult of
        Right cs -> putStrLn $ "  " ++ runId ++ "  [PAUSED after '" ++ T.unpack (csPausedAfter cs) ++ "']"
        Left  _  -> putStrLn $ "  " ++ runId ++ "  [PAUSED — unreadable checkpoint]"
    else
      putStrLn $ "  " ++ runId ++ "  [COMPLETE]"
