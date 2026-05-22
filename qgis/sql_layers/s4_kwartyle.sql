-- QGIS layer for S4 — dzielnice z kwartylem dostępności aptek
-- Geometry column: geom, SRID: 2180, Geometry type: MultiPolygon
-- Style: Categorized by `kwartyl` (1=red worst, 4=green best, 0=gray no data)
WITH wskazniki AS (
    SELECT d.id, d.nazwa, d.geom,
           COUNT(a.id)                                AS liczba_aptek,
           dd.ludnosc::NUMERIC / NULLIF(COUNT(a.id), 0) AS mieszkancy_na_apteke
    FROM dzielnice d
    LEFT JOIN apteki a ON ST_Contains(d.geom, a.geom)
    JOIN demografia_dzielnice dd ON dd.dzielnica_id = d.id AND dd.rok = 2023
    GROUP BY d.id, d.nazwa, d.geom, dd.ludnosc
)
SELECT id, nazwa, geom, liczba_aptek,
       ROUND(mieszkancy_na_apteke, 0) AS mieszkancy_na_apteke,
       CASE WHEN liczba_aptek = 0 THEN 0
            ELSE NTILE(4) OVER (PARTITION BY (liczba_aptek > 0)
                                ORDER BY mieszkancy_na_apteke DESC)
       END AS kwartyl
FROM wskazniki;
