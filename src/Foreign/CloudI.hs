{--*-Mode:haskell;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
  ex: set ft=haskell fenc=utf-8 sts=4 ts=4 sw=4 et nomod: -}

{-

  BSD LICENSE

  Copyright (c) 2017, Michael Truog <mjtruog at gmail dot com>
  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:

      * Redistributions of source code must retain the above copyright
        notice, this list of conditions and the following disclaimer.
      * Redistributions in binary form must reproduce the above copyright
        notice, this list of conditions and the following disclaimer in
        the documentation and/or other materials provided with the
        distribution.
      * All advertising materials mentioning features or use of this
        software must display the following acknowledgment:
          This product includes software developed by Michael Truog
      * The name of the author may not be used to endorse or promote
        products derived from this software without specific prior
        written permission

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
  CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
  INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
  NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
  DAMAGE.

 -}

module Foreign.CloudI
    ( Instance.RequestType(..)
    , Instance.Source
    , Instance.Response(..)
    , Instance.Callback
    , Instance.T
    , transIdNull
    , invalidInputError
    , messageDecodingError
    , terminateError
    , Exception
    , api
    , threadCount
    , subscribe
    , subscribeCount
    , unsubscribe
    , sendAsync
    , sendSync
    , mcastAsync
    , forward_
    , forwardAsync
    , forwardSync
    , return_
    , returnAsync
    , returnSync
    , recvAsync
    , processIndex
    , processCount
    , processCountMax
    , processCountMin
    , prefix
    , timeoutInitialize
    , timeoutAsync
    , timeoutSync
    , timeoutTerminate
    , poll
    , threadCreate
    , threadsWait
    , requestHttpQsParse
    , infoKeyValueParse
    ) where

import Prelude hiding (init,length)
import Data.Bits (shiftL,(.|.))
import Data.Maybe (fromMaybe)
import Data.Typeable (Typeable)
import qualified Control.Exception as Exception
import qualified Control.Concurrent as Concurrent
import qualified Data.Array.IArray as IArray
import qualified Data.Binary.Get as Get
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Monoid as Monoid
import qualified Data.Sequence as Sequence
import qualified Data.Time.Clock as Clock
import qualified Data.Time.Clock.POSIX as POSIX (getPOSIXTime)
import qualified Data.Word as Word
import qualified Foreign.C.Types as C
import qualified Foreign.Erlang as Erlang
import qualified Foreign.CloudI.Instance as Instance
import qualified System.IO as SysIO
import qualified System.IO.Unsafe as Unsafe
import qualified System.Posix.Env as POSIX (getEnv)
type Array = IArray.Array
type Builder = Builder.Builder
type ByteString = ByteString.ByteString
type Get = Get.Get
type Handle = SysIO.Handle
type LazyByteString = LazyByteString.ByteString
type Map = Map.Map
type RequestType = Instance.RequestType
type SomeException = Exception.SomeException
type Source = Instance.Source
type ThreadId = Concurrent.ThreadId
type Word32 = Word.Word32

messageInit :: Word32
messageInit = 1
messageSendAsync :: Word32
messageSendAsync = 2
messageSendSync :: Word32
messageSendSync = 3
messageRecvAsync :: Word32
messageRecvAsync = 4
messageReturnAsync :: Word32
messageReturnAsync = 5
messageReturnSync :: Word32
messageReturnSync = 6
messageReturnsAsync :: Word32
messageReturnsAsync = 7
messageKeepalive :: Word32
messageKeepalive = 8
messageReinit :: Word32
messageReinit = 9
messageSubscribeCount :: Word32
messageSubscribeCount = 10
messageTerm :: Word32
messageTerm = 11

data Message =
      MessageSend (
        RequestType, ByteString, ByteString, ByteString, ByteString,
        Int, Int, ByteString, Source)
    | MessageKeepalive

transIdNull :: ByteString
transIdNull = Char8.pack $ List.replicate 16 '\0'

invalidInputError :: String
invalidInputError = "Invalid Input"
messageDecodingError :: String
messageDecodingError = "Message Decoding Error"
terminateError :: String
terminateError = "Terminate"

data Exception s =
      ReturnSync (Instance.T s)
    | ReturnAsync (Instance.T s)
    | ForwardSync (Instance.T s)
    | ForwardAsync (Instance.T s)
    deriving (Show, Typeable)

instance Typeable s => Exception.Exception (Exception s)

printException :: String -> IO ()
printException str =
    SysIO.hPutStrLn SysIO.stderr ("Exception: " ++ str)

printError :: String -> IO ()
printError str =
    SysIO.hPutStrLn SysIO.stderr ("Error: " ++ str)

data CallbackResult s =
      ReturnI (ByteString, ByteString, s, Instance.T s)
    | ForwardI (ByteString, ByteString, ByteString, Int, Int,
                s, Instance.T s)
    | Finished (Instance.T s)

type Result a = Either String a

api :: Typeable s => Int -> s ->
    IO (Result (Instance.T s))
api threadIndex state = do
    SysIO.hSetEncoding SysIO.stdout SysIO.utf8
    SysIO.hSetBuffering SysIO.stdout SysIO.LineBuffering
    SysIO.hSetEncoding SysIO.stderr SysIO.utf8
    SysIO.hSetBuffering SysIO.stderr SysIO.LineBuffering
    protocolValue <- POSIX.getEnv "CLOUDI_API_INIT_PROTOCOL"
    bufferSizeValue <- POSIX.getEnv "CLOUDI_API_INIT_BUFFER_SIZE"
    case (protocolValue, bufferSizeValue) of
        (Just protocol, Just bufferSizeStr) ->
            let bufferSize = read bufferSizeStr :: Int
                fd = C.CInt $ fromIntegral (threadIndex + 3)
                useHeader = protocol /= "udp"
                timeoutTerminate' = 1000
                initTerms = Erlang.OtpErlangAtom (Char8.pack "init")
            in
            case Erlang.termToBinary initTerms (-1) of
                Left err ->
                    return $ Left $ show err
                Right initBinary -> do
                    api0 <- Instance.make state protocol fd
                        useHeader bufferSize timeoutTerminate'
                    send api0 initBinary
                    result <- pollRequest api0 (-1) False
                    case result of
                        Left err ->
                            return $ Left err
                        Right (_, api1) ->
                            return $ Right api1
        (_, _) ->
            return $ Left invalidInputError

threadCount :: IO (Result Int)
threadCount = do
    threadCountValue <- POSIX.getEnv "CLOUDI_API_INIT_THREAD_COUNT"
    case threadCountValue of
        Nothing ->
            return $ Left invalidInputError
        Just threadCountStr ->
            return $ Right (read threadCountStr :: Int)

subscribe :: Instance.T s -> ByteString -> Instance.Callback s ->
    IO (Result (Instance.T s))
subscribe api0 pattern f =
    let subscribeTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "subscribe")
            , Erlang.OtpErlangString pattern]
    in
    case Erlang.termToBinary subscribeTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right subscribeBinary -> do
            send api0 subscribeBinary
            return $ Right $ Instance.callbacksAdd api0 pattern f

subscribeCount :: Typeable s => Instance.T s -> ByteString ->
    IO (Result (Int, Instance.T s))
subscribeCount api0 pattern =
    let subscribeCountTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "subscribe_count")
            , Erlang.OtpErlangString pattern]
    in
    case Erlang.termToBinary subscribeCountTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right subscribeCountBinary -> do
            send api0 subscribeCountBinary
            result <- pollRequest api0 (-1) False
            case result of
                Left err ->
                    return $ Left err
                Right (_, api1@Instance.T{Instance.subscribeCount = count}) ->
                    return $ Right (count, api1)

unsubscribe :: Instance.T s -> ByteString ->
    IO (Result (Instance.T s))
unsubscribe api0 pattern =
    let unsubscribeTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "unsubscribe")
            , Erlang.OtpErlangString pattern]
    in
    case Erlang.termToBinary unsubscribeTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right unsubscribeBinary -> do
            send api0 unsubscribeBinary
            return $ Right $ Instance.callbacksRemove api0 pattern

sendAsync :: Typeable s => Instance.T s -> ByteString -> ByteString ->
    Maybe Int -> Maybe ByteString -> Maybe Int ->
    IO (Result (ByteString, Instance.T s))
sendAsync api0@Instance.T{
      Instance.timeoutAsync = timeoutAsync'
    , Instance.priorityDefault = priorityDefault}
    name request timeoutOpt requestInfoOpt priorityOpt =
    let timeout = fromMaybe timeoutAsync' timeoutOpt
        requestInfo = fromMaybe ByteString.empty requestInfoOpt
        priority = fromMaybe priorityDefault priorityOpt
        sendAsyncTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "send_async")
            , Erlang.OtpErlangString name
            , Erlang.OtpErlangBinary requestInfo
            , Erlang.OtpErlangBinary request
            , Erlang.OtpErlangInteger timeout
            , Erlang.OtpErlangInteger priority]
    in
    case Erlang.termToBinary sendAsyncTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right sendAsyncBinary -> do
            send api0 sendAsyncBinary
            result <- pollRequest api0 (-1) False
            case result of
                Left err ->
                    return $ Left err
                Right (_, api1@Instance.T{Instance.transId = transId}) ->
                    return $ Right (transId, api1)

sendSync :: Typeable s => Instance.T s -> ByteString -> ByteString ->
    Maybe Int -> Maybe ByteString -> Maybe Int ->
    IO (Result (ByteString, ByteString, ByteString, Instance.T s))
sendSync api0@Instance.T{
      Instance.timeoutSync = timeoutSync'
    , Instance.priorityDefault = priorityDefault}
    name request timeoutOpt requestInfoOpt priorityOpt =
    let timeout = fromMaybe timeoutSync' timeoutOpt
        requestInfo = fromMaybe ByteString.empty requestInfoOpt
        priority = fromMaybe priorityDefault priorityOpt
        sendSyncTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "send_sync")
            , Erlang.OtpErlangString name
            , Erlang.OtpErlangBinary requestInfo
            , Erlang.OtpErlangBinary request
            , Erlang.OtpErlangInteger timeout
            , Erlang.OtpErlangInteger priority]
    in
    case Erlang.termToBinary sendSyncTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right sendSyncBinary -> do
            send api0 sendSyncBinary
            result <- pollRequest api0 (-1) False
            case result of
                Left err ->
                    return $ Left err
                Right (_, api1@Instance.T{
                      Instance.responseInfo = responseInfo
                    , Instance.response = response
                    , Instance.transId = transId}) ->
                    return $ Right (responseInfo, response, transId, api1)

mcastAsync :: Typeable s => Instance.T s -> ByteString -> ByteString ->
    Maybe Int -> Maybe ByteString -> Maybe Int ->
    IO (Result (Array Int ByteString, Instance.T s))
mcastAsync api0@Instance.T{
      Instance.timeoutAsync = timeoutAsync'
    , Instance.priorityDefault = priorityDefault}
    name request timeoutOpt requestInfoOpt priorityOpt =
    let timeout = fromMaybe timeoutAsync' timeoutOpt
        requestInfo = fromMaybe ByteString.empty requestInfoOpt
        priority = fromMaybe priorityDefault priorityOpt
        mcastAsyncTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "mcast_async")
            , Erlang.OtpErlangString name
            , Erlang.OtpErlangBinary requestInfo
            , Erlang.OtpErlangBinary request
            , Erlang.OtpErlangInteger timeout
            , Erlang.OtpErlangInteger priority]
    in
    case Erlang.termToBinary mcastAsyncTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right mcastAsyncBinary -> do
            send api0 mcastAsyncBinary
            result <- pollRequest api0 (-1) False
            case result of
                Left err ->
                    return $ Left err
                Right (_, api1@Instance.T{Instance.transIds = transIds}) ->
                    return $ Right (transIds, api1)

forward_ :: Typeable s =>
    Instance.T s -> Instance.RequestType -> ByteString ->
    ByteString -> ByteString -> Int -> Int -> ByteString -> Source ->
    IO ()
forward_ api0 Instance.ASYNC = forwardAsync api0
forward_ api0 Instance.SYNC = forwardSync api0

forwardAsyncI :: Instance.T s -> ByteString ->
    ByteString -> ByteString -> Int -> Int -> ByteString -> Source ->
    IO (Result (Instance.T s))
forwardAsyncI api0@Instance.T{
      Instance.requestTimeoutAdjustment = requestTimeoutAdjustment
    , Instance.requestTimer = requestTimer
    , Instance.requestTimeout = requestTimeout}
    name responseInfo response timeout priority transId pid = do
    timeoutNew <- if requestTimeoutAdjustment && timeout == requestTimeout then
            timeoutAdjustment requestTimer timeout
        else
            return timeout
    let forwardTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "forward_async")
            , Erlang.OtpErlangString name
            , Erlang.OtpErlangBinary responseInfo
            , Erlang.OtpErlangBinary response
            , Erlang.OtpErlangInteger timeoutNew
            , Erlang.OtpErlangInteger priority
            , Erlang.OtpErlangBinary transId
            , Erlang.OtpErlangPid pid]
    case Erlang.termToBinary forwardTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right forwardBinary -> do
            send api0 forwardBinary
            return $ Right api0

forwardAsync :: Typeable s => Instance.T s -> ByteString ->
    ByteString -> ByteString -> Int -> Int -> ByteString -> Source ->
    IO ()
forwardAsync api0 name responseInfo response timeout priority transId pid = do
    result <- forwardAsyncI api0
        name responseInfo response timeout priority transId pid
    case result of
        Left err ->
            error err
        Right api1 ->
            Exception.throwIO $ ForwardAsync api1

forwardSyncI :: Instance.T s -> ByteString ->
    ByteString -> ByteString -> Int -> Int -> ByteString -> Source ->
    IO (Result (Instance.T s))
forwardSyncI api0@Instance.T{
      Instance.requestTimeoutAdjustment = requestTimeoutAdjustment
    , Instance.requestTimer = requestTimer
    , Instance.requestTimeout = requestTimeout}
    name responseInfo response timeout priority transId pid = do
    timeoutNew <- if requestTimeoutAdjustment && timeout == requestTimeout then
            timeoutAdjustment requestTimer timeout
        else
            return timeout
    let forwardTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "forward_sync")
            , Erlang.OtpErlangString name
            , Erlang.OtpErlangBinary responseInfo
            , Erlang.OtpErlangBinary response
            , Erlang.OtpErlangInteger timeoutNew
            , Erlang.OtpErlangInteger priority
            , Erlang.OtpErlangBinary transId
            , Erlang.OtpErlangPid pid]
    case Erlang.termToBinary forwardTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right forwardBinary -> do
            send api0 forwardBinary
            return $ Right api0

forwardSync :: Typeable s => Instance.T s -> ByteString ->
    ByteString -> ByteString -> Int -> Int -> ByteString -> Source ->
    IO ()
forwardSync api0 name responseInfo response timeout priority transId pid = do
    result <- forwardSyncI api0
        name responseInfo response timeout priority transId pid
    case result of
        Left err ->
            error err
        Right api1 ->
            Exception.throwIO $ ForwardSync api1

return_ :: Typeable s =>
    Instance.T s -> Instance.RequestType -> ByteString -> ByteString ->
    ByteString -> ByteString -> Int -> ByteString -> Source ->
    IO ()
return_ api0 Instance.ASYNC = returnAsync api0
return_ api0 Instance.SYNC = returnSync api0

returnAsyncI :: Instance.T s -> ByteString -> ByteString ->
    ByteString -> ByteString -> Int -> ByteString -> Source ->
    IO (Result (Instance.T s))
returnAsyncI api0@Instance.T{
      Instance.requestTimeoutAdjustment = requestTimeoutAdjustment
    , Instance.requestTimer = requestTimer
    , Instance.requestTimeout = requestTimeout}
    name pattern responseInfo response timeout transId pid = do
    timeoutNew <- if requestTimeoutAdjustment && timeout == requestTimeout then
            timeoutAdjustment requestTimer timeout
        else
            return timeout
    let returnTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "return_async")
            , Erlang.OtpErlangString name
            , Erlang.OtpErlangString pattern
            , Erlang.OtpErlangBinary responseInfo
            , Erlang.OtpErlangBinary response
            , Erlang.OtpErlangInteger timeoutNew
            , Erlang.OtpErlangBinary transId
            , Erlang.OtpErlangPid pid]
    case Erlang.termToBinary returnTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right returnBinary -> do
            send api0 returnBinary
            return $ Right api0

returnAsync :: Typeable s => Instance.T s -> ByteString -> ByteString ->
    ByteString -> ByteString -> Int -> ByteString -> Source ->
    IO ()
returnAsync api0 name pattern responseInfo response timeout transId pid = do
    result <- returnAsyncI api0
        name pattern responseInfo response timeout transId pid
    case result of
        Left err ->
            error err
        Right api1 ->
            Exception.throwIO $ ReturnAsync api1

returnSyncI :: Instance.T s -> ByteString -> ByteString ->
    ByteString -> ByteString -> Int -> ByteString -> Source ->
    IO (Result (Instance.T s))
returnSyncI api0@Instance.T{
      Instance.requestTimeoutAdjustment = requestTimeoutAdjustment
    , Instance.requestTimer = requestTimer
    , Instance.requestTimeout = requestTimeout}
    name pattern responseInfo response timeout transId pid = do
    timeoutNew <- if requestTimeoutAdjustment && timeout == requestTimeout then
            timeoutAdjustment requestTimer timeout
        else
            return timeout
    let returnTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "return_sync")
            , Erlang.OtpErlangString name
            , Erlang.OtpErlangString pattern
            , Erlang.OtpErlangBinary responseInfo
            , Erlang.OtpErlangBinary response
            , Erlang.OtpErlangInteger timeoutNew
            , Erlang.OtpErlangBinary transId
            , Erlang.OtpErlangPid pid]
    case Erlang.termToBinary returnTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right returnBinary -> do
            send api0 returnBinary
            return $ Right api0

returnSync :: Typeable s => Instance.T s -> ByteString -> ByteString ->
    ByteString -> ByteString -> Int -> ByteString -> Source ->
    IO ()
returnSync api0 name pattern responseInfo response timeout transId pid = do
    result <- returnSyncI api0
        name pattern responseInfo response timeout transId pid
    case result of
        Left err ->
            error err
        Right api1 ->
            Exception.throwIO $ ReturnSync api1

recvAsync :: Typeable s => Instance.T s ->
    Maybe Int -> Maybe ByteString -> Maybe Bool ->
    IO (Result (ByteString, ByteString, ByteString, Instance.T s))
recvAsync api0@Instance.T{Instance.timeoutSync = timeoutSync'}
    timeoutOpt transIdOpt consumeOpt =
    let timeout = fromMaybe timeoutSync' timeoutOpt
        transId = fromMaybe transIdNull transIdOpt
        consume = fromMaybe True consumeOpt
        recvAsyncTerms = Erlang.OtpErlangTuple
            [ Erlang.OtpErlangAtom (Char8.pack "recv_async")
            , Erlang.OtpErlangInteger timeout
            , Erlang.OtpErlangBinary transId
            , Erlang.OtpErlangAtomBool consume]
    in
    case Erlang.termToBinary recvAsyncTerms (-1) of
        Left err ->
            return $ Left $ show err
        Right recvAsyncBinary -> do
            send api0 recvAsyncBinary
            result <- pollRequest api0 (-1) False
            case result of
                Left err ->
                    return $ Left err
                Right (_, api1@Instance.T{
                      Instance.responseInfo = responseInfo
                    , Instance.response = response
                    , Instance.transId = transId'}) ->
                    return $ Right (responseInfo, response, transId', api1)

processIndex :: Instance.T s -> Int
processIndex Instance.T{Instance.processIndex = processIndex'} =
    processIndex'

processCount :: Instance.T s -> Int
processCount Instance.T{Instance.processCount = processCount'} =
    processCount'

processCountMax :: Instance.T s -> Int
processCountMax Instance.T{Instance.processCountMax = processCountMax'} =
    processCountMax'

processCountMin :: Instance.T s -> Int
processCountMin Instance.T{Instance.processCountMin = processCountMin'} =
    processCountMin'

prefix :: Instance.T s -> ByteString
prefix Instance.T{Instance.prefix = prefix'} =
    prefix'

timeoutInitialize :: Instance.T s -> Int
timeoutInitialize Instance.T{Instance.timeoutInitialize = timeoutInitialize'} =
    timeoutInitialize'

timeoutAsync :: Instance.T s -> Int
timeoutAsync Instance.T{Instance.timeoutAsync = timeoutAsync'} =
    timeoutAsync'

timeoutSync :: Instance.T s -> Int
timeoutSync Instance.T{Instance.timeoutSync = timeoutSync'} =
    timeoutSync'

timeoutTerminate :: Instance.T s -> Int
timeoutTerminate Instance.T{Instance.timeoutTerminate = timeoutTerminate'} =
    timeoutTerminate'

nullResponse :: RequestType -> ByteString -> ByteString ->
    ByteString -> ByteString -> Int -> Int -> ByteString -> Source ->
    s -> Instance.T s -> IO (Instance.Response s)
nullResponse _ _ _ _ _ _ _ _ _ state api0 =
    return $ Instance.Null (state, api0)

callback :: Typeable s => Instance.T s ->
    (RequestType, ByteString, ByteString, ByteString, ByteString,
     Int, Int, ByteString, Source) -> IO (Result (Instance.T s))
callback api0@Instance.T{
      Instance.state = state
    , Instance.callbacks = callbacks
    , Instance.requestTimeoutAdjustment = requestTimeoutAdjustment}
    (requestType, name, pattern, requestInfo, request,
     timeout, priority, transId, pid) = do
    api1 <- if requestTimeoutAdjustment then do
            requestTimer <- POSIX.getPOSIXTime
            return api0{
                  Instance.requestTimer = requestTimer
                , Instance.requestTimeout = timeout}
        else
            return api0
    let (callbackF, callbacksNew) = case Map.lookup pattern callbacks of
            Nothing ->
                (nullResponse, callbacks)
            Just functionQueue ->
                let f = Sequence.index functionQueue 0
                    functionQueueNew = (Sequence.|>)
                        (Sequence.drop 0 functionQueue) f
                in
                (f, Map.insert pattern functionQueueNew callbacks)
        api2 = api1{Instance.callbacks = callbacksNew}
        empty = ByteString.empty
    callbackResultValue <- Exception.try $ case requestType of
        Instance.ASYNC -> do
            callbackResultAsyncValue <- Exception.try $
                callbackF requestType name pattern
                requestInfo request timeout priority transId pid
                state api2
            case callbackResultAsyncValue of
                Left (ReturnSync api3) -> do
                    printException "Synchronous Call Return Invalid"
                    return $ Finished api3
                Left (ReturnAsync api3) ->
                    return $ Finished api3
                Left (ForwardSync api3) -> do
                    printException "Synchronous Call Forward Invalid"
                    return $ Finished api3
                Left (ForwardAsync api3) ->
                    return $ Finished api3
                Right (Instance.ResponseInfo (v0, v1, v2, v3)) ->
                    return $ ReturnI (v0, v1, v2, v3)
                Right (Instance.Response (v0, v1, v2)) ->
                    return $ ReturnI (empty, v0, v1, v2)
                Right (Instance.Forward (v0, v1, v2, v3, v4)) ->
                    return $ ForwardI (v0, v1, v2, timeout, priority, v3, v4)
                Right (Instance.Forward_ (v0, v1, v2, v3, v4, v5, v6)) ->
                    return $ ForwardI (v0, v1, v2, v3, v4, v5, v6)
                Right (Instance.Null (v0, v1)) ->
                    return $ ReturnI (empty, empty, v0, v1)
                Right (Instance.NullError (err, v0, v1)) -> do
                    printError err
                    return $ ReturnI (empty, empty, v0, v1)
        Instance.SYNC -> do
            callbackResultSyncValue <- Exception.try $
                callbackF requestType name pattern
                requestInfo request timeout priority transId pid
                state api2
            case callbackResultSyncValue of
                Left (ReturnSync api3) ->
                    return $ Finished api3
                Left (ReturnAsync api3) -> do
                    printException "Asynchronous Call Return Invalid"
                    return $ Finished api3
                Left (ForwardSync api3) ->
                    return $ Finished api3
                Left (ForwardAsync api3) -> do
                    printException "Asynchronous Call Forward Invalid"
                    return $ Finished api3
                Right (Instance.ResponseInfo (v0, v1, v2, v3)) ->
                    return $ ReturnI (v0, v1, v2, v3)
                Right (Instance.Response (v0, v1, v2)) ->
                    return $ ReturnI (empty, v0, v1, v2)
                Right (Instance.Forward (v0, v1, v2, v3, v4)) ->
                    return $ ForwardI (v0, v1, v2, timeout, priority, v3, v4)
                Right (Instance.Forward_ (v0, v1, v2, v3, v4, v5, v6)) ->
                    return $ ForwardI (v0, v1, v2, v3, v4, v5, v6)
                Right (Instance.Null (v0, v1)) ->
                    return $ ReturnI (empty, empty, v0, v1)
                Right (Instance.NullError (err, v0, v1)) -> do
                    printError err
                    return $ ReturnI (empty, empty, v0, v1)
    callbackResultType <- case callbackResultValue of
        Left exception -> do
            printException $ show (exception :: Exception.SomeException)
            return $ Finished api2
        Right callbackResult ->
            return $ callbackResult
    case requestType of
        Instance.ASYNC ->
            case callbackResultType of
                Finished api4 ->
                    return $ Right api4
                ReturnI (responseInfo, response, state', api4) ->
                    returnAsyncI api4{Instance.state = state'}
                        name pattern responseInfo response timeout transId pid
                ForwardI (name', requestInfo', request', timeout', priority',
                          state', api4) ->
                    forwardAsyncI api4{Instance.state = state'}
                        name' requestInfo' request'
                        timeout' priority' transId pid
        Instance.SYNC ->
            case callbackResultType of
                Finished api4 ->
                    return $ Right api4
                ReturnI (responseInfo, response, state', api4) ->
                    returnSyncI api4{Instance.state = state'}
                        name pattern responseInfo response timeout transId pid
                ForwardI (name', requestInfo', request', timeout', priority',
                          state', api4) ->
                    forwardSyncI api4{Instance.state = state'}
                        name' requestInfo' request'
                        timeout' priority' transId pid

handleEvents :: [Message] -> Instance.T s -> Bool -> Word32 ->
    Get ([Message], Instance.T s)
handleEvents messages api0 external cmd0 = do
    cmd <- if cmd0 == 0 then Get.getWord32host else return cmd0
    case () of
      _ | cmd == messageTerm ->
            let api1 = api0{
                      Instance.terminate = True
                    , Instance.timeout = Just False} in
            if external then
                return ([], api1)
            else
                fail terminateError
        | cmd == messageReinit -> do
            processCount' <- Get.getWord32host
            timeoutAsync' <- Get.getWord32host
            timeoutSync' <- Get.getWord32host
            priorityDefault <- Get.getInt8
            requestTimeoutAdjustment <- Get.getWord8
            let api1 = Instance.reinit api0
                    processCount'
                    timeoutAsync'
                    timeoutSync'
                    priorityDefault
                    requestTimeoutAdjustment
            empty <- Get.isEmpty
            if not empty then
                handleEvents messages api1 external 0
            else
                return (messages, api1)
        | cmd == messageKeepalive -> do
            let messagesNew = MessageKeepalive:messages
            empty <- Get.isEmpty
            if not empty then
                handleEvents messagesNew api0 external 0
            else
                return (messagesNew, api0)
        | otherwise ->
            fail messageDecodingError

pollRequestDataGet :: [Message] -> Instance.T s -> Bool ->
    Get ([Message], Instance.T s)
pollRequestDataGet messages api0 external = do
    cmd <- Get.getWord32host
    case () of
      _ | cmd == messageInit -> do
            processIndex' <- Get.getWord32host
            processCount' <- Get.getWord32host
            processCountMax' <- Get.getWord32host
            processCountMin' <- Get.getWord32host
            prefixSize <- Get.getWord32host
            prefix' <- Get.getByteString $ fromIntegral prefixSize - 1
            Get.skip 1
            timeoutInitialize' <- Get.getWord32host
            timeoutAsync' <- Get.getWord32host
            timeoutSync' <- Get.getWord32host
            timeoutTerminate' <- Get.getWord32host
            priorityDefault <- Get.getInt8
            requestTimeoutAdjustment <- Get.getWord8
            let api1 = Instance.init api0
                    processIndex'
                    processCount'
                    processCountMax'
                    processCountMin'
                    prefix'
                    timeoutInitialize'
                    timeoutAsync'
                    timeoutSync'
                    timeoutTerminate'
                    priorityDefault
                    requestTimeoutAdjustment
            empty <- Get.isEmpty
            if not empty then
                handleEvents messages api1 external 0
            else
                return (messages, api1)
        | cmd == messageSendAsync || cmd == messageSendSync -> do
            nameSize <- Get.getWord32host
            name <- Get.getByteString $ fromIntegral nameSize - 1
            Get.skip 1
            patternSize <- Get.getWord32host
            pattern <- Get.getByteString $ fromIntegral patternSize - 1
            Get.skip 1
            requestInfoSize <- Get.getWord32host
            requestInfo <- Get.getByteString $ fromIntegral requestInfoSize
            Get.skip 1
            requestSize <- Get.getWord32host
            request <- Get.getByteString $ fromIntegral requestSize
            Get.skip 1
            timeout <- Get.getWord32host
            priority <- Get.getInt8
            transId <- Get.getByteString 16
            pidSize <- Get.getWord32host
            pidData <- Get.getLazyByteString $ fromIntegral pidSize
            empty <- Get.isEmpty
            case Erlang.binaryToTerm pidData of
                Left err ->
                    fail $ show err
                Right (Erlang.OtpErlangPid (pid)) ->
                    let requestType =
                            if cmd == messageSendAsync then
                                Instance.ASYNC
                            else -- cmd == messageSendSync
                                Instance.SYNC
                        messagesNew = (MessageSend (
                            requestType, name, pattern, requestInfo, request,
                            fromIntegral timeout, fromIntegral priority,
                            transId, pid)):messages in
                    if not empty then
                        handleEvents messagesNew api0 external 0
                    else
                        return (messagesNew, api0)
                Right _ ->
                    fail messageDecodingError
        | cmd == messageRecvAsync || cmd == messageReturnSync -> do
            responseInfoSize <- Get.getWord32host
            responseInfo <- Get.getByteString $ fromIntegral responseInfoSize
            responseSize <- Get.getWord32host
            response <- Get.getByteString $ fromIntegral responseSize
            transId <- Get.getByteString 16
            empty <- Get.isEmpty
            let api1 = Instance.setResponse api0
                    responseInfo response transId
            if not empty then
                handleEvents messages api1 external 0
            else
                return (messages, api1)
        | cmd == messageReturnAsync -> do
            transId <- Get.getByteString 16
            empty <- Get.isEmpty
            let api1 = Instance.setTransId api0
                    transId
            if not empty then
                handleEvents messages api1 external 0
            else
                return (messages, api1)
        | cmd == messageReturnsAsync -> do
            transIdCount <- Get.getWord32host
            transIds <- Get.getByteString $ 16 * (fromIntegral transIdCount)
            empty <- Get.isEmpty
            let api1 = Instance.setTransIds api0
                    transIds transIdCount
            if not empty then
                handleEvents messages api1 external 0
            else
                return (messages, api1)
        | cmd == messageSubscribeCount -> do
            subscribeCount' <- Get.getWord32host
            empty <- Get.isEmpty
            let api1 = Instance.setSubscribeCount api0
                    subscribeCount'
            if not empty then
                handleEvents messages api1 external 0
            else
                return (messages, api1)
        | cmd == messageTerm ->
            handleEvents messages api0 external cmd
        | cmd == messageReinit -> do
            processCount' <- Get.getWord32host
            timeoutAsync' <- Get.getWord32host
            timeoutSync' <- Get.getWord32host
            priorityDefault <- Get.getInt8
            requestTimeoutAdjustment <- Get.getWord8
            let api1 = Instance.reinit api0
                    processCount'
                    timeoutAsync'
                    timeoutSync'
                    priorityDefault
                    requestTimeoutAdjustment
            empty <- Get.isEmpty
            if not empty then
                pollRequestDataGet messages api1 external
            else
                return (messages, api1)
        | cmd == messageKeepalive -> do
            let messagesNew = MessageKeepalive:messages
            empty <- Get.isEmpty
            if not empty then
                pollRequestDataGet messagesNew api0 external
            else
                return (messagesNew, api0)
        | otherwise ->
            fail messageDecodingError

pollRequestDataProcess :: Typeable s => [Message] -> Instance.T s ->
    IO (Result (Instance.T s))
pollRequestDataProcess [] api0 =
    return $ Right api0
pollRequestDataProcess (message:messages) api0 =
    case message of
        MessageSend callbackData -> do
            callbackResult <- callback api0 callbackData
            case callbackResult of
                Left err ->
                    return $ Left err
                Right api1 ->
                    pollRequestDataProcess messages api1
        MessageKeepalive ->
            let aliveTerms = Erlang.OtpErlangAtom (Char8.pack "keepalive") in
            case Erlang.termToBinary aliveTerms (-1) of
                Left err ->
                    return $ Left $ show err
                Right aliveBinary -> do
                    send api0 aliveBinary
                    pollRequestDataProcess messages api0

pollRequestData :: Typeable s => Instance.T s -> Bool -> LazyByteString ->
    IO (Result (Instance.T s))
pollRequestData api0 external dataIn =
    case Get.runGetOrFail (pollRequestDataGet [] api0 external) dataIn of
        Left (_, _, err) ->
            return $ Left err
        Right (_, _, (messages, api1)) ->
            pollRequestDataProcess (List.reverse messages) api1

pollRequestLoop :: Typeable s =>
    Instance.T s -> Int -> Bool -> Clock.NominalDiffTime ->
    IO (Result (Bool, Instance.T s))
pollRequestLoop api0@Instance.T{
      Instance.socketHandle = socketHandle} timeout external pollTimer = do
    inputAvailable <- SysIO.hWaitForInput socketHandle timeout
    if not inputAvailable then
        return $ Right (True, api0{Instance.timeout = Nothing})
    else do
        (dataIn, _, api1) <- recv api0
        dataResult <- pollRequestData api1 external dataIn
        case dataResult of
            Left err ->
                return $ Left err
            Right api2@Instance.T{Instance.timeout = Just result} ->
                return $ Right (result, api2{Instance.timeout = Nothing})
            Right api2 -> do
                (pollTimerNew, timeoutNew) <- if timeout <= 0 then
                        return (0, timeout)
                    else
                        timeoutAdjustmentPoll pollTimer timeout
                if timeout == 0 then
                    return $ Right (True, api2{Instance.timeout = Nothing})
                else
                    pollRequestLoop api2 timeoutNew external pollTimerNew

pollRequestLoopBegin :: Typeable s =>
    Instance.T s -> Int -> Bool -> Clock.NominalDiffTime ->
    IO (Result (Bool, Instance.T s))
pollRequestLoopBegin api0 timeout external pollTimer = do
    result <- Exception.try (pollRequestLoop api0 timeout external pollTimer)
    case result of
        Left exception ->
            return $ Left $ show (exception :: SomeException)
        Right success ->
            return success

pollRequest :: Typeable s => Instance.T s -> Int -> Bool ->
    IO (Result (Bool, Instance.T s))
pollRequest api0@Instance.T{
      Instance.initializationComplete = initializationComplete
    , Instance.terminate = terminate} timeout external =
    if terminate then
        return $ Right (False, api0)
    else do
        pollTimer <- if timeout <= 0 then
                return 0
            else
                POSIX.getPOSIXTime
        if external && not initializationComplete then
            let pollingTerms = Erlang.OtpErlangAtom (Char8.pack "polling") in
            case Erlang.termToBinary pollingTerms (-1) of
                Left err ->
                    return $ Left $ show err
                Right pollingBinary -> do
                    send api0 pollingBinary
                    pollRequestLoopBegin
                        api0{Instance.initializationComplete = True}
                        timeout external pollTimer
        else
            pollRequestLoopBegin api0 timeout external pollTimer

poll :: Typeable s => Instance.T s -> Int -> IO (Result (Bool, Instance.T s))
poll api0 timeout =
    pollRequest api0 timeout True

send :: Instance.T s -> LazyByteString -> IO ()
send Instance.T{
      Instance.useHeader = False
    , Instance.socketHandle = socketHandle} binary = do
    LazyByteString.hPut socketHandle binary
send Instance.T{
      Instance.useHeader = True
    , Instance.socketHandle = socketHandle} binary = do
    let total = fromIntegral (LazyByteString.length binary) :: Word32
    LazyByteString.hPut socketHandle (Builder.toLazyByteString $
        Builder.word32BE total `Monoid.mappend`
        Builder.lazyByteString binary)

recvBuffer :: Builder -> Int -> Int -> Handle -> Int ->
    IO (Builder, Int)
recvBuffer bufferRecv bufferRecvSize recvSize socketHandle bufferSize
    | recvSize <= bufferRecvSize =
        return (bufferRecv, bufferRecvSize)
    | otherwise = do
        fragment <- ByteString.hGetNonBlocking socketHandle bufferSize
        recvBuffer
            (bufferRecv `Monoid.mappend` Builder.byteString fragment)
            (bufferRecvSize + ByteString.length fragment)
            recvSize socketHandle bufferSize

recvBufferAll :: Builder -> Int -> Handle -> Int ->
    IO (Builder, Int)
recvBufferAll bufferRecv bufferRecvSize socketHandle bufferSize = do
    fragment <- ByteString.hGetNonBlocking socketHandle bufferSize
    let fragmentSize = ByteString.length fragment
        bufferRecvNew = bufferRecv `Monoid.mappend` Builder.byteString fragment
        bufferRecvSizeNew = bufferRecvSize + fragmentSize
    if fragmentSize == bufferSize then
        recvBufferAll bufferRecvNew bufferRecvSizeNew socketHandle bufferSize
    else
        return (bufferRecv, bufferRecvSize)

recv :: Instance.T s -> IO (LazyByteString, Int, Instance.T s)
recv api0@Instance.T{
      Instance.useHeader = False
    , Instance.socketHandle = socketHandle
    , Instance.bufferSize = bufferSize
    , Instance.bufferRecv = bufferRecv
    , Instance.bufferRecvSize = bufferRecvSize} = do
    (bufferRecvAll,
     bufferRecvAllSize) <- recvBufferAll
        bufferRecv bufferRecvSize socketHandle bufferSize
    return $ (
          Builder.toLazyByteString bufferRecvAll
        , bufferRecvAllSize
        , api0{
              Instance.bufferRecv = Monoid.mempty
            , Instance.bufferRecvSize = 0})
recv api0@Instance.T{
      Instance.useHeader = True
    , Instance.socketHandle = socketHandle
    , Instance.bufferSize = bufferSize
    , Instance.bufferRecv = bufferRecv
    , Instance.bufferRecvSize = bufferRecvSize} = do
    (bufferRecvHeader, bufferRecvHeaderSize) <- recvBuffer
        bufferRecv bufferRecvSize 4 socketHandle bufferSize
    let header0 = Builder.toLazyByteString bufferRecvHeader
        Just (byte0, header1) = LazyByteString.uncons header0
        Just (byte1, header2) = LazyByteString.uncons header1
        Just (byte2, header3) = LazyByteString.uncons header2
        Just (byte3, headerRemaining) = LazyByteString.uncons header3
        total = fromIntegral $
            (fromIntegral byte0 :: Word32) `shiftL` 24 .|.
            (fromIntegral byte1 :: Word32) `shiftL` 16 .|.
            (fromIntegral byte2 :: Word32) `shiftL` 8 .|.
            (fromIntegral byte3 :: Word32) :: Int
    (bufferRecvAll, bufferRecvAllSize) <- recvBuffer
        (Builder.lazyByteString headerRemaining)
        (bufferRecvHeaderSize - 4) total socketHandle bufferSize
    let bufferRecvAllStr = Builder.toLazyByteString bufferRecvAll
        (bufferRecvData, bufferRecvNew) =
            LazyByteString.splitAt (fromIntegral total) bufferRecvAllStr
    return $ (
          bufferRecvData
        , total
        , api0{
              Instance.bufferRecv = Builder.lazyByteString bufferRecvNew
            , Instance.bufferRecvSize = bufferRecvAllSize - total})

timeoutAdjustment :: Clock.NominalDiffTime -> Int ->
    IO (Int)
timeoutAdjustment t0 timeout = do
    t1 <- POSIX.getPOSIXTime
    if t1 <= t0 then
        return timeout
    else
        let elapsed = floor ((t1 - t0) * 1000) :: Integer
            timeoutValue = fromIntegral timeout :: Integer in
        if elapsed >= timeoutValue then
            return 0
        else
            return $ fromIntegral $ timeoutValue - elapsed

timeoutAdjustmentPoll :: Clock.NominalDiffTime -> Int ->
    IO (Clock.NominalDiffTime, Int)
timeoutAdjustmentPoll t0 timeout = do
    t1 <- POSIX.getPOSIXTime
    if t1 <= t0 then
        return (t1, timeout)
    else
        let elapsed = floor ((t1 - t0) * 1000) :: Integer
            timeoutValue = fromIntegral timeout :: Integer in
        if elapsed >= timeoutValue then
            return (t1, 0)
        else
            return (t1, fromIntegral $ timeoutValue - elapsed)

threadList :: Concurrent.MVar [Concurrent.MVar ()]
threadList = Unsafe.unsafePerformIO (Concurrent.newMVar [])

threadCreate :: (Int -> IO ()) -> Int -> IO ThreadId
threadCreate f threadIndex = do
    thread <- Concurrent.newEmptyMVar
    threads <- Concurrent.takeMVar threadList
    Concurrent.putMVar threadList (thread:threads)
    threadCreateFork threadIndex (f threadIndex)
        (\_ -> Concurrent.putMVar thread ())

threadCreateFork :: Int -> IO a -> (Either SomeException a -> IO ()) ->
    IO ThreadId
threadCreateFork threadIndex action afterF =
    -- similar to Concurrent.forkFinally
    Exception.mask $ \restore ->
        Concurrent.forkOn threadIndex
            (Exception.try (restore action) >>= afterF)

threadsWait :: IO ()
threadsWait = do
    threads <- Concurrent.takeMVar threadList
    case threads of
        [] ->
            return ()
        done:remaining -> do
            Concurrent.putMVar threadList remaining
            Concurrent.takeMVar done
            threadsWait

textKeyValueParse :: ByteString -> Map ByteString [ByteString]
textKeyValueParse text =
    let loop m [] = m
        loop m [v] =
            if v == ByteString.empty then
                m
            else
                error "not text_pairs"
        loop m (k:(v:l')) =
            case Map.lookup k m of
                Nothing ->
                    loop (Map.insert k [v] m) l'
                Just v' ->
                    loop (Map.insert k (v:v') m) l'
    in
    loop Map.empty (Char8.split '\0' text)

requestHttpQsParse :: ByteString -> Map ByteString [ByteString]
requestHttpQsParse = textKeyValueParse

infoKeyValueParse :: ByteString -> Map ByteString [ByteString]
infoKeyValueParse = textKeyValueParse

