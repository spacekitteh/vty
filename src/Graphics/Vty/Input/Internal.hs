{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
-- Much of the input layer used to be in a single module with a few large functions. I've refactored
-- the input layer into many small bits. Now, I think, the code is a better position to be
-- incrementally refined. Still, until there are proper tests in place much of the refinement must
-- wait.
module Graphics.Vty.Input.Internal where

import Graphics.Vty.Input.Events

import Codec.Binary.UTF8.Generic (decode)
import Control.Applicative
import Control.Concurrent
import Control.Lens
import Control.Exception (try, IOException)
import Control.Monad (when, void, mzero)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.State (StateT(..))
import Control.Monad.Trans.Reader (ReaderT(..))

import Data.Char
import Data.Default
import Data.IORef
import Data.List( inits )
import qualified Data.Map as M( fromList, lookup )
import Data.Maybe ( mapMaybe )
import qualified Data.Set as S( fromList, member )
import Data.Word

import Foreign ( alloca, poke, peek, peekArray, Ptr )
import Foreign.C.Types (CInt(..))

import System.Posix.IO ( fdReadBuf
                       , setFdOption
                       , FdOption(..)
                       )
import System.Posix.Types (Fd(..))

data Config = Config
    { controlSeqPeriod :: Int -- ^ default control sequence period is 10000 microseconds.  Which is
                              -- assumed to be well above the sampling rate required to detect a 
                              -- keyup for a person typing 200 wpm.
    , metaComboPeriod :: Int -- ^ The default meta combo period is 100000 microseconds.
    } deriving (Show, Eq)

instance Default Config where
    def = Config
        { controlSeqPeriod = 10000
        , metaComboPeriod = 100000
        }

data Input = Input
    { -- | Channel of events direct from input processing. Unlike 'next_event' this will not refresh
      -- the display if the next event is an 'EvResize'.
      _event_channel  :: Chan Event
      -- | Shuts down the input processing. This should return the terminal input state to before
      -- the input initialized.
    , shutdown_input :: IO ()
      -- | Changes to this value are reflected after the next event.
    , _config_ref :: IORef Config
      -- | File descriptor used for input.
    , _input_fd :: Fd
    }

makeLenses ''Input

data KClass
    = Valid Key [Modifier] [Char]
    | Invalid
    | Prefix
    deriving(Show, Eq)

data InputBuffer = InputBuffer
    { _ptr :: Ptr Word8
    , _size :: Int
    }

makeLenses ''InputBuffer

data InputState = InputState
    { _unprocessed_bytes :: String
    , _applied_config :: Config
    , _input_buffer :: InputBuffer
    , _stop_request_ref :: IORef Bool
    , _classifier :: String -> KClass
    }

makeLenses ''InputState

type InputM a = StateT InputState (ReaderT Input IO) a

loop_input_processor :: InputM ()
loop_input_processor = do
    read_from_device >>= add_bytes_to_process
    _ <- many $ parse_event >>= emit
    drop_invalid
    stop_requested <|> loop_input_processor

add_bytes_to_process :: String -> InputM ()
add_bytes_to_process block = unprocessed_bytes <>= block

emit :: Event -> InputM ()
emit event = view event_channel >>= liftIO . flip writeChan event

read_from_device :: InputM String
read_from_device = do
    new_config <- view config_ref >>= liftIO . readIORef
    old_config <- use applied_config
    fd <- view input_fd
    when (new_config /= old_config) $ do
        let vtime = min 255 $ metaComboPeriod new_config `div` 100000
        liftIO $ set_term_timing fd 0 vtime
        applied_config .= new_config
    buffer_ptr <- use $ input_buffer.ptr
    max_bytes  <- use $ input_buffer.size
    liftIO $ do
        bytes_read <- fdReadBuf fd buffer_ptr (fromIntegral max_bytes)
        fmap (map $ chr . fromIntegral) $ peekArray (fromIntegral bytes_read) buffer_ptr

parse_event :: InputM Event
parse_event = do
    c <- use classifier
    b <- use unprocessed_bytes
    case c b of
        Valid k m remaining -> do
            unprocessed_bytes .= remaining
            return $ EvKey k m
        _                   -> mzero 

drop_invalid :: InputM ()
drop_invalid = do
    c <- use classifier
    b <- use unprocessed_bytes
    when (c b == Invalid) $ unprocessed_bytes .= []

stop_requested :: InputM ()
stop_requested = do
    True <- (liftIO . readIORef) =<< use stop_request_ref
    return ()

#if 0
data InputChunk
    = StopInput
    | InputChunk String
    | InputBreak

-- The input uses two magic character:
--
--  * '\xFFFD' for "stop processing"
--  * '\xFFFE' for "previous input chunk is complete" Which is used to differentiate a single ESC
--  from using ESC as meta or to indicate a control sequence.
--
-- | Read 'InputChunk' from the input channel, parse into one or more 'Event's, output to event
-- channel.
--
-- Each input chunk is added to the current chunk being processed. The current chunk is processed
-- with the provided function to determine events.
inputToEventThread :: (String -> KClass) -> Chan InputChunk -> Chan Event -> IO ()
inputToEventThread classifier inputChannel eventChannel = loop []
    where
        loop current =
            c <- readChan inputChannel
            case c of
                StopInput        -> return ()
                -- the prefix is missing bytes and there are bytes available.
                InputChunk chunk -> parse_until_prefix (current ++ chunk)
                                    >>= loop
                -- if there are bytes remaining after all events are parsed then the spacing after 
                InputBreak       -> parse_until_prefix current
                                    >> loop []
        parse_until_prefix current = case classifier current of
            Prefix  -> return current
            Invalid -> return []
            Valid k m remaining -> do
                writeChan eventChannel (EvKey k m)
                parse_until_prefix remaining

            Prefix       -> do
                c <- readChan inputChannel
                case c of
                    StopInput             -> return ()
                    -- the prefix is missing bytes and there are bytes available.
                    InputChunk chunk      -> loop (current ++ chunk)
                    -- the prefix is a control sequence that is unknown. Drop and move on to the next
                    MetaShiftChunk chunk  -> loop chunk 
            -- drop the entirety of invalid sequences. Probably better to drop only the first
            -- character. However, the read behavior of terminals (a single read corresponds to the
            -- bytes of a single event) might mean this results in quicker error recovery from a
            -- users perspective.
            Invalid      -> do
                c <- readChan inputChannel
                case c of
                    EndChunk         -> return ()
                    InputChunk chunk -> loop chunk
            Valid k m remaining -> writeChan eventChannel (EvKey k m) >> loop remaining
#endif

-- This makes a kind of tri. Has space efficiency issues with large input blocks.
-- Likely building a parser and just applying that would be better.
-- I did not write this so I might just rewrite it for better understanding. Not the best of
-- reasons...
-- TODO: measure and rewrite if required.
compile :: ClassifyTable -> [Char] -> KClass
compile table = cl' where
    -- take all prefixes and create a set of these
    prefix_set = S.fromList $ concatMap (init . inits . fst) $ table
    -- create a map from strings to event
    event_for_input = flip M.lookup (M.fromList table)
    cl' [] = Prefix
    cl' input_block = case S.member input_block prefix_set of
            True -> Prefix
            -- if the input_block is exactly what is expected for an event then consume the whole
            -- block and return the event
            False -> case event_for_input input_block of
                Just (EvKey k m) -> Valid k m []
                -- look up progressively large prefixes of the input block until an event is found
                -- H: There will always be one match. The prefix_set contains, by definition, all
                -- prefixes of an event. 
                Nothing -> 
                    let input_prefixes = init $ inits input_block
                    in case mapMaybe (\s -> (,) s `fmap` event_for_input s) input_prefixes of
                        (s,EvKey k m) : _ -> Valid k m (drop (length s) input_block)
                        -- neither a prefix or a full event. Might be interesting to log.
                        [] -> Invalid

classify, classifyTab :: ClassifyTable -> [Char] -> KClass

-- As soon as
classify _table s@(c:_) | ord c >= 0xC2
    = if utf8Length (ord c) > length s then Prefix else classifyUtf8 s -- beginning of an utf8 sequence
classify table other
    = classifyTab table other

classifyUtf8 :: [Char] -> KClass
classifyUtf8 s = case decode ((map (fromIntegral . ord) s) :: [Word8]) of
    Just (unicodeChar, _) -> Valid (KChar unicodeChar) [] []
    _ -> Invalid -- something bad happened; just ignore and continue.

classifyTab table = compile table

first :: (a -> b) -> (a,c) -> (b,c)
first f (x,y) = (f x, y)

utf8Length :: (Num t, Ord a, Num a) => a -> t
utf8Length c
    | c < 0x80 = 1
    | c < 0xE0 = 2
    | c < 0xF0 = 3
    | otherwise = 4

-- I gave a quick shot at replacing this code with some that removed the "odd" bits. The "obvious"
-- changes all failed testing. This is timing sensitive code.
-- I now think I can replace this wil code that makes the time sensitivity explicit. I am waiting
-- until I have a good set of characterization tests to verify the input to event timing is still
-- correct for a user. I estimate the current tests cover ~70% of the required cases.
--
-- This is an example of an algorithm where code coverage could be high, even 100%, but the
-- algorithm still under tested. I should collect more of these examples...
initInputForFd :: IORef Config -> ClassifyTable -> Fd -> IO (Chan Event, IO ())
initInputForFd config_ref classify_table input_fd = do
    eventChannel <- newChan
#if 0
    should_exit <- newIORef False
    let -- initial state: read bytes until a ESC. Emit bytes. Go to possible-control-seq state.
        -- possible-control-seq: read available bytes.
        --  If time is < controlSeqPeriod then emit as chunk with ESC prefix.
        --  If time is < metaComboPeriod then emit chunk with Meta shift.
        --  If time is > metaComboPeriod then emit ESC event then chunk of bytes.
        inputThread :: IO ()
        inputThread = do
            let k = 1024
            _ <- allocaArray k $ \(input_buffer :: Ptr Word8) -> do
                let loop = do
                        setFdOption input_fd NonBlockingRead False
                        threadWaitRead input_fd
                        setFdOption input_fd NonBlockingRead True
                        _ <- try readAll :: IO (Either IOException ())
                        when (escDelay == 0) finishAtomicInput
                        loop
                    readAll = do
                        poke input_buffer 0
                        bytes_read <- fdReadBuf input_fd input_buffer 1
                        input_char <- fmap (chr . fromIntegral) $ peek input_buffer
                        when (bytes_read > 0) $ do
                            _ <- tryPutMVar hadInput () -- signal input
                            writeChan inputChannel input_char
                            readAll
                loop
            return ()
        -- If there is no input for some time, this thread puts '\xFFFE' in the
        -- inputChannel.
        noInputThread :: IO ()
        noInputThread = when (escDelay > 0) loop
            where loop = do
                    takeMVar hadInput -- wait for some input
                    threadDelay escDelay -- microseconds
                    hadNoInput <- isEmptyMVar hadInput -- no input yet?
                    -- TODO(corey): there is a race between here and the inputThread.
                    when hadNoInput finishAtomicInput
                    loop
        classifier = classify classify_table
    eventThreadId <- forkIO $ void $ inputToEventThread classifier inputChannel eventChannel
    inputThreadId <- forkIO $ input_thread
    noInputThreadId <- forkIO $ noInputThread
    -- TODO(corey): killThread is a bit risky for my tastes.
    -- H - somewhat mitigated by sending a magic terminate character?
    let shutdown_event_processing = do
            killThread eventThreadId
            killThread inputThreadId
#endif
    let shutdown_event_processing = return ()

    return (eventChannel, shutdown_event_processing)

foreign import ccall "vty_set_term_timing" set_term_timing :: Fd -> Int -> Int -> IO ()
