-- E3: Wpływ indeksu GiST na wydajność
-- Metryka: EXPLAIN ANALYZE dla Q5.2 (KNN apteki) i Q1.4 (ST_Difference)
-- oraz skalowanie czasu dla N = 10^3, 10^4, 10^5 punktów syntetycznych.

-- -----------------------------------------------------------
-- Tabela benchmark z N punktów losowych w EPSG:2180
-- -----------------------------------------------------------
DROP TABLE IF EXISTS bench_points CASCADE;
CREATE TABLE bench_points (
    id   SERIAL PRIMARY KEY,
    geom GEOMETRY(POINT, 2180)
);

-- 100 000 punktów losowych wewnątrz bbox Warszawy (deterministic via setseed)
-- setseed(0.42) ensures reproducible results across runs for fair EXPLAIN ANALYZE comparison
SELECT setseed(0.42);

INSERT INTO bench_points (geom)
SELECT ST_SetSRID(ST_Point(
    630000 + random() * 50000,
    490000 + random() * 35000
), 2180)
FROM generate_series(1, 100000);

ANALYZE bench_points;

-- ---- Z indeksem GiST ----
CREATE INDEX idx_bench_points_geom ON bench_points USING GiST (geom);
ANALYZE bench_points;

\echo '=== Q5.2 odpowiednik (KNN) — Z indeksem, N=100k ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, ST_Distance(geom, ST_SetSRID(ST_Point(655000, 507000), 2180)) AS d
FROM bench_points
ORDER BY geom <-> ST_SetSRID(ST_Point(655000, 507000), 2180)
LIMIT 3;

\echo '=== Q1.4 odpowiednik (ST_Difference na ST_Union buforów) — Z indeksem ==='
EXPLAIN (ANALYZE, BUFFERS)
WITH pokrycie AS (
    SELECT ST_Union(ST_Buffer(geom, 1000)) AS g FROM przychodnie_poz
),
miasto AS (SELECT ST_Union(geom) AS g FROM dzielnice)
SELECT ST_Area(ST_Difference(m.g, p.g)) FROM miasto m, pokrycie p;

-- ---- Bez indeksu GiST ----
DROP INDEX idx_bench_points_geom;

\echo '=== Q5.2 — BEZ indeksu, N=100k ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, ST_Distance(geom, ST_SetSRID(ST_Point(655000, 507000), 2180)) AS d
FROM bench_points
ORDER BY geom <-> ST_SetSRID(ST_Point(655000, 507000), 2180)
LIMIT 3;

-- Przywróć indeks i sprzątnij
CREATE INDEX idx_bench_points_geom ON bench_points USING GiST (geom);
ANALYZE bench_points;

-- Opcjonalnie: porównanie dla N=1k, 10k
\echo '=== Q5.2 — Z indeksem, N=10k ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT id FROM (SELECT * FROM bench_points LIMIT 10000) sub
ORDER BY geom <-> ST_SetSRID(ST_Point(655000, 507000), 2180)
LIMIT 3;
