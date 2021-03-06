{-# LANGUAGE TemplateHaskell    #-}
module TinyThreePassCompiler where


import           Control.Applicative
import           Control.Lens
import           Control.Monad.State
import qualified Data.Map as M
import           Data.Maybe (fromJust, listToMaybe)


data AST = Imm Int
         | Arg Int
         | Add AST AST
         | Sub AST AST
         | Mul AST AST
         | Div AST AST
         deriving (Eq, Show)


data Token = TChar Char
           | TInt Int
           | TStr String
           deriving (Eq, Show)


alpha, digit :: String
alpha = ['a'..'z'] ++ ['A'..'Z']
digit = ['0'..'9']

tokenize :: String -> [Token]
tokenize [] = []
tokenize xxs@(c:cs)
  | c `elem` "-+*/()[]" = TChar c : tokenize cs
  | not (null i) = TInt (read i) : tokenize is
  | not (null s) = TStr s : tokenize ss
  | otherwise = tokenize cs
  where
    (i, is) = span (`elem` digit) xxs
    (s, ss) = span (`elem` alpha) xxs


------------------------------------------------------------------------------
-- | Parser state
data ParserSate = ParserSate { _input     :: [ Token ]
                             , _pos       :: Int
                             , _variables :: M.Map String Int
                             }
makeLenses ''ParserSate
type Parser a = (StateT ParserSate Maybe) a


runParser :: Parser a -> [Token] -> Maybe a
runParser p i = evalStateT p (ParserSate i 0 M.empty)


------------------------------------------------------------------------------
-- | next token
next :: Parser Token
next = do
  t <- liftM listToMaybe $ use input
  input %= tail
  lift t


------------------------------------------------------------------------------
-- | Asserts that the next token is the one we expect
token :: Char -> Parser ()
token x = next >>= \t -> guard $ t == TChar x


------------------------------------------------------------------------------
-- | Reads a variable name and creates the symbol table entry
variable :: Parser ()
variable = next >>= \t -> case t of
  (TStr name) -> do
    p <- pos <%= succ
    variables %= M.insert name (p - 1)
  _           -> mzero


------------------------------------------------------------------------------
-- | Parses a single value either immediate or a variable reference
value :: Parser AST
value = immVal <|> varVal
  where
    immVal = next >>= \t -> case t of
      (TInt i) -> return $ Imm i
      _        -> mzero
    varVal = next >>= \t -> case t of
      (TStr name) -> do
        p <- liftM (M.lookup name) $ use variables
        lift $ Arg <$> p
      _           -> mzero


------------------------------------------------------------------------------
-- | Parser
pass1 :: String -> AST
pass1 = fromJust . runParser function . tokenize
  where
    function      = do
      token '[' *> argument_list <* token ']'
      expression
    argument_list = void $ many variable
    expression    = term >>= expression'  -- left to right recursion rewrite
    expression' l =     (token '+' *> liftM (Add l) term >>= expression')
                    <|> (token '-' *> liftM (Sub l) term >>= expression')
                    <|> return l
    term          = factor >>= term'      -- left to right recursion rewrite
    term' l       =     (token '*' *> liftM (Mul l) factor >>= term')
                    <|> (token '/' *> liftM (Div l) factor >>= term')
                    <|> return l
    factor        = token '(' *> expression <* token ')' <|> value


------------------------------------------------------------------------------
instance Plated AST where
  plate f (Add x y) = Add <$> f x <*> f y
  plate f (Sub x y) = Sub <$> f x <*> f y 
  plate f (Mul x y) = Mul <$> f x <*> f y 
  plate f (Div x y) = Div <$> f x <*> f y
  plate _ x         = pure x


------------------------------------------------------------------------------
-- | Simplifier
pass2 :: AST -> AST
pass2 = transform f
  where f (Add (Imm a) (Imm b)) = Imm $ a + b
        f (Sub (Imm a) (Imm b)) = Imm $ a - b
        f (Mul (Imm a) (Imm b)) = Imm $ a * b
        f (Div (Imm a) (Imm b)) = Imm $ a `div` b
        f x = x        


------------------------------------------------------------------------------
-- | Intruction set
data Instruction = IM Int
                 | AR Int
                 | PU | PO | SW | AD | SU | MU | DI deriving (Eq, Show)


generate :: AST -> [ Instruction ]
generate (Imm x) = [ IM x, PU ]
generate (Arg x) = [ AR x, PU ]
generate (Add x1 x2) = generate x1 ++ generate x2 ++ popPush AD
generate (Sub x1 x2) = generate x1 ++ generate x2 ++ popPush SU
generate (Mul x1 x2) = generate x1 ++ generate x2 ++ popPush MU
generate (Div x1 x2) = generate x1 ++ generate x2 ++ popPush DI


popPush :: Instruction -> [Instruction]
popPush x = [ PO, SW, PO, x, PU ]


tPUPO :: [Instruction] -> [Instruction]
tPUPO (PU:PO:t) = t
tPUPO x         = x


tPU_SWPO_ :: [Instruction] -> [Instruction]
tPU_SWPO_ z@(PU:IM x:SW:PO:y:t) | y `elem` [AD, MU] = SW:IM x:y:t
                                | y `elem` [SU, DI] = SW:IM x:SW:y:t
                                | otherwise         = z
tPU_SWPO_ z@(PU:AR x:SW:PO:y:t) | y `elem` [AD, MU] = SW:AR x:y:t
                                | y `elem` [SU, DI] = SW:AR x:SW:y:t
                                | otherwise         = z                                                   
tPU_SWPO_ x                     = x


t_SW_SW :: [Instruction] -> [Instruction]
t_SW_SW (IM x:SW:IM y:SW:t) = IM y:SW:IM x:t
t_SW_SW (IM x:SW:AR y:SW:t) = AR y:SW:IM x:t
t_SW_SW (AR x:SW:IM y:SW:t) = IM y:SW:AR x:t
t_SW_SW (AR x:SW:AR y:SW:t) = AR y:SW:AR x:t
t_SW_SW x                   = x



peepHole :: [Instruction] -> [Instruction]
peepHole = transform t_SW_SW . transform tPU_SWPO_ . transform tPUPO


------------------------------------------------------------------------------
-- | Code generator
pass3 :: AST -> [ String ]
pass3 = map show . peepHole . init . generate


compile :: String -> [String]
compile = pass3 . pass2 . pass1
