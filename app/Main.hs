module Main (main) where

import Options.Applicative
import System.Directory (makeAbsolute, getCurrentDirectory, createDirectoryIfMissing,
                         listDirectory, doesDirectoryExist)
import System.FilePath (takeDirectory, (</>))
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)

import Guild.Types (TeamSpec(..), ProjectConfig(..))
import Guild.Parser (parseTeamSpec)
import Guild.Resolver (resolveAgents)
import Guild.Generator (generateProject)
import Guild.Runtime.Machine (runPipeline)

-- ---------------------------------------------------------------------------
-- CLI definition
-- ---------------------------------------------------------------------------

data Command
  = Init FilePath (Maybe FilePath)
  | Validate FilePath
  | Run FilePath
  | RunsList
  deriving (Show)

parseCommand :: Parser Command
parseCommand = subparser
  ( command "init" (info initOpts (progDesc "Initialize project from a team spec"))
 <> command "validate" (info validateOpts (progDesc "Validate a team spec"))
 <> command "run" (info runOpts (progDesc "Execute a pipeline from a team spec"))
 <> command "runs" (info runsOpts (progDesc "Manage pipeline runs"))
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
    Init specPath mOutput -> runInit specPath mOutput
    Validate specPath     -> runValidate specPath
    Run specPath          -> runRun specPath
    RunsList              -> runRunsList

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

-- ---------------------------------------------------------------------------
-- run
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
      -- Generate a run ID and create the run directory
      runId <- toString <$> nextRandom
      now <- getCurrentTime
      let timestamp = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now

      cwd <- getCurrentDirectory
      let runsBase = cwd </> ".agentic" </> "runs"
          runDir   = runsBase </> runId
      createDirectoryIfMissing True runDir

      putStrLn $ "Run ID:    " ++ runId
      putStrLn $ "Started:   " ++ timestamp
      putStrLn $ "Run dir:   " ++ runDir
      putStrLn $ "Phases:    " ++ show (length (tsPhases spec))
      putStrLn ""

      -- Execute the pipeline
      runPipeline spec runDir

      putStrLn ""
      putStrLn $ "Run " ++ runId ++ " complete."

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
          mapM_ (\d -> putStrLn $ "  " ++ d) dirs
