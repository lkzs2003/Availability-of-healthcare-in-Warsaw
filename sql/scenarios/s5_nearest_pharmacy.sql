-- ============================================================
-- S5 — Najbliższa apteka od punktu — 3 zapytania
-- Pytanie: gdzie jest najbliższa apteka od zadanego adresu?
-- :punkt — lokalizacja użytkownika w EPSG:2180
-- Przykład: Plac Defilad 1 (Pałac Kultury i Nauki)
-- ============================================================

-- Ustaw punkt referencywy (Pałac Kultury i Nauki, Śródmieście)
\set punkt 'ST_Transform(ST_SetSRID(ST_Point(21.0062, 52.2319), 4326), 2180)'


-- Q1: Apteki w promieniu 500 m z filtrem bbox (szybkie pre-filtrowanie)
SELECT id, nazwa, adres,
       ROUND(ST_Distance(geom, :punkt)::NUMERIC, 0) AS odl_m
FROM apteki
WHERE geom && ST_Expand(:punkt, 500)          -- filtr bbox (używa indeksu)
  AND ST_DWithin(geom, :punkt, 500)           -- dokładny filtr odległości
ORDER BY odl_m;


-- Q2: 3 najbliższe apteki z operatorem KNN <-> (indeks GiST)
SELECT id, nazwa, adres,
       ROUND(ST_Distance(geom, :punkt)::NUMERIC, 0) AS odl_m
FROM apteki
ORDER BY geom <-> :punkt
LIMIT 3;


-- Q3: EXPLAIN ANALYZE — porównanie wydajności z indeksem i bez
--     Krok 3a: wydajność z indeksem GiST (domyślny stan)
EXPLAIN ANALYZE
SELECT id, nazwa,
       ST_Distance(geom, :punkt) AS odl_m
FROM apteki
ORDER BY geom <-> :punkt
LIMIT 3;

-- Krok 3b: usuń indeks i powtórz zapytanie
DROP INDEX IF EXISTS idx_apteki_geom;

EXPLAIN ANALYZE
SELECT id, nazwa,
       ST_Distance(geom, :punkt) AS odl_m
FROM apteki
ORDER BY geom <-> :punkt
LIMIT 3;

-- Krok 3c: przywróć indeks i odśwież statystyki planera
CREATE INDEX IF NOT EXISTS idx_apteki_geom ON apteki USING GiST (geom);
ANALYZE apteki;
