-- ============================================================
-- S3 — Lokalizacja nowej przychodni POZ — 5 zapytań
-- Pytanie: gdzie otworzyć nową przychodnię, aby maksymalnie
-- poprawić dostępność?
-- ============================================================

-- Q1: Diagram Voronoi dla istniejących przychodni POZ
WITH pts AS (
    SELECT ST_Collect(geom) AS geom FROM przychodnie_poz
),
envelope AS (
    SELECT ST_Expand(ST_Envelope(geom), 5000) AS g FROM pts
)
SELECT (ST_Dump(ST_VoronoiPolygons(pts.geom, 0, envelope.g))).geom AS strefa_voronoi
FROM pts, envelope;


-- Q2: Ranking stref Voronoi według powierzchni
--     (duża strefa Voronoi = słaba dostępność)
WITH pts AS (
    SELECT ST_Collect(geom) AS geom FROM przychodnie_poz
),
envelope AS (
    SELECT ST_Expand(ST_Envelope(geom), 5000) AS g FROM pts
),
voronoi AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(pts.geom, 0, envelope.g))).geom AS strefa
    FROM pts, envelope
),
miasto AS (
    SELECT ST_Union(geom) AS g FROM dzielnice
),
voronoi_clip AS (
    SELECT ST_Intersection(v.strefa, m.g) AS strefa_clip
    FROM voronoi v, miasto m
    WHERE ST_Intersects(v.strefa, m.g)
)
SELECT ROUND((ST_Area(strefa_clip) / 1e6)::NUMERIC, 3) AS powierzchnia_km2,
       strefa_clip
FROM voronoi_clip
ORDER BY ST_Area(strefa_clip) DESC;


-- Q3: Centroid największej strefy Voronoi jako kandydat
WITH pts AS (
    SELECT ST_Collect(geom) AS geom FROM przychodnie_poz
),
envelope AS (
    SELECT ST_Expand(ST_Envelope(geom), 5000) AS g FROM pts
),
voronoi AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(pts.geom, 0, envelope.g))).geom AS strefa
    FROM pts, envelope
),
miasto AS (
    SELECT ST_Union(geom) AS g FROM dzielnice
),
voronoi_clip AS (
    SELECT ST_Intersection(v.strefa, m.g) AS strefa_clip
    FROM voronoi v, miasto m
    WHERE ST_Intersects(v.strefa, m.g)
),
top_strefa AS (
    SELECT strefa_clip
    FROM voronoi_clip
    ORDER BY ST_Area(strefa_clip) DESC
    LIMIT 1
)
SELECT ST_Centroid(strefa_clip) AS kandydat_lokalizacja,
       ROUND((ST_Area(strefa_clip) / 1e6)::NUMERIC, 3) AS pow_km2
FROM top_strefa;


-- Q4: Szacunek mieszkańców w buforze 1 km wokół kandydata
--     (proporcja przecinającej się powierzchni z dzielnicą)
WITH pts AS (
    SELECT ST_Collect(geom) AS geom FROM przychodnie_poz
),
envelope AS (
    SELECT ST_Expand(ST_Envelope(geom), 5000) AS g FROM pts
),
voronoi AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(pts.geom, 0, envelope.g))).geom AS strefa
    FROM pts, envelope
),
miasto AS (
    SELECT ST_Union(geom) AS g FROM dzielnice
),
voronoi_clip AS (
    SELECT ST_Intersection(v.strefa, m.g) AS strefa_clip
    FROM voronoi v, miasto m
    WHERE ST_Intersects(v.strefa, m.g)
),
kandydat AS (
    SELECT ST_Buffer(ST_Centroid(strefa_clip), 1000) AS bufor_1km
    FROM voronoi_clip
    ORDER BY ST_Area(strefa_clip) DESC
    LIMIT 1
)
SELECT d.nazwa,
       dd.ludnosc,
       ROUND((ST_Area(ST_Intersection(d.geom, k.bufor_1km))
              / ST_Area(d.geom) * dd.ludnosc)::NUMERIC) AS szac_mieszkancy
FROM dzielnice d
JOIN demografia_dzielnice dd ON dd.dzielnica_id = d.id AND dd.rok = 2023
CROSS JOIN kandydat k
WHERE ST_Intersects(d.geom, k.bufor_1km)
ORDER BY szac_mieszkancy DESC;


-- Q5: Top 5 kandydatów z porównaniem (powierzchnia strefy + zasięg 1 km)
WITH pts AS (
    SELECT ST_Collect(geom) AS geom FROM przychodnie_poz
),
envelope AS (
    SELECT ST_Expand(ST_Envelope(geom), 5000) AS g FROM pts
),
voronoi AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(pts.geom, 0, envelope.g))).geom AS strefa
    FROM pts, envelope
),
miasto AS (
    SELECT ST_Union(geom) AS g FROM dzielnice
),
voronoi_clip AS (
    SELECT row_number() OVER (ORDER BY ST_Area(ST_Intersection(v.strefa, m.g)) DESC)
               AS rank_nr,
           ST_Intersection(v.strefa, m.g) AS strefa_clip,
           ST_Centroid(ST_Intersection(v.strefa, m.g))                AS kandydat
    FROM voronoi v, miasto m
    WHERE ST_Intersects(v.strefa, m.g)
    ORDER BY ST_Area(ST_Intersection(v.strefa, m.g)) DESC
    LIMIT 5
),
zasieg AS (
    SELECT vc.rank_nr, vc.kandydat,
           ROUND((ST_Area(vc.strefa_clip) / 1e6)::NUMERIC, 3) AS pow_strefy_km2,
           COALESCE(SUM(
               ROUND((ST_Area(ST_Intersection(d.geom, ST_Buffer(vc.kandydat, 1000)))
                      / ST_Area(d.geom) * dd.ludnosc)::NUMERIC)
           ), 0) AS szac_mieszkancy_1km
    FROM voronoi_clip vc
    LEFT JOIN dzielnice d ON ST_Intersects(d.geom, ST_Buffer(vc.kandydat, 1000))
    LEFT JOIN demografia_dzielnice dd ON dd.dzielnica_id = d.id AND dd.rok = 2023
    GROUP BY vc.rank_nr, vc.kandydat, vc.strefa_clip
)
SELECT rank_nr,
       ST_X(kandydat) AS x_pl92,
       ST_Y(kandydat) AS y_pl92,
       pow_strefy_km2,
       szac_mieszkancy_1km
FROM zasieg
ORDER BY rank_nr;
