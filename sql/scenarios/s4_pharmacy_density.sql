-- ============================================================
-- S4 — Gęstość aptek względem ludności — 4 zapytania
-- Pytanie: jaki jest stosunek liczby aptek do liczby
-- mieszkańców per dzielnica?
-- ============================================================

-- Q1: Przestrzenny JOIN aptek z dzielnicami (ST_Contains)
SELECT d.nazwa AS dzielnica, a.id AS apteka_id, a.nazwa AS apteka
FROM apteki a
JOIN dzielnice d ON ST_Contains(d.geom, a.geom)
ORDER BY d.nazwa, a.nazwa;


-- Q2: Liczba aptek per dzielnica
SELECT d.nazwa,
       COUNT(a.id) AS liczba_aptek
FROM dzielnice d
LEFT JOIN apteki a ON ST_Contains(d.geom, a.geom)
GROUP BY d.id, d.nazwa
ORDER BY liczba_aptek DESC;


-- Q3: Wskaźnik mieszkańcy / apteka per dzielnica
SELECT d.nazwa,
       COUNT(a.id)                                        AS liczba_aptek,
       dd.ludnosc,
       CASE
           WHEN COUNT(a.id) = 0 THEN NULL
           ELSE ROUND((dd.ludnosc::NUMERIC / NULLIF(COUNT(a.id), 0)), 0)
       END AS mieszkancy_na_apteke
FROM dzielnice d
LEFT JOIN apteki a   ON ST_Contains(d.geom, a.geom)
JOIN  demografia_dzielnice dd
    ON dd.dzielnica_id = d.id AND dd.rok = 2023
GROUP BY d.id, d.nazwa, dd.ludnosc
ORDER BY mieszkancy_na_apteke DESC NULLS FIRST;


-- Q4: Ranking z funkcjami okna (RANK, NTILE — kwartyle)
WITH wskazniki AS (
    SELECT d.nazwa,
           COUNT(a.id)                                AS liczba_aptek,
           dd.ludnosc,
           dd.ludnosc::NUMERIC / NULLIF(COUNT(a.id), 0) AS mieszkancy_na_apteke
    FROM dzielnice d
    LEFT JOIN apteki a ON ST_Contains(d.geom, a.geom)
    JOIN  demografia_dzielnice dd
        ON dd.dzielnica_id = d.id AND dd.rok = 2023
    GROUP BY d.id, d.nazwa, dd.ludnosc
)
SELECT nazwa,
       liczba_aptek,
       ROUND(mieszkancy_na_apteke, 0)                AS mieszkancy_na_apteke,
       RANK()  OVER (ORDER BY mieszkancy_na_apteke DESC NULLS LAST) AS rank_dostepnosc,
       NTILE(4) OVER (ORDER BY mieszkancy_na_apteke DESC NULLS LAST) AS kwartyl
       -- kwartyl=1 → najgorsza dostępność (najwięcej mieszk. na aptekę)
       -- kwartyl=4 → najlepsza dostępność
FROM wskazniki
ORDER BY rank_dostepnosc;
