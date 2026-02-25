module Main (main) where

import Options.Applicative
import System.Directory (makeAbsolute, getCurrentDirectory, createDirectoryIfMissing)
import System.FilePath (takeDirectory)

import Guild.Types (TeamSpec(..))
import Guild.Parser (parseTeamSpec)
import Guild.Resolver (resolveAgents)
import Guild.Generator (generateProject)

-- ---------------------------------------------------------------------------
-- CLI definition
-- ---------------------------------------------------------------------------

data Command
  = Init FilePath (Maybe FilePath)
  deriving (Show)

parseCommand :: Parser Command
parseCommand = subparser
  ( command "init" (info initOpts (progDesc "Initialize project from a team spec"))
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
