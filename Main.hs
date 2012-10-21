{-# LANGUAGE RecordWildCards #-}

import Prelude hiding (id)

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (bracket_, finally)
import Control.Monad (forM_, forever, join)
import Data.Int (Int64)
import Data.Map (Map)
import Network
import System.IO

import qualified Data.Foldable  as F
import qualified Data.Map       as Map

type ClientId   = Int64
type ClientName = String

data Message = Notice String
             | MessageFrom ClientName String

data Server = Server
    { serverClients         :: TVar (Map ClientId Client)
    , serverClientsByName   :: TVar (Map ClientName Client)
    }

initServer :: IO Server
initServer =
    Server <$> newTVarIO Map.empty
           <*> newTVarIO Map.empty

data Client = Client
    { clientId       :: ClientId
    , clientName     :: ClientName
    , clientHandle   :: Handle
    , clientSendChan :: TChan Message
    , clientKicked   :: TVar (Maybe String)
    }

instance Eq Client where
    a == b = clientId a == clientId b

initClient :: ClientId -> ClientName -> Handle -> IO Client
initClient id name handle =
    Client <$> return id
           <*> return name
           <*> return handle
           <*> newTChanIO
           <*> newTVarIO Nothing

broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg =
    readTVar serverClients >>= F.mapM_ (\client -> sendMessage client msg)

sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg =
    writeTChan clientSendChan msg

kickClient :: Client -> String -> STM ()
kickClient Client{..} reason =
    writeTVar clientKicked $ Just reason

serve :: Server -> ClientId -> Handle -> IO ()
serve server@Server{..} id handle = do
    hSetNewlineMode handle universalNewlineMode
        -- Swallow carriage returns sent by telnet clients
    hSetBuffering handle LineBuffering

    hPutStrLn handle "What is your name?"
    name <- hGetLine handle
    if null name
        then hPutStrLn handle "Bye, anonymous coward"
        else do
            client <- initClient id name handle
            bracket_ (atomically $ insertClient server client)
                     (atomically $ deleteClient server client)
                     (serveLoop server client)

-- | Register the client with the server.  If another client with the same name
-- is connected already, kick it.
insertClient :: Server -> Client -> STM ()
insertClient server@Server{..}
             client@Client{..} = do
    modifyTVar' serverClients $ Map.insert clientId client
    m <- readTVar serverClientsByName
    writeTVar serverClientsByName $! Map.insert clientName client m
    case Map.lookup clientName m of
        Nothing ->
            broadcast server $ Notice $
                clientName ++ " has connected"
        Just victim -> do
            broadcast server $ Notice $
                clientName ++ " has connected (kicking previous client)"
            kickClient victim $
                "Another client by the name of " ++ clientName ++ " has connected"

-- | Unregister the client.
deleteClient :: Server -> Client -> STM ()
deleteClient server@Server{..}
             client@Client{..} = do
    modifyTVar' serverClients $ Map.delete clientId
    m <- readTVar serverClientsByName
    case Map.lookup clientName m of
        -- Make sure the client in the map is actually me, and not another
        -- client who took my name.
        Just c | c == client -> do
            broadcast server $ Notice $ clientName ++ " has disconnected"
            writeTVar serverClientsByName $! Map.delete clientName m
        _ ->
            return ()

-- | Handle client I/O.
serveLoop :: Server -> Client -> IO ()
serveLoop server@Server{..}
          client@Client{..} = do
    done <- newEmptyMVar
    let spawnWorker io = forkIO (io `finally` tryPutMVar done ())

    recv_tid <- spawnWorker $ forever $ do
        msg <- hGetLine clientHandle
        atomically $ broadcast server $ MessageFrom clientName msg

    send_tid <- spawnWorker $
        let loop = join $ atomically $ do
                k <- readTVar clientKicked
                case k of
                    Just reason -> return $
                        hPutStrLn clientHandle $ "You have been kicked: " ++ reason
                    Nothing -> do
                        msg <- readTChan clientSendChan
                        return $ do
                            handleMessage client msg
                            loop
         in loop

    takeMVar done
    mapM_ killThread [recv_tid, send_tid]

handleMessage :: Client -> Message -> IO ()
handleMessage Client{..} message =
    hPutStrLn clientHandle $
        case message of
            Notice msg           -> "* " ++ msg
            MessageFrom name msg -> "<" ++ name ++ ">: " ++ msg

main :: IO ()
main = do
    server <- initServer
    sock <- listenOn $ PortNumber 1234
    putStrLn "Listening on port 1234"
    forM_ [1..] $ \id -> do
        (handle, host, port) <- accept sock
        putStrLn $ "Accepted connection from " ++ host ++ ":" ++ show port
        forkIO $ serve server id handle `finally` hClose handle
