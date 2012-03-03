{-# LANGUAGE CPP, RecordWildCards #-}

import Prelude hiding (id)

import Control.Applicative
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (bracket, finally)
import Control.Monad (forM_, forever)
import Data.Int (Int64)
import Data.Map (Map)
import Network
import System.IO

import qualified Data.Foldable  as F
import qualified Data.Map       as Map

#if !MIN_VERSION_stm(2,3,0)
modifyTVar' :: TVar a -> (a -> a) -> STM ()
modifyTVar' var f = do
    x <- readTVar var
    writeTVar var $! f x
#endif

type ClientId   = Int64
type ClientName = String

data Message = Notice String
             | MessageFrom ClientName String

data Server
    = Server
        { serverClients         :: TVar (Map ClientId Client)
        , serverClientsByName   :: TVar (Map ClientName Client)
        }

initServer :: IO Server
initServer =
    Server <$> newTVarIO Map.empty
           <*> newTVarIO Map.empty

data Client
    = Client
        { clientId       :: ClientId
        , clientName     :: ClientName
        , clientHandle   :: Handle
        , clientSendChan :: TChan Message
        , clientKicked   :: TVar (Maybe String)
        }

instance Eq Client where
    Client{clientId = a} == Client{clientId = b}
        = a == b

initClient :: ClientId -> ClientName -> Handle -> IO Client
initClient id name handle  =
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
kickClient client@Client{..} reason =
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
        else bracket (insertClient server id name handle)
                     (deleteClient server)
                     (serveLoop server)

-- | Register the client with the server.  If another client with the same name
-- is connected already, kick it.
insertClient :: Server -> ClientId -> ClientName -> Handle -> IO Client
insertClient server@Server{..} id name handle = do
    client <- initClient id name handle

    atomically $ do
        modifyTVar' serverClients $ Map.insert id client

        m <- readTVar serverClientsByName
        writeTVar serverClientsByName $! Map.insert name client m
        case Map.lookup name m of
            Nothing ->
                broadcast server $ Notice $
                    name ++ " has connected"
            Just victim -> do
                broadcast server $ Notice $
                    name ++ " has connected (kicking previous client)"
                kickClient client $
                    "Another client by the name of " ++ name ++ " has connected"

    return client

deleteClient :: Server -> Client -> IO ()
deleteClient Server{..} Client{..} =
    atomically $ do
        modifyTVar' serverClients $ Map.delete clientId

serveLoop :: Server -> Client -> IO ()
serveLoop server@Server{..}
          client@Client{..} = undefined

main :: IO ()
main = do
    server <- initServer
    sock <- listenOn $ PortNumber 1234
    putStrLn "Listening on port 1234"
    forM_ [1..] $ \id -> do
        (handle, host, port) <- accept sock
        putStrLn $ "Accepted connection from " ++ host ++ ":" ++ show port
        forkIO $ serve server id handle `finally` hClose handle
