-- FFI across multiple modules.
-- Rewrite with named fields, Show, Eq.
module Main where
import Base
import Map
import Ast
import RTS
import Compiler
import Kiselyov
import System

hide_prelude_here' = hide_prelude_here'

codegenLocal (name, ((_, lambs), _)) (bigmap, (hp, f)) =
  (insert name localmap bigmap, (hp', f . f'))
  where
  (localmap, (hp', f')) = hashcons hp $ optiComb lambs

codegen ffis mods = (bigmap', mem) where
  (bigmap, (_, memF)) = foldr codegenLocal (Tip, (128, id)) $ toAscList mods
  bigmap' = (resolveGlobal <$>) <$> bigmap
  mem = resolveGlobal <$> memF []
  ffiIndex = fromList $ zip (keys ffis) [0..]
  resolveGlobal = \case
    Left (m, s) -> if m == "{foreign}"
      then ffiIndex ! s
      else resolveGlobal $ (bigmap ! m) ! s
    Right n -> n

getIOType (Qual [] (TAp (TC "IO") t)) = Right t
getIOType q = Left $ "main : " ++ show q

ffcat (name, (_, (ffis, ffes))) (xs, ys) =
  ( foldr (\(k, v) m -> insertWith (error $ "duplicate import: " ++ k) k v m) xs $ toAscList ffis
  , foldr (\(k, v) m -> insertWith (error $ "duplicate export: " ++ k) k (name, v) m) ys $ toAscList ffes
  )

compile s = either id id do
  mods <- untangle s
  let
    (ffis, ffes) = foldr ffcat (Tip, Tip) $ toAscList mods
    (bigmap, mem) = codegen ffis mods
    mustType modName s = case mlookup s $ fst $ fst $ mods ! modName of
      Just (Qual [] t) -> t
      _ -> error "TODO: report bad exports"
    mayMain = do
        tab <- mlookup "Main" bigmap
        mainAddr <- mlookup "main" tab
        mainType <- mlookup "main" $ fst $ fst $ mods ! "Main"
        pure (mainAddr, mainType)
  mainStr <- case mayMain of
    Nothing -> pure ""
    Just (a, q) -> do
      getIOType q
      pure $ genMain a

  pure
    $ ("#include<stdio.h>\n"++)
    . ("typedef unsigned u;\n"++)
    . ("enum{_UNDEFINED=0,"++)
    . foldr (.) id (map (\(s, _) -> ('_':) . (s++) . (',':)) comdefs)
    . ("};\n"++)
    . ("static const u prog[]={" ++)
    . foldr (.) id (map (\n -> shows n . (',':)) mem)
    . ("};\nstatic u root[]={" ++)
    . foldr (\(_, (modName, ourName)) f -> maybe undefined shows (mlookup ourName $ bigmap ! modName) . (", " ++) . f) id (toAscList ffes)
    . ("0};\n" ++)
    . (preamble++)
    . (libc++)
    . foldr (.) id (ffiDeclare <$> toAscList ffis)
    . ("static void foreign(u n) {\n  switch(n) {\n" ++)
    . foldr (.) id (zipWith ffiDefine [0..] $ toAscList ffis)
    . ("\n  }\n}\n" ++)
    . runFun
    . foldr (.) id (zipWith (\(expName, (modName, ourName)) n -> ("EXPORT(f"++) . shows n . (", \""++) . (expName++) . ("\")\n"++)
      . genExport (arrCount $ mustType modName ourName) n) (toAscList ffes) [0..])
    $ mainStr

dumpWith dumper s = case untangle s of
  Left err -> err
  Right tab -> foldr ($) [] $ map (\(name, mod) -> ("module "++) . (name++) . ('\n':) . (foldr (.) id $ dumper mod)) $ toAscList tab

dumpLambs ((_, lambs), _) = map (\(s, t) -> (s++) . (" = "++) . showAst False t . ('\n':)) lambs

dumpTypes ((typed, _), _) = map (\(s, q) -> (s++) . (" :: "++) . shows q . ('\n':)) $ toAscList typed

dumpCombs ((_, lambs), _) = go <$> optiComb lambs where
  go (s, t) = (s++) . (" = "++) . shows t . (";\n"++)

main = getArgs >>= \case
  "comb":_ -> interact $ dumpWith dumpCombs
  "lamb":_ -> interact $ dumpWith dumpLambs
  "type":_ -> interact $ dumpWith dumpTypes
  _ -> interact compile
  where
  getArg' k n = getArgChar n k >>= \c -> if ord c == 0 then pure [] else (c:) <$> getArg' (k + 1) n
  getArgs = getArgCount >>= \n -> mapM (getArg' 0) [1..n-1]
