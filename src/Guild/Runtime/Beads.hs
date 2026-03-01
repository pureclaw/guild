{-# LANGUAGE OverloadedStrings #-}

-- | The Beads knowledge system — compounding intelligence across runs.
--
-- Before any pipeline phase runs, 'primeContext' loads all knowledge fragments
-- from @.beads\/knowledge\/@ and injects them as shared context. Every agent
-- invocation in the run receives this primed context — no extra agent configuration
-- required.
--
-- The extraction half (feeding lessons back into .beads\/knowledge\/ after a run)
-- is handled by 'extractKnowledge', which invokes a KnowledgeCuratorAgent via the
-- claude CLI to summarise the run history and append lessons learned.
--
-- This is the "feed-forward / feed-back" compounding loop described in DESIGN.md §6.
module Guild.Runtime.Beads
  ( BeadsContext (..)
  , emptyBeadsContext
  , primeContext
  , extractKnowledge
  ) where

import Control.Exception (try, SomeException)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesDirectoryExist, listDirectory, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>), takeExtension)
import System.Process (readProcessWithExitCode)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | All knowledge loaded from .beads/knowledge/ for a single run.
-- Injected as a prefix into every agent prompt.
newtype BeadsContext = BeadsContext { beadsText :: Text }

emptyBeadsContext :: BeadsContext
emptyBeadsContext = BeadsContext T.empty

-- ---------------------------------------------------------------------------
-- Priming (load → inject)
-- ---------------------------------------------------------------------------

-- | Load all Markdown files from @.beads\/knowledge\/@ (if the directory exists)
-- and concatenate them into a BeadsContext.
--
-- Files are loaded in sorted order so the context is deterministic across runs.
primeContext :: FilePath  -- ^ Working directory (where .beads/ lives)
             -> IO BeadsContext
primeContext workDir = do
  let knowledgeDir = workDir </> ".beads" </> "knowledge"
  exists <- doesDirectoryExist knowledgeDir
  if not exists
    then pure emptyBeadsContext
    else do
      entries <- sort <$> listDirectory knowledgeDir
      let mdFiles = filter (\f -> takeExtension f == ".md") entries
      if null mdFiles
        then pure emptyBeadsContext
        else do
          fragments <- mapM (loadFragment knowledgeDir) mdFiles
          let body = T.intercalate "\n\n---\n\n" (filter (not . T.null) fragments)
          if T.null body
            then pure emptyBeadsContext
            else pure . BeadsContext $
                   "# Knowledge Base (loaded from .beads/knowledge/)\n\n"
                   <> body
                   <> "\n\n---\n\n"

-- | Read one knowledge fragment file, returning empty Text on any error.
loadFragment :: FilePath -> FilePath -> IO Text
loadFragment dir filename = do
  let path = dir </> filename
  result <- try (TIO.readFile path) :: IO (Either SomeException Text)
  case result of
    Left _    -> pure T.empty
    Right txt -> pure (T.strip txt)

-- ---------------------------------------------------------------------------
-- Extraction (run history → lessons learned)
-- ---------------------------------------------------------------------------

-- | After a pipeline run completes, invoke a KnowledgeCuratorAgent via the
-- claude CLI to extract lessons and append them to @.beads\/knowledge\/@.
--
-- The curator receives the full run history (all phase outputs concatenated)
-- and is asked to identify patterns, gotchas, and decisions worth preserving.
-- Its output is written to @.beads\/knowledge\/extracted-<timestamp>.md@.
--
-- If @.beads\/knowledge\/@ does not exist, this is a no-op (the pipeline spec
-- opted out of the beads system by not shipping a .beads directory).
extractKnowledge :: FilePath  -- ^ Working directory (where .beads/ lives)
                 -> Text      -- ^ Full run history (all phase outputs joined)
                 -> String    -- ^ Timestamp string for the output filename
                 -> IO ()
extractKnowledge workDir runHistory timestamp = do
  let knowledgeDir = workDir </> ".beads" </> "knowledge"
  exists <- doesDirectoryExist knowledgeDir
  if not exists
    then putStrLn "[beads] No .beads/knowledge/ directory — skipping extraction."
    else do
      putStrLn "[beads] Extracting lessons learned from this run..."
      let prompt = curatorPrompt runHistory
      (exitCode, stdout, stderr) <- readProcessWithExitCode
        "claude"
        ["--dangerously-skip-permissions", "-p", T.unpack prompt]
        ""
      case exitCode of
        ExitSuccess -> do
          let outFile = knowledgeDir </> ("extracted-" ++ timestamp ++ ".md")
              content = T.pack stdout
          TIO.writeFile outFile content
          putStrLn $ "[beads] Lessons appended to " ++ outFile
        ExitFailure code ->
          putStrLn $ "[beads] KnowledgeCuratorAgent failed (exit " ++ show code
                     ++ "): " ++ take 200 stderr

-- | Prompt for the KnowledgeCuratorAgent.
curatorPrompt :: Text -> Text
curatorPrompt runHistory =
  "You are a KnowledgeCuratorAgent. Your job is to read a pipeline run history \
  \and extract structured lessons that will help future runs of this pipeline \
  \go better.\n\n\
  \Focus on:\n\
  \- GOTCHAS: Things that went wrong or required unexpected handling\n\
  \- PATTERNS: Approaches that worked well\n\
  \- DECISIONS: Key choices made and why\n\
  \- ANTI-PATTERNS: Things to avoid next time\n\n\
  \Format your output as Markdown with clear headers. Be concise — \
  \each bullet should be one sentence. \
  \Do not include anything from the run that future agents don't need to know.\n\n\
  \## Run History\n\n" <> runHistory
