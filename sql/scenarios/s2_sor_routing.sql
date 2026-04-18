-- ============================================================
-- S2 — Dostępność SOR po sieci drogowej — 6 zapytań
-- Pytanie: jaki jest czas dojazdu do najbliższego SOR
-- z każdego punktu miasta po faktycznej sieci dróg?
-- Koszt w drogi_topo = długość segmentu w metrach
-- 50 km/h → 1 min = 833 m → 10 min = 8 333 m
-- ============================================================

-- Q1: Lista szpitali z SOR
SELECT id, nazwa, adres,
       ST_X(geom) AS x_pl92,
       ST_Y(geom) AS y_pl92
FROM szpitale_sor
ORDER BY nazwa;


-- Q2: Mapowanie szpitali na węzły sieci drogowej (KNN <->)
SELECT s.id   AS szpital_id,
       s.nazwa,
       v.id   AS vertex_id,
       ROUND(ST_Distance(s.geom, v.geom)::NUMERIC, 0) AS odl_do_wezla_m
FROM szpitale_sor s
CROSS JOIN LATERAL (
    SELECT id, geom
    FROM drogi_vertices
    ORDER BY geom <-> s.geom
    LIMIT 1
) v;


-- Q3: Izochrona 10 min (8333 m) dla wybranego szpitala
--     :vertex_szpitala — węzeł najbliższy wybranemu szpitalowi (z Q2)
\set vertex_szpitala 44

SELECT ST_ConcaveHull(ST_Collect(v.geom), 0.85) AS izochrona_10min
FROM pgr_drivingDistance(
    'SELECT id, source, target, cost FROM drogi_topo',
    :vertex_szpitala, 8333, false
) pgd
JOIN drogi_vertices v ON v.id = pgd.node;


-- Q4: Izochrony 5 / 10 / 15 min dla wszystkich SOR
WITH hospital_vertices AS (
    SELECT DISTINCT ON (s.id)
        s.id AS szpital_id, s.nazwa, v.id AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
    ORDER BY s.id
),
reachable AS (
    SELECT hv.szpital_id, hv.nazwa, pgd.node, pgd.agg_cost,
           CASE
               WHEN pgd.agg_cost <= 4166  THEN '5min'
               WHEN pgd.agg_cost <= 8333  THEN '10min'
               WHEN pgd.agg_cost <= 12500 THEN '15min'
           END AS strefa
    FROM hospital_vertices hv,
         pgr_drivingDistance(
             'SELECT id, source, target, cost FROM drogi_topo',
             ARRAY(SELECT vertex_id FROM hospital_vertices),
             12500, false
         ) pgd
    WHERE pgd.start_vid = hv.vertex_id
)
SELECT szpital_id, nazwa, strefa,
       ST_ConcaveHull(ST_Collect(v.geom), 0.85) AS izochrona
FROM reachable r
JOIN drogi_vertices v ON v.id = r.node
WHERE strefa IS NOT NULL
GROUP BY szpital_id, nazwa, strefa;


-- Q5: Siatka 500 m × 500 m — czas dojazdu do najbliższego SOR
--     (pgr_dijkstra wiele źródeł → wiele celów)
WITH hospital_vertices AS (
    SELECT v.id AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
),
grid AS (
    SELECT
        ST_SetSRID(ST_Point(x, y), 2180) AS geom,
        row_number() OVER () AS cell_id
    FROM generate_series(630000, 680000, 500) x,
         generate_series(490000, 525000, 500) y
),
grid_vertices AS (
    SELECT g.cell_id, g.geom, v.id AS vertex_id
    FROM grid g
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> g.geom LIMIT 1
    ) v
),
dijkstra AS (
    SELECT start_vid, end_vid, agg_cost
    FROM pgr_dijkstra(
        'SELECT id, source, target, cost FROM drogi_topo',
        ARRAY(SELECT vertex_id FROM grid_vertices),
        ARRAY(SELECT vertex_id FROM hospital_vertices),
        directed := false
    )
),
min_cost_per_cell AS (
    SELECT gv.cell_id, gv.geom,
           MIN(d.agg_cost)                       AS koszt_m,
           ROUND((MIN(d.agg_cost) / 833.3)::NUMERIC, 1) AS czas_min
    FROM grid_vertices gv
    LEFT JOIN dijkstra d ON d.start_vid = gv.vertex_id
    GROUP BY gv.cell_id, gv.geom
)
SELECT cell_id, geom, koszt_m, czas_min
FROM min_cost_per_cell
ORDER BY czas_min DESC NULLS FIRST;


-- Q6: Komórki z czasem dojazdu >15 min — obszary krytyczne
WITH hospital_vertices AS (
    SELECT v.id AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
),
grid AS (
    SELECT ST_SetSRID(ST_Point(x, y), 2180) AS geom
    FROM generate_series(630000, 680000, 500) x,
         generate_series(490000, 525000, 500) y
),
grid_vertices AS (
    SELECT g.geom, v.id AS vertex_id
    FROM grid g
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> g.geom LIMIT 1
    ) v
),
dijkstra AS (
    SELECT start_vid, MIN(agg_cost) AS min_koszt_m
    FROM pgr_dijkstra(
        'SELECT id, source, target, cost FROM drogi_topo',
        ARRAY(SELECT vertex_id FROM grid_vertices),
        ARRAY(SELECT vertex_id FROM hospital_vertices),
        directed := false
    )
    GROUP BY start_vid
)
SELECT gv.geom,
       d.min_koszt_m                              AS koszt_m,
       ROUND((d.min_koszt_m / 833.3)::NUMERIC, 1) AS czas_min
FROM grid_vertices gv
JOIN dijkstra d ON d.start_vid = gv.vertex_id
WHERE d.min_koszt_m > 12500   -- > 15 min przy 50 km/h
ORDER BY czas_min DESC;
