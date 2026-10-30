{-# LANGUAGE ForeignFunctionInterface #-}

-- | Anchored file access. Only provider-derived roots enter this interface.
-- V1 wire paths use exact ASCII directory-entry spellings; contents may be UTF-8.
-- Provider serialization and settled validation processes are prerequisites;
-- arbitrary host operators with write access are outside this trust boundary.
module Shikigami.Workspace.ContainedFile
  ( ContainedFile,
    FileError (..),
    withContainedFile,
    withWorkspaceLock,
    readContainedFile,
    readContainedGitBlob,
    containedTargetIdentity,
    replaceContainedFile,
    replaceContainedFileOwned,
    ensurePrivateDirectory,
    checkPrivateDirectory,
    provisionContainedRoot,
    listContainedFiles,
  )
where

import Control.Exception (bracket)
import Data.ByteString qualified as Bytes
import Data.List (inits, sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Foreign
import Foreign.C
import Shikigami.Workspace.Instructions (validWorkspacePath)

newtype ContainedFile = ContainedFile (Ptr ())

data FileError = FilePathRefused | FileContentConflict | FileTooLarge | FileUnavailable | FileBusy
  deriving stock (Eq, Show)

foreign import ccall safe "shikigami_ws_private" privateDirectory :: CString -> IO CInt

foreign import ccall safe "shikigami_ws_is_private" isPrivateDirectory :: CString -> IO CInt

foreign import ccall safe "shikigami_ws_open" openTarget :: CString -> CString -> IO (Ptr ())

foreign import ccall unsafe "shikigami_ws_close" closeTarget :: Ptr () -> IO ()

foreign import ccall safe "shikigami_ws_read" readTarget :: Ptr () -> Ptr Word8 -> CInt -> IO CInt

foreign import ccall unsafe "shikigami_ws_identity" identifyTarget :: Ptr () -> CString -> CInt -> IO CInt

foreign import ccall safe "shikigami_ws_replace" replaceTarget :: Ptr () -> CString -> CString -> Ptr Word8 -> CInt -> Ptr Word8 -> CInt -> IO CInt

foreign import ccall safe "shikigami_ws_replace_owned" replaceOwnedTarget :: Ptr () -> CString -> CString -> Ptr Word8 -> CInt -> Ptr Word8 -> CInt -> CInt -> IO CInt

foreign import ccall safe "shikigami_ws_lock" lockWorkspace :: CString -> IO CInt

foreign import ccall unsafe "shikigami_ws_unlock" unlockWorkspace :: CInt -> IO ()

foreign import ccall safe "shikigami_ws_provision" provisionRoot :: Ptr () -> CInt -> CInt -> IO CInt

foreign import ccall safe "shikigami_ws_manifest" manifestRoot :: Ptr () -> CInt -> CString -> CInt -> IO CInt

withContainedFile :: FilePath -> Text -> (ContainedFile -> IO (Either FileError a)) -> IO (Either FileError a)
withContainedFile root path use
  | not (validWorkspacePath path) || not (Text.all (< '\DEL') path) = pure (Left FilePathRefused)
  | otherwise = withCString root \rootName -> Bytes.useAsCString (Encoding.encodeUtf8 path) \target ->
      bracket (openTarget rootName target) closeTarget \pointer ->
        if pointer == nullPtr then pure (Left FilePathRefused) else use (ContainedFile pointer)

withWorkspaceLock :: FilePath -> IO (Either FileError a) -> IO (Either FileError a)
withWorkspaceLock metadata use = withCString metadata \name ->
  bracket (lockWorkspace name) (\fd -> if fd < 0 then pure () else unlockWorkspace fd) \fd ->
    if fd < 0 then pure (Left FileBusy) else use

readContainedFile :: Int -> ContainedFile -> IO (Either FileError (Maybe Bytes.ByteString))
readContainedFile = readWithBound 1048576

-- Git must preserve unchanged binary/source blobs larger than an edit tool's
-- content limit. This separate entry point does not enlarge model file reads.
readContainedGitBlob :: Int -> ContainedFile -> IO (Either FileError (Maybe Bytes.ByteString))
readContainedGitBlob = readWithBound 16777216

readWithBound :: Int -> Int -> ContainedFile -> IO (Either FileError (Maybe Bytes.ByteString))
readWithBound ceilingBytes limit (ContainedFile pointer)
  | limit < 0 || limit > ceilingBytes = pure (Left FileTooLarge)
  | otherwise = allocaBytes (limit + 1) \buffer -> do
      size <- readTarget pointer buffer (fromIntegral limit)
      case size of
        -2 -> pure (Right Nothing)
        -5 -> pure (Left FileTooLarge)
        n | n < 0 -> pure (Left FileUnavailable)
        n -> Right . Just <$> Bytes.packCStringLen (castPtr buffer, fromIntegral n)

containedTargetIdentity :: ContainedFile -> IO (Either FileError Text)
containedTargetIdentity (ContainedFile pointer) = allocaBytes 128 \buffer -> do
  size <- identifyTarget pointer buffer 128
  if size < 0 then pure (Left FileUnavailable) else Right . Encoding.decodeUtf8 <$> Bytes.packCStringLen (buffer, fromIntegral size)

replaceContainedFile :: FilePath -> ContainedFile -> Maybe Bytes.ByteString -> Bytes.ByteString -> IO (Either FileError ())
replaceContainedFile = replaceWith replaceTarget

-- Revision 2 publishes with the reserved workspace identity. Metadata remains
-- provider-owned; unprivileged repository commands receive neither it nor its
-- descriptors. The caller must retain the qualified profile and process fence.
replaceContainedFileOwned :: Int -> FilePath -> ContainedFile -> Maybe Bytes.ByteString -> Bytes.ByteString -> IO (Either FileError ())
replaceContainedFileOwned uid metadata target expected content
  | uid < 1000 || uid > 2147483647 = pure (Left FilePathRefused)
  | otherwise = replaceWith (\pointer directory nonce before expectedSize after size -> replaceOwnedTarget pointer directory nonce before expectedSize after size (fromIntegral uid)) metadata target expected content

replaceWith :: (Ptr () -> CString -> CString -> Ptr Word8 -> CInt -> Ptr Word8 -> CInt -> IO CInt) -> FilePath -> ContainedFile -> Maybe Bytes.ByteString -> Bytes.ByteString -> IO (Either FileError ())
replaceWith replace metadata (ContainedFile pointer) expected content
  | Bytes.length content > 262144 || maybe False ((> 262144) . Bytes.length) expected = pure (Left FileTooLarge)
  | otherwise = do
      nonce <- ("replace-" <>) . UUID.toString <$> UUID.nextRandom
      withCString metadata \directory -> withCString nonce \temporary ->
        Bytes.useAsCString (maybe Bytes.empty id expected) \before -> Bytes.useAsCStringLen content \(after, size) -> do
          result <- replace pointer directory temporary (castPtr before) (maybe (-1) (fromIntegral . Bytes.length) expected) (castPtr after) (fromIntegral size)
          pure case result of
            0 -> Right ()
            -3 -> Left FileContentConflict
            _ -> Left FileUnavailable

ensurePrivateDirectory :: FilePath -> IO (Either FileError ())
ensurePrivateDirectory path = withCString path \name -> do
  result <- privateDirectory name
  pure (if result == 0 then Right () else Left FileUnavailable)

checkPrivateDirectory :: FilePath -> IO (Either FileError ())
checkPrivateDirectory path = withCString path \name -> do
  result <- isPrivateDirectory name
  pure (if result == 0 then Right () else Left FileUnavailable)

-- The caller holds the workspace lock, checks no process/effect is pending and
-- obtains fresh target-bound authority before apply=True. A check never writes.
provisionContainedRoot :: Int -> Bool -> ContainedFile -> IO (Either FileError ())
provisionContainedRoot uid apply (ContainedFile target)
  | uid < 1000 || uid > 2147483647 = pure (Left FilePathRefused)
  | otherwise = do
      result <- provisionRoot target (fromIntegral uid) (if apply then 1 else 0)
      pure case result of
        0 -> Right ()
        -3 -> Left FileContentConflict
        -5 -> Left FileTooLarge
        _ -> Left FileUnavailable

-- Protected capture metadata only; contents are read through separately pinned
-- contained targets. The caller holds the workspace lock and process barrier
-- across both enumeration and reads. Empty directories have no Git identity.
listContainedFiles :: Int -> ContainedFile -> IO (Either FileError [(Text, Bool)])
listContainedFiles uid (ContainedFile target)
  | uid < 1000 || uid > 2147483647 = pure (Left FilePathRefused)
  | otherwise = allocaBytes 1048576 \buffer -> do
      size <- manifestRoot target (fromIntegral uid) buffer 1048576
      case size of
        -3 -> pure (Left FileContentConflict)
        -5 -> pure (Left FileTooLarge)
        n | n < 0 -> pure (Left FileUnavailable)
        n -> do
          bytes <- Bytes.packCStringLen (buffer, fromIntegral n)
          pure do
            text <- either (const (Left FilePathRefused)) Right (Encoding.decodeUtf8' bytes)
            records <- if Text.null text then Right [] else if Text.isSuffixOf "\0" text then Right (init (Text.splitOn "\0" text)) else Left FilePathRefused
            entries <- traverse parse records
            let paths = map fst entries
                prefixes = Set.fromList [Text.intercalate "/" prefix | path <- paths, prefix <- drop 1 (inits (Text.splitOn "/" path))]
            if length paths /= Set.size (Set.fromList paths) || Set.size prefixes /= Set.size (Set.map Text.toCaseFold prefixes)
              then Left FilePathRefused
              else Right (sort entries)
  where
    parse record = case Text.splitOn "\t" record of
      [mode, path] | mode `elem` ["100644", "100755"] && validWorkspacePath path && Text.all (< '\DEL') path -> Right (path, mode == "100755")
      _ -> Left FilePathRefused
