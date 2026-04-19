-- ============================================================
-- S6 — Placówki w wybranej dzielnicy — 2 zapytania
-- Pytanie: ile i jakie placówki są w wybranej dzielnicy?
-- ============================================================

-- Q1: Lista przychodni POZ w wybranej dzielnicy (ST_Contains + nazwa)
\set dzielnica_nazwa 'Mokotów'

SELECT p.id, p.nazwa, p.adres, p.nr_rpwdl
FROM przychodnie_poz p
JOIN dzielnice d ON ST_Contains(d.geom, p.geom)
WHERE d.nazwa = :'dzielnica_nazwa'
ORDER BY p.nazwa;


-- Q2: Zbiorcze zestawienie wszystkich typów placówek per dzielnica
--     Scalar subqueries zamiast triple LEFT JOIN — unika
--     multiplikatywnego wybuchu wierszy (O(n+m+k) zamiast O(n*m*k)).
SELECT
    d.nazwa                                                   AS dzielnica,
    dd.ludnosc,
    (SELECT COUNT(*) FROM apteki a
        WHERE ST_Contains(d.geom, a.geom))                    AS liczba_aptek,
    (SELECT COUNT(*) FROM przychodnie_poz p
        WHERE ST_Contains(d.geom, p.geom))                    AS liczba_przychodni_poz,
    (SELECT COUNT(*) FROM szpitale_sor s
        WHERE ST_Contains(d.geom, s.geom))                    AS liczba_sor,
    ROUND(
        dd.ludnosc::NUMERIC
        / NULLIF(
            (SELECT COUNT(*) FROM przychodnie_poz p
                WHERE ST_Contains(d.geom, p.geom)),
            0
        ),
        0
    )                                                         AS mieszkancy_na_przychodnie
FROM dzielnice d
JOIN demografia_dzielnice dd
    ON dd.dzielnica_id = d.id AND dd.rok = 2023
ORDER BY d.nazwa;
