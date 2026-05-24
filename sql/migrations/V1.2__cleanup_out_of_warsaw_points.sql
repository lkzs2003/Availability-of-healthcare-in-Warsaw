-- =====================================================================
--  Migracja V1.2: cleanup_out_of_warsaw_points
-- ---------------------------------------------------------------------
--  Usuwa rekordy znajdujące się geograficznie poza granicami Warszawy.
--  Bbox Overpass (52.10–52.37 N, 20.85–21.27 E) jest większy niż faktyczny
--  obrys miasta i obejmuje także sąsiednie gminy (Marki, Ząbki, Piaseczno,
--  Pruszków, Legionowo). Po spatial-join z `dzielnice` rekordy spoza
--  Warszawy mają NULL w kolumnie `dzielnica` — i właśnie je usuwamy.
--
--  Po tej migracji wszystkie analizy zwracają wynik wyłącznie dla
--  obszaru Warszawy administracyjnej (18 dzielnic, 517 km²).
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

-- Diagnoza przed usunięciem (raport do logu psql).
\echo
\echo '>> Rekordy do usunięcia (NULL dzielnica = poza granicami Warszawy):'
SELECT 'apteki'          AS tabela, COUNT(*) AS do_usuniecia FROM public.apteki          WHERE dzielnica IS NULL
UNION ALL
SELECT 'przychodnie_poz' AS tabela, COUNT(*) AS do_usuniecia FROM public.przychodnie_poz WHERE dzielnica IS NULL
UNION ALL
SELECT 'szpitale_sor'    AS tabela, COUNT(*) AS do_usuniecia FROM public.szpitale_sor    WHERE dzielnica IS NULL;

-- Usuwanie.
DELETE FROM public.apteki          WHERE dzielnica IS NULL;
DELETE FROM public.przychodnie_poz WHERE dzielnica IS NULL;
DELETE FROM public.szpitale_sor    WHERE dzielnica IS NULL;

COMMIT;

REFRESH MATERIALIZED VIEW public.mv_pokrycie_poz_1km;
REFRESH MATERIALIZED VIEW public.mv_voronoi_poz;
REFRESH MATERIALIZED VIEW public.mv_sor_reachability;

ANALYZE public.apteki;
ANALYZE public.przychodnie_poz;
ANALYZE public.szpitale_sor;

\echo
\echo '>> Stan końcowy:'
SELECT 'apteki'          AS tabela, COUNT(*) FROM public.apteki
UNION ALL
SELECT 'przychodnie_poz' AS tabela, COUNT(*) FROM public.przychodnie_poz
UNION ALL
SELECT 'szpitale_sor'    AS tabela, COUNT(*) FROM public.szpitale_sor;
