Copyright (c) 2016 Rodrigo Ribeiro (rodrigo@decsi.ufop.br)
                   Leandro T. C. Melo (ltcmelo@gmail.com)
                   Marcus Rodrigues (demaroar@gmail.com)

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public License
along with this library; if not, write to the Free Software Foundation,
Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA

Constraints' Parser

> module Parser.ConstraintParser (module Parser.ConstraintParser, module Text.Parsec) where

> import Data.Functor
> import Data.Functor.Identity

> import Text.Parsec
> import Text.Parsec.Char
> import Text.Parsec.Language
> import Text.Parsec.Token (TokenParser)
> import qualified Text.Parsec.Token as Tk
> import qualified Text.Parsec.Expr as Ex

> import Data.Type
> import Data.Constraints


A type for parsers

> type Parser a = ParsecT String () Identity a


Top level parsing function

> parser :: String -> Either String Constraint
> parser = either (Left . show) Right . parse constraintParser ""


Constraint parser

> constraintParser :: Parser Constraint
> constraintParser = Ex.buildExpressionParser table ctrParser
>                    where
>                      table = [[ Ex.Infix conjParser Ex.AssocLeft ]]
>                      conjParser = (:&:) <$ comma

> ctrParser :: Parser Constraint
> ctrParser = choice [
>                      eqParser
>                    , ascriptionParser
>                    , hasParser
>                    , defParser
>                    , existsParser
>                    , typeDefParser
>                    , isConstParser
>                    ]

> eqParser :: Parser Constraint
> eqParser = (:=:) <$> typeParser <* reservedOp "="
>                                 <*> typeParser

> ascriptionParser :: Parser Constraint
> ascriptionParser = build <$> reserved "$typeof$" <*>
>                              (parens nameParser) <*>
>                              reservedOp "="      <*>
>                              typeParser
>                    where
>                      build _ n _ t = n :<-: t

> isConstParser :: Parser Constraint
> isConstParser = build <$> reserved "$read_only$" <*>
>                         (parens nameParser)
>                    where
>                      build _ n = Const n

> hasParser :: Parser Constraint
> hasParser = reserved "$has$" *>
>             parens (build <$> typeParser <*>
>                               comma      <*>
>                               nameParser <*>
>                               colon      <*>
>                               typeParser)
>             where
>               build t _ n _ t' = Has t (Field n t')

> defParser :: Parser Constraint
> defParser = build <$> reserved "$def$" <*> nameParser <*>
>                       colon          <*> typeParser <*>
>                       reserved "$in$"  <*> constraintParser
>             where
>               build _ n _ t _ ctr = Def n t ctr

> existsParser :: Parser Constraint
> existsParser = build <$> reserved "$exists$" <*> nameParser <*>
>                          reservedOp "."    <*> constraintParser
>                where
>                  build _ n _ ctr = Exists n ctr

> typeDefParser :: Parser Constraint
> typeDefParser = build <$> reserved "$typedef$" <*> typeParser <*>
>                           reserved "$as$"      <*> typeParser
>                 where
>                    build _ n _ t = TypeDef n t


Type parser

> constQualParser :: Parser Ty -> Parser Ty
> constQualParser p = f <$> p <*> (optionMaybe constParser)
>                     where
>                       f t Nothing = t
>                       f t _ = QualTy t

> typeParser :: Parser Ty
> typeParser = constQualParser typeParser'

> typeParser' :: Parser Ty
> typeParser' = f <$> typeParser'' <*> (many starParser)
>              where
>                f t ts = foldr (\ _ ac -> Pointer ac) t ts

> typeParser'' :: Parser Ty
> typeParser'' = choice [ tyVarParser
>                      , constQualParser floatTyParser
>                      , constQualParser intTyParser
>                      , constQualParser tyConParser
>                      , funTyParser
>                      , constQualParser structTyParser
>                      , constQualParser enumTyParser
>                     ]

> trivialSpecParser :: Parser Ty
> trivialSpecParser
>   = TyCon <$> name'
>   where
>     name' = try (reserved "short" >> return (Name "short"))
>               <|> try (reserved "char" >> return (Name "char"))
>               <|> try (reserved "int" >> return (Name "int"))
>               <|> try (reserved "long" >> return (Name "long"))
>               <|> try (reserved "unsigned" >> return (Name "unsigned"))
>               <|> try (reserved "signed" >> return (Name "signed"))
>               <|> try (reserved "double" >> return (Name "double")) -- Because long double.
>               <* skipMany space

> intTyParser :: Parser Ty
> intTyParser
>   = f <$> trivialSpecParser <*> (many trivialSpecParser)
>   where
>     f t ts = foldr (\(TyCon t') (TyCon t'') -> TyCon (Name $ unName t'' ++ " " ++ unName t')) t ts

> floatTyParser :: Parser Ty
> floatTyParser
>   = TyCon <$> name'
>   where
>     name' = try (reserved "float" >> return (Name "float"))
>               <|> try (reserved "double" >> return (Name "double"))
>               <* skipMany space

> tyVarParser :: Parser Ty
> tyVarParser = TyVar <$> name'
>               where
>                  name' = f <$> string "#alpha"
>                            <*> (show <$> Tk.integer constrLexer)
>                  f x y = Name (x ++ y)

> tyConParser :: Parser Ty
> tyConParser = f <$> (Tk.identifier constrLexer)
>               where
>                 f n = TyCon (Name n)

> funTyParser :: Parser Ty
> funTyParser = f <$> parens (typeParser `sepBy1` comma)
>               where
>                 f ts = FunTy (last ts) (init ts)

> structTyParser :: Parser Ty
> structTyParser = f <$> reserved "struct" <*>
>                      ((Name "") `option` nameParser)  <*>
>                      ((Left <$> braces (fieldParser `endBy` semi)) <|>
>                       (Right <$> many starParser))
>                where
>                  f _ n (Left fs) = Struct fs (elabName n)
>                  f _ n (Right ts) = foldr (\ _ ac -> Pointer ac) (TyCon (elabName n)) ts
>                  elabName n' = Name ("struct " ++ (unName n'))

> enumTyParser :: Parser Ty
> enumTyParser = f <$> reserved "enum" <*>
>                      ((Name "") `option` nameParser)  <*>
>                      ((Left <$> braces (nameParser `endBy` comma)) <|>
>                       (Right <$> many starParser))
>                where
>                  f _ n (Left _) = EnumTy (elabName n)
>                  f _ n (Right ts) = foldr (\ _ ac -> Pointer ac) (EnumTy (elabName n)) ts
>                  elabName n' = Name ("enum " ++ (unName n'))

> fieldParser :: Parser Field
> fieldParser = flip Field <$> typeParser <*> nameParser

Lexer definition

> constrLexer :: TokenParser st
> constrLexer = Tk.makeTokenParser constrDef

> nameParser :: Parser Name
> nameParser = Name <$> (Tk.identifier constrLexer <|>
>                        Tk.operator constrLexer)

> reserved :: String -> Parser ()
> reserved = Tk.reserved constrLexer

> reservedOp :: String -> Parser ()
> reservedOp = Tk.reservedOp constrLexer

> braces :: Parser a -> Parser a
> braces = Tk.braces constrLexer

> parens :: Parser a -> Parser a
> parens = Tk.parens constrLexer

> comma :: Parser ()
> comma = () <$ Tk.comma constrLexer

> semi :: Parser ()
> semi = () <$ Tk.semi constrLexer

> starParser :: Parser ()
> starParser = () <$ (Tk.lexeme constrLexer $ Tk.symbol constrLexer "*")

> constParser :: Parser ()
> constParser = () <$ (Tk.lexeme constrLexer $ Tk.reserved constrLexer "const")

> colon :: Parser ()
> colon = () <$ Tk.colon constrLexer

> dot :: Parser ()
> dot = () <$ Tk.dot constrLexer

Constraint language definition

> constrDef :: LanguageDef st
> constrDef = emptyDef {
>     Tk.identStart = letter <|> char '_' <|> char '#'
>   , Tk.reservedOpNames = [":", "=", "->"]
>   , Tk.reservedNames = [
>                        -- Reserved C names we need to distinguish.
>                          "struct"
>                        , "enum"
>                        , "unsigned"
>                        , "signed"
>                        , "char"
>                        , "short"
>                        , "int"
>                        , "long"
>                        , "float"
>                        , "double"
>                        , "const"
>                        -- The surrounding `$'s are to prevend collisions
>                        -- between identifiers in the C program and keywords
>                        -- from our the contraint's language.
>                        , "$exists$"
>                        , "$def$"
>                        , "$in$"
>                        , "$typedef$" -- Not to be confused with C's typedef.
>                        , "$as$"
>                        , "$has$"
>                        , "$typeof$"
>                        , "$read_only$"
>                        ]
>                      }
