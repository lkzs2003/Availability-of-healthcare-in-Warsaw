-- QGIS layer for S6 — sumaryczne placówki + ludność per dzielnica
-- Geometry column: geom, SRID: 2180, Geometry type: MultiPolygon
-- Style: Graduated by `liczba_aptek` lub `mieszkancy_na_przychodnie`
SELECT
    d.id, d.nazwa, d.geom, dd.ludnosc,
    (SELECT COUNT(*) FROM apteki a          WHERE ST_Contains(d.geom, a.geom)) AS liczba_aptek,
    (SELECT COUNT(*) FROM przychodnie_poz p WHERE ST_Contains(d.geom, p.geom)) AS liczba_przychodni_poz,
    (SELECT COUNT(*) FROM szpitale_sor s    WHERE ST_Contains(d.geom, s.geom)) AS liczba_sor,
    ROUND(
        dd.ludnosc::NUMERIC /
        NULLIF((SELECT COUNT(*) FROM przychodnie_poz p WHERE ST_Contains(d.geom, p.geom)), 0),
        0
    ) AS mieszkancy_na_przychodnie
FROM dzielnice d
JOIN demografia_dzielnice dd ON dd.dzielnica_id = d.id AND dd.rok = 2023;
