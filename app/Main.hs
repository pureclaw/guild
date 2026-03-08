module Main (main) where

import Control.Monad (filterM)
import Data.List (sort, isInfixOf)
import qualified Data.Text as T
import Options.Applicative
import System.Directory (makeAbsolute, getCurrentDirectory, createDirectoryIfMissing,
                         listDirectory, doesDirectoryExist, doesFileExist)
import System.FilePath (takeDirectory, takeFileName, (</>))
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)

import Guild.Types (TeamSpec(..), ProjectConfig(..), Phase(..), Checkpoint(..))
import Guild.Parser (parseTeamSpec)
import Guild.Resolver (resolveAgents, expandTilde)
import Guild.Generator (generateProject)
import Guild.Runtime.Machine (PipelineResult(..), runPipeline, runPipelineFrom,
                               readCheckpoint, CheckpointState(..))
import Guild.Runtime.Beads (primeContext, extractKnowledge)
import Guild.Runtime.SlotStore (openSlotStore, listSlots)

-- ---------------------------------------------------------------------------
-- CLI definition
-- ---------------------------------------------------------------------------

data Command
  = Init FilePath (Maybe FilePath)
  | Validate FilePath
  | Run FilePath (Maybe FilePath)   -- spec, optional resume run-dir
  | Resume FilePath FilePath        -- spec, run-dir to resume
  | RunsList
  | RunsShow FilePath               -- run-dir; show slot contents
  | AgentsList FilePath             -- spec; list agents in agents_dir
  | Graph FilePath                  -- spec; print ASCII pipeline graph
  deriving (Show)

parseCommand :: Parser Command
parseCommand = subparser
  ( command "init"     (info initOpts     (progDesc "Initialize project from a team spec"))
 <> command "validate" (info validateOpts (progDesc "Validate a team spec"))
 <> command "run"      (info runOpts      (progDesc "Execute a pipeline from a team spec"))
 <> command "resume"   (info resumeOpts   (progDesc "Resume a paused pipeline run"))
 <> command "runs"     (info runsOpts     (progDesc "Manage pipeline runs"))
 <> command "agents"   (info agentsOpts   (progDesc "Manage agent library"))
 <> command "graph"    (info graphOpts    (progDesc "Print ASCII pipeline graph"))
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
 <> command "show" (info runsShowOpts   (progDesc "Show slot outputs from a run"))
  )

runsShowOpts :: Parser Command
runsShowOpts = RunsShow
  <$> argument str
      ( metavar "RUN_DIR"
     <> help "Path to the run directory (or run ID under .agentic/runs/)"
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

graphOpts :: Parser Command
graphOpts = Graph
  <$> argument str
      ( metavar "SPEC"
     <> help "Path to team.toml spec to visualize"
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
    RunsShow runDirArg       -> runRunsShow runDirArg
    AgentsList specPath      -> runAgentsList specPath
    Graph specPath           -> runGraph specPath

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
      uuid  <- toString <$> nextRandom
      now   <- getCurrentTime
      let timestamp  = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
          dirStamp   = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now
          runId      = dirStamp ++ "-" ++ take 8 uuid

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

      -- Write run manifest
      writeRunManifest runDir runId absSpec timestamp (length (tsPhases spec)) agentsBaseDir

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
-- graph
-- ---------------------------------------------------------------------------

runGraph :: FilePath -> IO ()
runGraph specPath = do
  absSpec <- makeAbsolute specPath
  result  <- parseTeamSpec absSpec
  case result of
    Left err -> do
      putStrLn "Error parsing team spec:"
      putStrLn err
    Right spec -> do
      let name   = T.unpack (pcName (tsProject spec))
          phases = tsPhases spec
          cps    = tsCheckpoints spec
          width  = 60

      putStrLn ""
      putStrLn $ "Pipeline: " ++ name
      putStrLn $ replicate width '━'
      putStrLn ""
      mapM_ (printPhaseNode cps width) (zip phases [0..])
      putStrLn ""

printPhaseNode :: [Checkpoint] -> Int -> (Phase, Int) -> IO ()
printPhaseNode checkpoints width (phase, idx) = do
  let name  = phName phase
      gates = phGates phase

  -- Connector from previous phase (except first)
  if idx > 0
    then do
      putStrLn "       │"
      putStrLn "       ▼"
    else pure ()

  -- Phase box
  case phAgents phase of
    Just agentList -> do
      -- Parallel phase
      let agentCount = length agentList
          reqStr = maybe "" (\r -> " (require: " ++ T.unpack r ++ ")") (phRequire phase)
      putStrLn $ "  ┌─ " ++ T.unpack name ++ "  [parallel × " ++ show agentCount ++ "]" ++ reqStr
      mapM_ (\(agent, i) ->
        putStrLn $ "  " ++ (if i == agentCount then "└─" else "├─")
                ++ " " ++ T.unpack agent
        ) (zip agentList [1..])
    Nothing -> do
      -- Single-agent phase
      let agentStr = maybe (T.unpack name) T.unpack (phAgent phase)
      putStrLn $ "  [ " ++ T.unpack name ++ " ]  →  " ++ agentStr

  -- Gates on this phase
  mapM_ (\g -> putStrLn $ "       🔒 gate: " ++ T.unpack g) gates

  -- Checkpoint after this phase
  case findCp checkpoints name of
    Just cp -> do
      putStrLn "       │"
      let desc = take (width - 15) (T.unpack (cpDescription cp))
      putStrLn $ "       ⏸  CHECKPOINT"
      putStrLn $ "          " ++ desc ++ (if length desc < length (T.unpack (cpDescription cp)) then "..." else "")
    Nothing -> pure ()

findCp :: [Checkpoint] -> T.Text -> Maybe Checkpoint
findCp cps name = case filter (\cp -> cpAfter cp == name) cps of
  (c:_) -> Just c
  []    -> Nothing

-- | Write a simple JSON manifest to the run directory.
writeRunManifest :: FilePath -> String -> FilePath -> String -> Int -> FilePath -> IO ()
writeRunManifest runDir runId specPath startedAt phaseCount agentsDir = do
  let manifest = unlines
        [ "{"
        , "  \"run_id\": \"" ++ runId ++ "\","
        , "  \"spec\": \"" ++ specPath ++ "\","
        , "  \"started_at\": \"" ++ startedAt ++ "\","
        , "  \"phase_count\": " ++ show phaseCount ++ ","
        , "  \"agents_dir\": \"" ++ agentsDir ++ "\""
        , "}"
        ]
  writeFile (runDir </> "run.json") manifest

-- ---------------------------------------------------------------------------
-- runs show
-- ---------------------------------------------------------------------------

runRunsShow :: FilePath -> IO ()
runRunsShow runDirArg = do
  cwd <- getCurrentDirectory

  -- Support both full paths and run IDs under .agentic/runs/
  absRunDir <- do
    exists <- doesDirectoryExist runDirArg
    if exists
      then makeAbsolute runDirArg
      else do
        let candidatePath = cwd </> ".agentic" </> "runs" </> runDirArg
        exists2 <- doesDirectoryExist candidatePath
        if exists2
          then pure candidatePath
          else do
            putStrLn $ "Run not found: " ++ runDirArg
            pure ""

  if null absRunDir
    then pure ()
    else showRunDetails absRunDir

showRunDetails :: FilePath -> IO ()
showRunDetails runDir = do
  -- Read manifest if present
  let manifestPath = runDir </> "run.json"
  hasManifest <- doesFileExist manifestPath
  if hasManifest
    then do
      manifest <- readFile manifestPath
      putStrLn $ "Run:     " ++ takeFileName runDir
      -- Print selected fields
      let ls = lines manifest
          findField k = case filter (k `isInfixOf`) ls of
            (l:_) -> dropWhile (== ' ') . drop 1 . dropWhile (/= ':') $ l
            []    -> "(unknown)"
      putStrLn $ "Spec:    " ++ cleanup (findField "spec")
      putStrLn $ "Started: " ++ cleanup (findField "started_at")
    else
      putStrLn $ "Run: " ++ takeFileName runDir

  -- Check status
  let cpFile = runDir </> "checkpoint.state"
  cpExists <- doesFileExist cpFile
  status <- if cpExists
    then return "PAUSED"
    else return "COMPLETE"
  putStrLn $ "Status:  " ++ status

  -- Read slot store
  let dbPath = runDir </> "slots.db"
  dbExists <- doesFileExist dbPath
  if not dbExists
    then putStrLn "(no slot data)"
    else do
      store <- openSlotStore dbPath
      slots <- listSlots store
      putStrLn ""
      putStrLn $ replicate 60 '─'

      -- Group slots by step and print each
      let steps = nubOrdered (map (\(s,_,_) -> s) slots)
      mapM_ (\step -> do
        let stepSlots = [(k,v) | (s,k,v) <- slots, s == step]
        -- Find the aggregate slot (key == step name) as the main output
        let mainOutput = case [(v) | (k,v) <- stepSlots, k == step] of
              (v:_) -> v
              []    -> case stepSlots of
                ((_, v):_) -> v
                []         -> T.empty
        putStrLn $ "  ▶ " ++ T.unpack step
        putStrLn $ replicate 60 '─'
        let preview = T.take 2000 mainOutput
        putStrLn (T.unpack preview)
        if T.length mainOutput > 2000
          then putStrLn $ "  ... (" ++ show (T.length mainOutput) ++ " chars total)"
          else pure ()
        putStrLn ""
        ) steps

-- | Remove duplicates while preserving order.
nubOrdered :: Eq a => [a] -> [a]
nubOrdered = foldr (\x acc -> if x `elem` acc then acc else x:acc) []

-- | Strip JSON string quotes and trailing comma/whitespace.
cleanup :: String -> String
cleanup s =
  let s1 = dropWhile (\c -> c == '"' || c == ' ') s
      s2 = reverse . dropWhile (\c -> c == '"' || c == ',' || c == ' ') . reverse $ s1
  in s2

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
