{-# LANGUAGE OverloadedStrings #-}

module Guild.Generator
  ( generateProject
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (createDirectoryIfMissing, copyFile, doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

import Guild.Types

-- | Generate all project scaffolding from a parsed team spec.
generateProject :: FilePath -> TeamSpec -> [AgentRef] -> FilePath -> IO ()
generateProject specPath spec agents outputDir = do
  generateClaudeMd outputDir spec agents
  generateSlashCommands outputDir spec
  copyAgentSkills outputDir agents
  generateBeadsConfig outputDir
  generateCoverageThresholds outputDir spec
  copyTeamSpec specPath outputDir

-- ---------------------------------------------------------------------------
-- CLAUDE.md
-- ---------------------------------------------------------------------------

generateClaudeMd :: FilePath -> TeamSpec -> [AgentRef] -> IO ()
generateClaudeMd outputDir spec agents = do
  let content = renderClaudeMd spec agents
  TIO.writeFile (outputDir </> "CLAUDE.md") content

renderClaudeMd :: TeamSpec -> [AgentRef] -> Text
renderClaudeMd spec agents = T.unlines $
  [ "## Agent Team"
  , ""
  , "This project uses an agent team. Team spec: `.agentic/team.toml`."
  , ""
  , "### Pipeline"
  , ""
  , renderPipeline (tsPhases spec)
  , ""
  , "### Available Commands"
  , ""
  , "| Command | Purpose |"
  , "|---|---|"
  ] ++ map renderCommandRow (tsPhases spec) ++
  [ ""
  , "### Agents"
  , ""
  ] ++ map renderAgentLine agents ++
  [ ""
  , "### Gates"
  , ""
  ] ++ map renderGateLine (tsGates spec) ++
  renderCheckpointsSection (tsCheckpoints spec) ++
  renderBuildSection (tsBuild spec)

-- | Render the pipeline as a linear diagram.
renderPipeline :: [Phase] -> Text
renderPipeline phases = T.intercalate " → " (map renderPhaseNode phases)

renderPhaseNode :: Phase -> Text
renderPhaseNode p = case phAgents p of
  Just ags -> phName p <> " (" <> T.pack (show (length ags))
              <> " agents, " <> maybe "all must pass" id (phRequire p) <> ")"
  Nothing  -> phName p

-- | Render a single command table row.
renderCommandRow :: Phase -> Text
renderCommandRow p =
  let cmdName = "project:" <> T.replace "_" "-" (phName p)
      purpose = case phAgents p of
        Just ags -> "Parallel: " <> T.intercalate " + " ags
        Nothing  -> case phAgent p of
          Just a  -> "Run " <> a <> " phase"
          Nothing -> phName p
  in "| `/" <> cmdName <> "` | " <> purpose <> " |"

-- | Render a single agent description line.
renderAgentLine :: AgentRef -> Text
renderAgentLine a =
  let desc = case arSkillMd a of
        Just md -> " — " <> firstLine md
        Nothing -> ""
  in "- **" <> arName a <> "**" <> desc

-- | Extract first non-empty line from text.
firstLine :: Text -> Text
firstLine t = case filter (not . T.null) (T.lines t) of
  []    -> ""
  (l:_) -> T.strip (T.dropWhile (== '#') (T.strip l))

-- | Render a gate description line.
renderGateLine :: Gate -> Text
renderGateLine g =
  let detail = case gType g of
        "shell"     -> maybe "" id (gCommand g) <> " (shell)"
        "predicate" -> "`" <> maybe "" id (gExpr g) <> "` (predicate)"
        other       -> "(" <> other <> ")"
  in "- **" <> gName g <> "**: " <> detail

-- | Render checkpoints section if any exist.
renderCheckpointsSection :: [Checkpoint] -> [Text]
renderCheckpointsSection [] = []
renderCheckpointsSection cps =
  [ ""
  , "### Human Checkpoints"
  , ""
  ] ++ map renderCheckpointLine cps

renderCheckpointLine :: Checkpoint -> Text
renderCheckpointLine cp =
  "- **After " <> cpAfter cp <> "**: " <> cpDescription cp

-- | Render optional build section.
renderBuildSection :: Maybe BuildConfig -> [Text]
renderBuildSection Nothing = []
renderBuildSection (Just bc) =
  [ ""
  , "### Build"
  , ""
  ] ++ maybe [] (\t -> ["- **test**: `" <> t <> "`"]) (bcTest bc)
    ++ maybe [] (\l -> ["- **lint**: `" <> l <> "`"]) (bcLint bc)
    ++ maybe [] (\c -> ["- **typecheck**: `" <> c <> "`"]) (bcTypecheck bc)
    ++ maybe [] (\c -> ["- **coverage**: `" <> c <> "`"]) (bcCoverage bc)
    ++ maybe [] (\t -> ["- **coverage threshold**: " <> T.pack (show t) <> "%"]) (bcCoverageThreshold bc)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

generateSlashCommands :: FilePath -> TeamSpec -> IO ()
generateSlashCommands outputDir spec = do
  let cmdDir = outputDir </> ".claude" </> "commands"
  createDirectoryIfMissing True cmdDir
  mapM_ (writePhaseCommand cmdDir) (tsPhases spec)

writePhaseCommand :: FilePath -> Phase -> IO ()
writePhaseCommand cmdDir phase = do
  let fileName = T.unpack (T.replace "_" "-" (phName phase)) ++ ".md"
      content  = renderPhaseCommand phase
  TIO.writeFile (cmdDir </> fileName) content

renderPhaseCommand :: Phase -> Text
renderPhaseCommand p = T.unlines $
  [ "# " <> phName p
  , ""
  ] ++ case phAgents p of
    Just ags ->
      [ "Run parallel agents for this phase: " <> T.intercalate ", " ags <> "."
      , ""
      , "Requirement: " <> maybe "all must pass" id (phRequire p)
      ] ++ freshNote (phFreshInstance p)
    Nothing ->
      [ "Run the **" <> maybe (phName p) id (phAgent p) <> "** agent for this phase."
      ] ++ freshNote (phFreshInstance p)
  where
    freshNote (Just True) = ["", "_Fresh instance: agent starts with no prior context._"]
    freshNote _           = []

-- ---------------------------------------------------------------------------
-- Agent skill files
-- ---------------------------------------------------------------------------

copyAgentSkills :: FilePath -> [AgentRef] -> IO ()
copyAgentSkills outputDir agents = do
  mapM_ (copyOneAgent outputDir) agents

copyOneAgent :: FilePath -> AgentRef -> IO ()
copyOneAgent outputDir agent = do
  let destDir = outputDir </> ".claude" </> "plugins" </> "guild" </> "skills"
                </> T.unpack (arName agent)
  createDirectoryIfMissing True destDir
  -- Copy all files from the agent source directory
  let srcDir = arPath agent
  srcExists <- doesDirectoryExist srcDir
  if srcExists
    then do
      files <- listDirectory srcDir
      mapM_ (\f -> do
        let src = srcDir </> f
            dst = destDir </> f
        -- Only copy files, not directories (shallow copy)
        isDir <- doesDirectoryExist src
        if not isDir
          then copyFile src dst
          else pure ()
        ) files
    else
      -- If source doesn't exist, write a placeholder SKILL.md
      case arSkillMd agent of
        Just md -> TIO.writeFile (destDir </> "SKILL.md") md
        Nothing -> TIO.writeFile (destDir </> "SKILL.md")
                     ("# " <> arName agent <> "\n\nAgent skill definition.\n")

-- ---------------------------------------------------------------------------
-- Beads config
-- ---------------------------------------------------------------------------

generateBeadsConfig :: FilePath -> IO ()
generateBeadsConfig outputDir = do
  let beadsDir = outputDir </> ".beads"
  createDirectoryIfMissing True (beadsDir </> "hooks")
  createDirectoryIfMissing True (beadsDir </> "knowledge")
  TIO.writeFile (beadsDir </> "config.yaml") beadsConfigYaml

beadsConfigYaml :: Text
beadsConfigYaml = T.unlines
  [ "# Beads knowledge system configuration"
  , "# Generated by guild init"
  , ""
  , "version: 1"
  , ""
  , "knowledge:"
  , "  store: .beads/knowledge"
  , "  format: markdown"
  , ""
  , "hooks:"
  , "  pre_run: .beads/hooks/pre-run.sh"
  , "  post_run: .beads/hooks/post-run.sh"
  ]

-- ---------------------------------------------------------------------------
-- Coverage thresholds
-- ---------------------------------------------------------------------------

generateCoverageThresholds :: FilePath -> TeamSpec -> IO ()
generateCoverageThresholds outputDir spec =
  case tsBuild spec of
    Nothing -> pure ()
    Just bc -> do
      let threshold = maybe 80 id (bcCoverageThreshold bc)
      TIO.writeFile (outputDir </> ".coverage-thresholds.json") $ T.unlines
        [ "{"
        , "  \"global\": {"
        , "    \"lines\": " <> T.pack (show threshold) <> ","
        , "    \"branches\": " <> T.pack (show threshold) <> ","
        , "    \"functions\": " <> T.pack (show threshold) <> ","
        , "    \"statements\": " <> T.pack (show threshold)
        , "  }"
        , "}"
        ]

-- ---------------------------------------------------------------------------
-- Copy team spec to .agentic/
-- ---------------------------------------------------------------------------

copyTeamSpec :: FilePath -> FilePath -> IO ()
copyTeamSpec specPath outputDir = do
  let agenticDir = outputDir </> ".agentic"
  createDirectoryIfMissing True agenticDir
  copyFile specPath (agenticDir </> "team.toml")
