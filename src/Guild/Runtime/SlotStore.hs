{-# LANGUAGE OverloadedStrings #-}

module Guild.Runtime.SlotStore
  ( SlotStore
  , openSlotStore
  , pushSlot
  , pullSlot
  , listSlots
  ) where

import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

-- | Handle to an open SQLite slot store.
newtype SlotStore = SlotStore Connection

-- | Open (or create) a slot store at the given path.
-- Creates the schema if it doesn't exist.
openSlotStore :: FilePath -> IO SlotStore
openSlotStore path = do
  conn <- open path
  execute_ conn
    "CREATE TABLE IF NOT EXISTS slots(\
    \id INTEGER PRIMARY KEY AUTOINCREMENT, \
    \step TEXT NOT NULL, \
    \key TEXT NOT NULL, \
    \value TEXT NOT NULL, \
    \created_at INTEGER NOT NULL)"
  pure (SlotStore conn)

-- | Push a value into the slot store.
pushSlot :: SlotStore -> Text -> Text -> Text -> IO ()
pushSlot (SlotStore conn) step key value = do
  now <- round <$> getPOSIXTime :: IO Int
  execute conn
    "INSERT INTO slots (step, key, value, created_at) VALUES (?, ?, ?, ?)"
    (step, key, value, now)

-- | Pull the most recent value for a given step and key.
pullSlot :: SlotStore -> Text -> Text -> IO (Maybe Text)
pullSlot (SlotStore conn) fromStep key = do
  rows <- query conn
    "SELECT value FROM slots WHERE step = ? AND key = ? ORDER BY id DESC LIMIT 1"
    (fromStep, key) :: IO [Only Text]
  pure $ case rows of
    [Only v] -> Just v
    _        -> Nothing

-- | List all slot entries.
listSlots :: SlotStore -> IO [(Text, Text, Text)]
listSlots (SlotStore conn) = do
  rows <- query_ conn
    "SELECT step, key, value FROM slots ORDER BY id" :: IO [(Text, Text, Text)]
  pure rows
