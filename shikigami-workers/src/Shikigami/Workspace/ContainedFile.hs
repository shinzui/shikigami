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
    containedTargetIdentity,
    replaceContainedFile,
    ensurePrivateDirectory,
  )
where

import Control.Exception (bracket)
import Data.ByteString qualified as Bytes
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

foreign import ccall safe "shikigami_ws_open" openTarget :: CString -> CString -> IO (Ptr ())

foreign import ccall unsafe "shikigami_ws_close" closeTarget :: Ptr () -> IO ()

foreign import ccall safe "shikigami_ws_read" readTarget :: Ptr () -> Ptr Word8 -> CInt -> IO CInt

foreign import ccall unsafe "shikigami_ws_identity" identifyTarget :: Ptr () -> CString -> CInt -> IO CInt

foreign import ccall safe "shikigami_ws_replace" replaceTarget :: Ptr () -> CString -> CString -> Ptr Word8 -> CInt -> Ptr Word8 -> CInt -> IO CInt

foreign import ccall safe "shikigami_ws_lock" lockWorkspace :: CString -> IO CInt

foreign import ccall unsafe "shikigami_ws_unlock" unlockWorkspace :: CInt -> IO ()

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
readContainedFile limit (ContainedFile pointer)
  | limit < 0 || limit > 1048576 = pure (Left FileTooLarge)
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
replaceContainedFile metadata (ContainedFile pointer) expected content
  | Bytes.length content > 262144 || maybe False ((> 262144) . Bytes.length) expected = pure (Left FileTooLarge)
  | otherwise = do
      nonce <- ("replace-" <>) . UUID.toString <$> UUID.nextRandom
      withCString metadata \directory -> withCString nonce \temporary ->
        Bytes.useAsCString (maybe Bytes.empty id expected) \before -> Bytes.useAsCStringLen content \(after, size) -> do
          result <- replaceTarget pointer directory temporary (castPtr before) (maybe (-1) (fromIntegral . Bytes.length) expected) (castPtr after) (fromIntegral size)
          pure case result of
            0 -> Right ()
            -3 -> Left FileContentConflict
            _ -> Left FileUnavailable

ensurePrivateDirectory :: FilePath -> IO (Either FileError ())
ensurePrivateDirectory path = withCString path \name -> do
  result <- privateDirectory name
  pure (if result == 0 then Right () else Left FileUnavailable)
