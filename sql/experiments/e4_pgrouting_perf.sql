-- E4: Wydajność pgRouting
-- Metryka: czas wykonania scenariusza S2 Q5 dla siatki 500 m vs 1 km.

\echo '=== S2.5 — siatka 500 m ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
WITH hospital_vertices AS (
    SELECT v.id::BIGINT AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
),
reachability AS (
    SELECT pgd.node AS vertex_id, MIN(pgd.agg_cost) AS min_koszt_m
    FROM pgr_drivingDistance(
        'SELECT id, source, target, cost FROM drogi_topo',
        ARRAY(SELECT vertex_id FROM hospital_vertices)::BIGINT[],
        25000, false
    ) pgd
    GROUP BY pgd.node
),
grid AS (
    SELECT ST_SetSRID(ST_Point(x, y), 2180) AS geom
    FROM generate_series(630000, 680000, 500) x,
         generate_series(490000, 525000, 500) y
)
SELECT COUNT(*) AS komorki_z_czasem
FROM grid g
CROSS JOIN LATERAL (
    SELECT id FROM drogi_vertices ORDER BY geom <-> g.geom LIMIT 1
) v
LEFT JOIN reachability r ON r.vertex_id = v.id;

\echo '=== S2.5 — siatka 1 km ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
WITH hospital_vertices AS (
    SELECT v.id::BIGINT AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
),
reachability AS (
    SELECT pgd.node AS vertex_id, MIN(pgd.agg_cost) AS min_koszt_m
    FROM pgr_drivingDistance(
        'SELECT id, source, target, cost FROM drogi_topo',
        ARRAY(SELECT vertex_id FROM hospital_vertices)::BIGINT[],
        25000, false
    ) pgd
    GROUP BY pgd.node
),
grid AS (
    SELECT ST_SetSRID(ST_Point(x, y), 2180) AS geom
    FROM generate_series(630000, 680000, 1000) x,
         generate_series(490000, 525000, 1000) y
)
SELECT COUNT(*) AS komorki_z_czasem
FROM grid g
CROSS JOIN LATERAL (
    SELECT id FROM drogi_vertices ORDER BY geom <-> g.geom LIMIT 1
) v
LEFT JOIN reachability r ON r.vertex_id = v.id;
