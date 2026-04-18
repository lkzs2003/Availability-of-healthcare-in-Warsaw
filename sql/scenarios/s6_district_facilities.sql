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
--     (3× LEFT JOIN przestrzenny — apteki, przychodnie, SOR)
SELECT
    d.nazwa                         AS dzielnica,
    dd.ludnosc,
    COUNT(DISTINCT a.id)            AS liczba_aptek,
    COUNT(DISTINCT p.id)            AS liczba_przychodni_poz,
    COUNT(DISTINCT s.id)            AS liczba_sor,
    ROUND(dd.ludnosc::NUMERIC
          / NULLIF(COUNT(DISTINCT p.id), 0), 0) AS mieszkancy_na_przychodnie
FROM dzielnice d
JOIN demografia_dzielnice dd
    ON dd.dzielnica_id = d.id AND dd.rok = 2023
LEFT JOIN apteki a
    ON ST_Contains(d.geom, a.geom)
LEFT JOIN przychodnie_poz p
    ON ST_Contains(d.geom, p.geom)
LEFT JOIN szpitale_sor s
    ON ST_Contains(d.geom, s.geom)
GROUP BY d.id, d.nazwa, dd.ludnosc
ORDER BY d.nazwa;
