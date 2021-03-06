{-# LANGUAGE GeneralizedNewtypeDeriving, PatternGuards, OverloadedStrings,
  DeriveDataTypeable, ExistentialQuantification, FlexibleInstances,
  ScopedTypeVariables, GeneralizedNewtypeDeriving, IncoherentInstances,
  DeriveGeneric #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Text.CSL.Reference
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Andrea Rossato <andrea.rossato@unitn.it>
-- Stability   :  unstable
-- Portability :  unportable
--
-- The Reference type
--
-----------------------------------------------------------------------------

module Text.CSL.Reference where

import Data.List  ( elemIndex, isPrefixOf, intercalate )
import Data.Maybe ( fromMaybe             )
import Data.Generics hiding (Generic)
import GHC.Generics (Generic)
import Data.Monoid
import Data.Aeson hiding (Value)
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser, Pair)
import Control.Applicative ((<$>), (<*>), (<|>), pure)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Char (toLower, isUpper, isLower, isDigit)
import Text.CSL.Style hiding (Number)
import Text.CSL.Util (parseString, parseInt, parseBool, safeRead, readNum,
                      inlinesToString, capitalize, camelize)
import Text.Pandoc (Inline(Str,Space))
import Data.List.Split (wordsBy)
import Data.String

newtype Literal = Literal { unLiteral :: String }
  deriving ( Show, Read, Eq, Data, Typeable, Monoid, Generic )

instance FromJSON Literal where
  parseJSON v             = Literal `fmap` parseString v

instance ToJSON Literal where
  toJSON = toJSON . unLiteral

instance IsString Literal where
  fromString = Literal

-- | An existential type to wrap the different types a 'Reference' is
-- made of. This way we can create a map to make queries easier.
data Value = forall a . Data a => Value a

-- for debuging
instance Show Value where
    show (Value a) = gshow a

type ReferenceMap = [(String, Value)]

mkRefMap :: Data a => a -> ReferenceMap
mkRefMap a = zip fields (gmapQ Value a)
    where fields = map formatField . constrFields . toConstr $ a

formatField :: String -> String
formatField = foldr f [] . g
    where f  x xs  = if isUpper x then '-' : toLower x : xs else x : xs
          g (x:xs) = toLower x : xs
          g     [] = []

fromValue :: Data a => Value -> Maybe a
fromValue (Value a) = cast a

isValueSet :: Value -> Bool
isValueSet val
    | Just v <- fromValue val :: Maybe Literal   = v /= mempty
    | Just v <- fromValue val :: Maybe String    = v /= mempty
    | Just v <- fromValue val :: Maybe Formatted = v /= mempty
    | Just v <- fromValue val :: Maybe [Agent]   = v /= []
    | Just v <- fromValue val :: Maybe [RefDate] = v /= []
    | Just v <- fromValue val :: Maybe Int       = v /= 0
    | Just v <- fromValue val :: Maybe CNum      = v /= 0
    | Just _ <- fromValue val :: Maybe Empty     = True
    | otherwise = False

data Empty = Empty deriving ( Typeable, Data, Generic )

data Agent
    = Agent { givenName       :: [Formatted]
            , droppingPart    ::  Formatted
            , nonDroppingPart ::  Formatted
            , familyName      ::  Formatted
            , nameSuffix      ::  Formatted
            , literal         ::  Formatted
            , commaSuffix     ::  Bool
            }
      deriving ( Show, Read, Eq, Typeable, Data, Generic )

instance FromJSON Agent where
  parseJSON (Object v) = Agent <$>
              (v .: "given" <|> ((map Formatted . wordsBy (== Space) . unFormatted) <$> v .: "given") <|> pure []) <*>
              v .:?  "dropping-particle" .!= mempty <*>
              v .:? "non-dropping-particle" .!= mempty <*>
              v .:? "family" .!= mempty <*>
              v .:? "suffix" .!= mempty <*>
              v .:? "literal" .!= mempty <*>
              v .:? "comma-suffix" .!= False
  parseJSON _ = fail "Could not parse Agent"

instance ToJSON Agent where
  toJSON agent = object' $ [
      "given" .= Formatted (intercalate [Space] $ map unFormatted
                                                $ givenName agent)
    , "dropping-particle" .= droppingPart agent
    , "non-dropping-particle" .= nonDroppingPart agent
    , "family" .= familyName agent
    , "suffix" .= nameSuffix agent
    , "literal" .= literal agent
    ] ++ ["comma-suffix" .= commaSuffix agent | nameSuffix agent /= mempty]

instance FromJSON [Agent] where
  parseJSON (Array xs) = mapM parseJSON $ V.toList xs
  parseJSON (Object v) = (:[]) `fmap` parseJSON (Object v)
  parseJSON _ = fail "Could not parse [Agent]"

-- instance ToJSON [Agent] where
--  toJSON xs  = Array (V.fromList $ map toJSON xs)

data RefDate =
    RefDate { year   :: Literal
            , month  :: Literal
            , season :: Literal
            , day    :: Literal
            , other  :: Literal
            , circa  :: Bool
            } deriving ( Show, Read, Eq, Typeable, Data, Generic )

instance FromJSON RefDate where
  parseJSON (Array v) =
     case fromJSON (Array v) of
          Success [y]     -> RefDate <$> parseJSON y <*>
                    pure "" <*> pure "" <*> pure "" <*> pure "" <*> pure False
          Success [y,m]   -> RefDate <$> parseJSON y <*> parseJSON m <*>
                    pure "" <*> pure "" <*> pure "" <*> pure False
          Success [y,m,d] -> RefDate <$> parseJSON y <*> parseJSON m <*>
                    pure "" <*> parseJSON d <*> pure "" <*> pure False
          Error e         -> fail $ "Could not parse RefDate: " ++ e
          _               -> fail "Could not parse RefDate"
  parseJSON (Object v) = RefDate <$>
              v .:? "year" .!= "" <*>
              v .:? "month" .!= "" <*>
              v .:? "season" .!= "" <*>
              v .:? "day" .!= "" <*>
              v .:? "other" .!= "" <*>
              ((v .: "circa" >>= parseBool) <|> pure False)
  parseJSON _ = fail "Could not parse RefDate"

{-
instance ToJSON RefDate where
  toJSON refdate = object' $ [
      "year" .= year refdate
    , "month" .= month refdate
    , "season" .= season refdate
    , "day" .= day refdate
    , "other" .= other refdate ] ++
    [ "circa" .= circa refdate | circa refdate ]
-}

instance FromJSON [RefDate] where
  parseJSON (Array xs) = mapM parseJSON $ V.toList xs
  parseJSON (Object v) = do
    dateParts <- v .:? "date-parts"
    circa' <- (v .: "circa" >>= parseBool) <|> pure False
    case dateParts of
         Just (Array xs) -> mapM (fmap (setCirca circa') . parseJSON)
                            $ V.toList xs
         _               -> (:[]) `fmap` parseJSON (Object v)
  parseJSON x          = parseJSON x >>= mkRefDate

toDatePart :: RefDate -> [Int]
toDatePart refdate =
    case (safeRead (unLiteral $ year refdate),
          safeRead (unLiteral $ month refdate),
          safeRead (unLiteral $ day refdate)) of
         (Just (y :: Int), Just (m :: Int), Just (d :: Int))
                                     -> [y, m, d]
         (Just y, Just m, Nothing)   -> [y, m]
         (Just y, Nothing, Nothing)  -> [y]
         _                           -> []

instance ToJSON [RefDate] where
  toJSON [] = Array V.empty
  toJSON xs = object' $
    case filter (not . null) (map toDatePart xs) of
         []  -> ["literal" .= intercalate "; " (map (unLiteral . other) xs)]
         dps -> (["date-parts" .= dps ] ++
                 ["circa" .= (1 :: Int) | or (map circa xs)] ++
                 ["season" .= s | s <- map season xs, s /= mempty])

-- instance ToJSON [RefDate]
-- toJSON xs  = Array (V.fromList $ map toJSON xs)

setCirca :: Bool -> RefDate -> RefDate
setCirca circa' rd = rd{ circa = circa' }

mkRefDate :: Literal -> Parser [RefDate]
mkRefDate z@(Literal xs)
  | all isDigit xs = return [RefDate z mempty mempty mempty mempty False]
  | otherwise      = return [RefDate mempty mempty mempty mempty z False]

data RefType
    = NoType
    | Article
    | ArticleMagazine
    | ArticleNewspaper
    | ArticleJournal
    | Bill
    | Book
    | Broadcast
    | Chapter
    | Dataset
    | Entry
    | EntryDictionary
    | EntryEncyclopedia
    | Figure
    | Graphic
    | Interview
    | Legislation
    | LegalCase
    | Manuscript
    | Map
    | MotionPicture
    | MusicalScore
    | Pamphlet
    | PaperConference
    | Patent
    | Post
    | PostWeblog
    | PersonalCommunication
    | Report
    | Review
    | ReviewBook
    | Song
    | Speech
    | Thesis
    | Treaty
    | Webpage
      deriving ( Read, Eq, Typeable, Data, Generic )

instance Show RefType where
    show MotionPicture = "motion_picture"
    show MusicalScore = "musical_score"
    show PersonalCommunication = "personal_communication"
    show LegalCase = "legal_case"
    show x = map toLower . formatField . showConstr . toConstr $ x

instance FromJSON RefType where
  parseJSON (String t) = safeRead (capitalize . camelize . T.unpack $ t)
  parseJSON v@(Array _) = fmap (capitalize . camelize . inlinesToString)
    (parseJSON v) >>= safeRead
  parseJSON _ = fail "Could not parse RefType"

instance ToJSON RefType where
  toJSON reftype = toJSON (uncamelize $ uncapitalize $ show reftype)
   where uncamelize [] = []
         uncamelize (x:y:zs)
          | isLower x && isUpper y = x:'-':toLower y:uncamelize zs
         uncamelize (x:xs) = x : uncamelize xs
         uncapitalize (x:xs) = toLower x : xs
         uncapitalize []     = []

newtype CNum = CNum { unCNum :: Int } deriving ( Show, Read, Eq, Num, Typeable, Data, Generic )

instance FromJSON CNum where
  parseJSON x = CNum `fmap` parseInt x

instance ToJSON CNum where
  toJSON (CNum n) = toJSON n

-- | The 'Reference' record.
data Reference =
    Reference
    { refId               :: Literal
    , refType             :: RefType

    , author              :: [Agent]
    , editor              :: [Agent]
    , translator          :: [Agent]
    , recipient           :: [Agent]
    , interviewer         :: [Agent]
    , composer            :: [Agent]
    , director            :: [Agent]
    , illustrator         :: [Agent]
    , originalAuthor      :: [Agent]
    , containerAuthor     :: [Agent]
    , collectionEditor    :: [Agent]
    , editorialDirector   :: [Agent]
    , reviewedAuthor      :: [Agent]

    , issued              :: [RefDate]
    , eventDate           :: [RefDate]
    , accessed            :: [RefDate]
    , container           :: [RefDate]
    , originalDate        :: [RefDate]
    , submitted           :: [RefDate]

    , title               :: Formatted
    , titleShort          :: Formatted
    , reviewedTitle       :: Formatted
    , containerTitle      :: Formatted
    , volumeTitle         :: Formatted
    , collectionTitle     :: Formatted
    , containerTitleShort :: Formatted
    , collectionNumber    :: Formatted --Int
    , originalTitle       :: Formatted
    , publisher           :: Formatted
    , originalPublisher   :: Formatted
    , publisherPlace      :: Formatted
    , originalPublisherPlace :: Formatted
    , authority           :: Formatted
    , jurisdiction        :: Formatted
    , archive             :: Formatted
    , archivePlace        :: Formatted
    , archiveLocation     :: Formatted
    , event               :: Formatted
    , eventPlace          :: Formatted
    , page                :: Formatted
    , pageFirst           :: Formatted
    , numberOfPages       :: Formatted
    , version             :: Formatted
    , volume              :: Formatted
    , numberOfVolumes     :: Formatted --Int
    , issue               :: Formatted
    , chapterNumber       :: Formatted
    , medium              :: Formatted
    , status              :: Formatted
    , edition             :: Formatted
    , section             :: Formatted
    , source              :: Formatted
    , genre               :: Formatted
    , note                :: Formatted
    , annote              :: Formatted
    , abstract            :: Formatted
    , keyword             :: Formatted
    , number              :: Formatted
    , references          :: Formatted
    , url                 :: Literal
    , doi                 :: Literal
    , isbn                :: Literal
    , issn                :: Literal
    , pmcid               :: Literal
    , pmid                :: Literal
    , callNumber          :: Literal
    , dimensions          :: Literal
    , scale               :: Literal
    , categories          :: [Literal]
    , language            :: Literal

    , citationNumber           :: CNum
    , firstReferenceNoteNumber :: Int
    , citationLabel            :: Literal
    } deriving ( Eq, Show, Read, Typeable, Data, Generic )

instance FromJSON Reference where
  parseJSON (Object v) = Reference <$>
       v .:? "id" .!= "" <*>
       v .:? "type" .!= NoType <*>
       v .:? "author" .!= [] <*>
       v .:? "editor" .!= [] <*>
       v .:? "translator" .!= [] <*>
       v .:? "recipient" .!= [] <*>
       v .:? "interviewer" .!= [] <*>
       v .:? "composer" .!= [] <*>
       v .:? "director" .!= [] <*>
       v .:? "illustrator" .!= [] <*>
       v .:? "original-author" .!= [] <*>
       v .:? "container-author" .!= [] <*>
       v .:? "collection-editor" .!= [] <*>
       v .:? "editorial-director" .!= [] <*>
       v .:? "reviewed-author" .!= [] <*>
       v .:? "issued" .!= [] <*>
       v .:? "event-date" .!= [] <*>
       v .:? "accessed" .!= [] <*>
       v .:? "container" .!= [] <*>
       v .:? "original-date" .!= [] <*>
       v .:? "submitted" .!= [] <*>
       v .:? "title" .!= mempty <*>
       (v .: "shortTitle" <|> (v .:? "title-short" .!= mempty)) <*>
       v .:? "reviewed-title" .!= mempty <*>
       v .:? "container-title" .!= mempty <*>
       v .:? "volume-title" .!= mempty <*>
       v .:? "collection-title" .!= mempty <*>
       (v .: "journalAbbreviation" <|> v .:? "container-title-short" .!= mempty) <*>
       v .:? "collection-number" .!= mempty <*>
       v .:? "original-title" .!= mempty <*>
       v .:? "publisher" .!= mempty <*>
       v .:? "original-publisher" .!= mempty <*>
       v .:? "publisher-place" .!= mempty <*>
       v .:? "original-publisher-place" .!= mempty <*>
       v .:? "authority" .!= mempty <*>
       v .:? "jurisdiction" .!= mempty <*>
       v .:? "archive" .!= mempty <*>
       v .:? "archive-place" .!= mempty <*>
       v .:? "archive_location" .!= mempty <*>
       v .:? "event" .!= mempty <*>
       v .:? "event-place" .!= mempty <*>
       v .:? "page" .!= mempty <*>
       v .:? "page-first" .!= mempty <*>
       v .:? "number-of-pages" .!= mempty <*>
       v .:? "version" .!= mempty <*>
       v .:? "volume" .!= mempty <*>
       v .:? "number-of-volumes" .!= mempty <*>
       v .:? "issue" .!= mempty <*>
       v .:? "chapter-number" .!= mempty <*>
       v .:? "medium" .!= mempty <*>
       v .:? "status" .!= mempty <*>
       v .:? "edition" .!= mempty <*>
       v .:? "section" .!= mempty <*>
       v .:? "source" .!= mempty <*>
       v .:? "genre" .!= mempty <*>
       v .:? "note" .!= mempty <*>
       v .:? "annote" .!= mempty <*>
       v .:? "abstract" .!= mempty <*>
       v .:? "keyword" .!= mempty <*>
       v .:? "number" .!= mempty <*>
       v .:? "references" .!= mempty <*>
       v .:? "URL" .!= "" <*>
       v .:? "DOI" .!= "" <*>
       v .:? "ISBN" .!= "" <*>
       v .:? "ISSN" .!= "" <*>
       v .:? "PMCID" .!= "" <*>
       v .:? "PMID" .!= "" <*>
       v .:? "call-number" .!= "" <*>
       v .:? "dimensions" .!= "" <*>
       v .:? "scale" .!= "" <*>
       v .:? "categories" .!= [] <*>
       v .:? "language" .!= "" <*>
       v .:? "citation-number" .!= CNum 0 <*>
       ((v .: "first-reference-note-number" >>= parseInt) <|> return 1) <*>
       v .:? "citation-label" .!= ""
  parseJSON _ = fail "Could not parse Reference"

instance ToJSON Reference where
  toJSON ref = object' [
      "id" .= refId ref
    , "type" .= refType ref
    , "author" .= author ref
    , "editor" .= editor ref
    , "translator" .= translator ref
    , "recipient" .= recipient ref
    , "interviewer" .= interviewer ref
    , "composer" .= composer ref
    , "director" .= director ref
    , "illustrator" .= illustrator ref
    , "original-author" .= originalAuthor ref
    , "container-author" .= containerAuthor ref
    , "collection-editor" .= collectionEditor ref
    , "editorial-director" .= editorialDirector ref
    , "reviewed-author" .= reviewedAuthor ref
    , "issued" .= issued ref
    , "event-date" .= eventDate ref
    , "accessed" .= accessed ref
    , "container" .= container ref
    , "original-date" .= originalDate ref
    , "submitted" .= submitted ref
    , "title" .= title ref
    , "title-short" .= titleShort ref
    , "reviewed-title" .= reviewedTitle ref
    , "container-title" .= containerTitle ref
    , "volume-title" .= volumeTitle ref
    , "collection-title" .= collectionTitle ref
    , "container-title-short" .= containerTitleShort ref
    , "collection-number" .= collectionNumber ref
    , "original-title" .= originalTitle ref
    , "publisher" .= publisher ref
    , "original-publisher" .= originalPublisher ref
    , "publisher-place" .= publisherPlace ref
    , "original-publisher-place" .= originalPublisherPlace ref
    , "authority" .= authority ref
    , "jurisdiction" .= jurisdiction ref
    , "archive" .= archive ref
    , "archive-place" .= archivePlace ref
    , "archive_location" .= archiveLocation ref
    , "event" .= event ref
    , "event-place" .= eventPlace ref
    , "page" .= page ref
    , "page-first" .= pageFirst ref
    , "number-of-pages" .= numberOfPages ref
    , "version" .= version ref
    , "volume" .= volume ref
    , "number-of-volumes" .= numberOfVolumes ref
    , "issue" .= issue ref
    , "chapter-number" .= chapterNumber ref
    , "medium" .= medium ref
    , "status" .= status ref
    , "edition" .= edition ref
    , "section" .= section ref
    , "source" .= source ref
    , "genre" .= genre ref
    , "note" .= note ref
    , "annote" .= annote ref
    , "abstract" .= abstract ref
    , "keyword" .= keyword ref
    , "number" .= number ref
    , "references" .= references ref
    , "URL" .= url ref
    , "DOI" .= doi ref
    , "ISBN" .= isbn ref
    , "ISSN" .= issn ref
    , "PMCID" .= pmcid ref
    , "PMID" .= pmid ref
    , "call-number" .= callNumber ref
    , "dimensions" .= dimensions ref
    , "scale" .= scale ref
    , "categories" .= categories ref
    , "language" .= language ref
    , "citation-number" .= citationNumber ref
    , "first-reference-note-number" .= firstReferenceNoteNumber ref
    , "citation-label" .= citationLabel ref
    ]

emptyReference :: Reference
emptyReference =
    Reference
    { refId               = mempty
    , refType             = NoType

    , author              = []
    , editor              = []
    , translator          = []
    , recipient           = []
    , interviewer         = []
    , composer            = []
    , director            = []
    , illustrator         = []
    , originalAuthor      = []
    , containerAuthor     = []
    , collectionEditor    = []
    , editorialDirector   = []
    , reviewedAuthor      = []

    , issued              = []
    , eventDate           = []
    , accessed            = []
    , container           = []
    , originalDate        = []
    , submitted           = []

    , title               = mempty
    , titleShort          = mempty
    , reviewedTitle       = mempty
    , containerTitle      = mempty
    , volumeTitle         = mempty
    , collectionTitle     = mempty
    , containerTitleShort = mempty
    , collectionNumber    = mempty
    , originalTitle       = mempty
    , publisher           = mempty
    , originalPublisher   = mempty
    , publisherPlace      = mempty
    , originalPublisherPlace = mempty
    , authority           = mempty
    , jurisdiction        = mempty
    , archive             = mempty
    , archivePlace        = mempty
    , archiveLocation     = mempty
    , event               = mempty
    , eventPlace          = mempty
    , page                = mempty
    , pageFirst           = mempty
    , numberOfPages       = mempty
    , version             = mempty
    , volume              = mempty
    , numberOfVolumes     = mempty
    , issue               = mempty
    , chapterNumber       = mempty
    , medium              = mempty
    , status              = mempty
    , edition             = mempty
    , section             = mempty
    , source              = mempty
    , genre               = mempty
    , note                = mempty
    , annote              = mempty
    , abstract            = mempty
    , keyword             = mempty
    , number              = mempty
    , references          = mempty
    , url                 = mempty
    , doi                 = mempty
    , isbn                = mempty
    , issn                = mempty
    , pmcid               = mempty
    , pmid                = mempty
    , callNumber          = mempty
    , dimensions          = mempty
    , scale               = mempty
    , categories          = mempty
    , language            = mempty

    , citationNumber           = CNum 0
    , firstReferenceNoteNumber = 0
    , citationLabel            = mempty
    }

numericVars :: [String]
numericVars = [ "edition", "volume", "number-of-volumes", "number", "issue", "citation-number"
              , "chapter-number", "collection-number", "number-of-pages"]

parseLocator :: String -> (String, String)
parseLocator s
    | "b"    `isPrefixOf` formatField s = mk "book"
    | "ch"   `isPrefixOf` formatField s = mk "chapter"
    | "co"   `isPrefixOf` formatField s = mk "column"
    | "fi"   `isPrefixOf` formatField s = mk "figure"
    | "fo"   `isPrefixOf` formatField s = mk "folio"
    | "i"    `isPrefixOf` formatField s = mk "issue"
    | "l"    `isPrefixOf` formatField s = mk "line"
    | "n"    `isPrefixOf` formatField s = mk "note"
    | "o"    `isPrefixOf` formatField s = mk "opus"
    | "para" `isPrefixOf` formatField s = mk "paragraph"
    | "part" `isPrefixOf` formatField s = mk "part"
    | "p"    `isPrefixOf` formatField s = mk "page"
    | "sec"  `isPrefixOf` formatField s = mk "section"
    | "sub"  `isPrefixOf` formatField s = mk "sub verbo"
    | "ve"   `isPrefixOf` formatField s = mk "verse"
    | "v"    `isPrefixOf` formatField s = mk "volume"
    | otherwise                         =    ([], [])
    where
      mk c = if null s then ([], []) else (,) c . unwords . tail . words $ s

getReference :: [Reference] -> Cite -> Maybe Reference
getReference  r c
    = case citeId c `elemIndex` map (unLiteral . refId) r of
        Just i  -> Just $ setPageFirst $ r !! i
        Nothing -> Nothing

processCites :: [Reference] -> [[Cite]] -> [[(Cite, Reference)]]
processCites rs cs
    = procGr [[]] cs
    where
      procRef r = case filter ((==) (unLiteral $ refId r) . citeId) $ concat cs of
                    x:_ -> r { firstReferenceNoteNumber = readNum $ citeNoteNumber x}
                    []  -> r
      getRef  c = case filter ((==) (citeId c) . unLiteral . refId) rs of
                    x:_ -> procRef $ setPageFirst x
                    []  -> emptyReference { title =
                            fromString $ citeId c ++ " not found!" }

      procGr _ [] = []
      procGr a (x:xs) = let (a',res) = procCs a x
                        in res : procGr (a' ++ [[]]) xs

      procCs a [] = (a,[])
      procCs a (c:xs)
          | isIbidC, isLocSet = go "ibid-with-locator-c"
          | isIbid,  isLocSet = go "ibid-with-locator"
          | isIbidC           = go "ibid-c"
          | isIbid            = go "ibid"
          | isElem            = go "subsequent"
          | otherwise         = go "first"
          where
            go s = let addCite    = if last a /= [] then init a ++ [last a ++ [c]] else init a ++ [[c]]
                       (a', rest) = procCs addCite xs
                   in  (a', (c { citePosition = s}, getRef c) : rest)
            isElem   = citeId c `elem` map citeId (concat a)
            -- Ibid in same citation
            isIbid   = last a /= [] && citeId c == citeId (last $ last a)
            -- Ibid in different citations (must be capitalized)
            isIbidC  = init a /= [] && length (last $ init a) == 1 &&
                       last a == [] && citeId c == citeId (head . last $ init a)
            isLocSet = citeLocator c /= ""

setPageFirst :: Reference -> Reference
setPageFirst ref =
  let Formatted ils = page ref
      ils' = takeWhile (\i -> i /= Str "–" && i /= Str "-") ils
  in  if ils == ils'
         then ref
         else ref{ pageFirst = Formatted ils' }

setNearNote :: Style -> [[Cite]] -> [[Cite]]
setNearNote s cs
    = procGr [] cs
    where
      near_note   = let nn = fromMaybe [] . lookup "near-note-distance" . citOptions . citation $ s
                    in  if nn == [] then 5 else readNum nn
      procGr _ [] = []
      procGr a (x:xs) = let (a',res) = procCs a x
                        in res : procGr a' xs

      procCs a []     = (a,[])
      procCs a (c:xs) = (a', c { nearNote = isNear} : rest)
          where
            (a', rest) = procCs (c:a) xs
            isNear     = case filter ((==) (citeId c) . citeId) a of
                           x:_ -> citeNoteNumber c /= "0" &&
                                  citeNoteNumber x /= "0" &&
                                  readNum (citeNoteNumber c) - readNum (citeNoteNumber x) <= near_note
                           _   -> False

object' :: [Pair] -> Aeson.Value
object' = object . filter (not . isempty)
  where isempty (_, Array v)  = V.null v
        isempty (_, String t) = T.null t
        isempty ("first-reference-note-number", Aeson.Number n) = n == 0
        isempty ("citation-number", Aeson.Number n) = n == 0
        isempty (_, _)        = False

