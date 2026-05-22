-- ============================================================
-- S5 — Najbliższa apteka od punktu — 3 zapytania
-- Pytanie: gdzie jest najbliższa apteka od zadanego adresu?
-- :punkt — lokalizacja użytkownika w EPSG:2180
-- Przykład: Plac Defilad 1 (Pałac Kultury i Nauki)
-- ============================================================

-- Punkt referencyjny (Pałac Kultury i Nauki, Śródmieście) — definiowany
-- raz jako stała PL/pgSQL w temp table, używany we wszystkich zapytaniach.
-- Dzięki temu ST_Transform/ST_SetSRID NIE są re-parsowane przy każdym :punkt
-- (jak miałby psql \set z podstawieniem tekstowym).
DROP TABLE IF EXISTS _s5_ref_point;
CREATE TEMP TABLE _s5_ref_point AS
SELECT ST_Transform(ST_SetSRID(ST_Point(21.0062, 52.2319), 4326), 2180) AS geom;


-- Q1: Apteki w promieniu 500 m z filtrem bbox (szybkie pre-filtrowanie)
SELECT a.id, a.nazwa, a.adres,
       ROUND(ST_Distance(a.geom, p.geom)::NUMERIC, 0) AS odl_m
FROM apteki a, _s5_ref_point p
WHERE a.geom && ST_Expand(p.geom, 500)          -- filtr bbox (używa indeksu)
  AND ST_DWithin(a.geom, p.geom, 500)           -- dokładny filtr odległości
ORDER BY odl_m;


-- Q2: 3 najbliższe apteki z operatorem KNN <-> (indeks GiST)
SELECT a.id, a.nazwa, a.adres,
       ROUND(ST_Distance(a.geom, p.geom)::NUMERIC, 0) AS odl_m
FROM apteki a, _s5_ref_point p
ORDER BY a.geom <-> p.geom
LIMIT 3;


-- Q3: EXPLAIN ANALYZE — porównanie wydajności z indeksem i bez
--     Krok 3a: wydajność z indeksem GiST (domyślny stan)
EXPLAIN ANALYZE
SELECT a.id, a.nazwa,
       ST_Distance(a.geom, p.geom) AS odl_m
FROM apteki a, _s5_ref_point p
ORDER BY a.geom <-> p.geom
LIMIT 3;

-- Krok 3b: benchmark QUERY PLAN bez GiST (rolled back — index survives)
--          Using ROLLBACK ensures no permanent schema mutation if interrupted.
BEGIN;
    DROP INDEX idx_apteki_geom;

    EXPLAIN ANALYZE
    SELECT a.id, a.nazwa,
           ST_Distance(a.geom, p.geom) AS odl_m
    FROM apteki a, _s5_ref_point p
    ORDER BY a.geom <-> p.geom
    LIMIT 3;

    ROLLBACK;  -- Cancel the DROP, index is intact

-- (ROLLBACK already restored the index and pg_class stats — no ANALYZE needed.)
