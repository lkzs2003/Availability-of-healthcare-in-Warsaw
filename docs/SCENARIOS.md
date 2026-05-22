# Scenariusze analityczne (S1–S6)

Każdy scenariusz to **drill-down**: Q1 = ogólny widok, kolejne Q coraz węższe, aż do konkretnej rekomendacji.

---

## S1 — Pustynie medyczne (7 zapytań)

**Pytanie**: Które obszary Warszawy leżą >1 km od najbliższej przychodni POZ i które dzielnice są najbardziej dotknięte?

**Klucz analityczny**: `ST_Difference(miasto, ST_Union(ST_Buffer(POZ, 1000)))` — odejmujemy od miasta sumę 1 km buforów wokół przychodni; reszta to "pustynia".

| # | Cel | Funkcje PostGIS |
|---|---|---|
| Q1 | Lista wszystkich POZ z X/Y w EPSG:2180 | `ST_X`, `ST_Y` |
| Q2 | Bufor 1 km wokół każdej przychodni | `ST_Buffer(geom, 1000)` |
| Q3 | Suma buforów = obszar pokryty (z MV) | `mv_pokrycie_poz_1km` |
| Q4 | **Fizyczna mapa pustyń** (kluczowy krok) | `ST_Difference(miasto, pokrycie)` |
| Q5 | km² pustyni per dzielnica | `ST_Area / 1e6` |
| Q6 | % powierzchni dzielnicy = pustynia | `ST_Area / powierzchnia_km2 * 100` |
| Q7 | Szacowana ludność na pustyniach + ranking | `RANK() OVER (ORDER BY ...)` |

**Wynik dla real-data**:
```
   nazwa   | pustynia_km2 | pustynia_pct
-----------+--------------+--------------
 Wilanów   |        30.68 |         83.6
 Wawer     |        65.80 |         82.6
 Białołęka |        55.60 |         76.2
 Bielany   |        22.44 |         69.5
 ...
```

**Interpretacja**: peryferyjne dzielnice (Wilanów, Wawer, Białołęka) mają 65–84% powierzchni poza zasięgiem 1 km od POZ. Centralne dzielnice (Śródmieście, Wola) — <10%.

**Założenie**: równomierne rozproszenie ludności w dzielnicy (jawnie odnotowane jako ograniczenie modelu).

---

## S2 — Dostępność SOR po sieci drogowej (6 zapytań)

**Pytanie**: Jaki jest czas dojazdu do najbliższego SOR z każdego punktu miasta po faktycznej sieci dróg?

**Klucz**: `pgr_drivingDistance(graf, vertex_szpitala, koszt_max, directed)`. Koszt = długość krawędzi w metrach; 50 km/h → 8 333 m = 10 min.

| # | Cel | Funkcje |
|---|---|---|
| Q1 | Lista SOR z koordynatami | `ST_X`, `ST_Y` |
| Q2 | Mapowanie szpitali na węzły grafu (KNN) | `<->` + `LATERAL LIMIT 1` |
| Q3 | Izochrona 10 min dla 1 szpitala | `pgr_drivingDistance(8333) + ST_ConcaveHull` |
| Q4 | Izochrony 5/10/15 min dla wszystkich SOR | `pgr_drivingDistance(array, 12500, true)` + `CASE WHEN` |
| Q5 | Siatka 500 m × 500 m: czas dojazdu do najbliższego SOR | `mv_sor_reachability` + `generate_series` |
| Q6 | Filtr: komórki >15 min = obszary krytyczne | `WHERE koszt_total_m > 12500` |

**Optymalizacja**: zamiast `dijkstra` z każdej z ~7 000 komórek (O(N × graf)) — robimy `drivingDistance` z 4 SOR z budżetem 25 km (O(H × graf)). Speedup ~1700×.

**Wynik z syntetycznym 5 km gridem**: koarse (88 vertices, 4 SOR często snapują się do tego samego węzła). **Dla realnej analizy** wymagane `./scripts/import_osm.sh`.

---

## S3 — Lokalizacja nowej przychodni POZ (5 zapytań)

**Pytanie**: Gdzie otworzyć nową przychodnię, aby maksymalnie poprawić dostępność?

**Klucz**: `ST_VoronoiPolygons` — strefa Voronoi to obszar najbliższy do danej istniejącej POZ. Im większa strefa, tym gorsza dostępność → tam warto otworzyć nową.

| # | Cel | Funkcje |
|---|---|---|
| Q1 | Diagram Voronoi (z MV) | `mv_voronoi_poz` |
| Q2 | Ranking stref wg powierzchni | `ORDER BY area_m2 DESC` |
| Q3 | Centroid największej strefy = top kandydat | `ST_Centroid`, `LIMIT 1` |
| Q4 | Szacunek mieszkańców w 1 km wokół kandydata | `ST_Intersection / ST_Area * ludnosc` |
| Q5 | Top 5 kandydatów z porównaniem | `row_number() OVER (... LIMIT 5)` |

**MV użyte**: `mv_voronoi_poz` — 25 komórek z indeksem `(area_m2 DESC)` przyspiesza wszystkie `ORDER BY ...`.

---

## S4 — Gęstość aptek względem ludności (4 zapytania)

**Pytanie**: Jaki jest stosunek liczby aptek do liczby mieszkańców per dzielnica?

| # | Cel | Funkcje |
|---|---|---|
| Q1 | Przestrzenny JOIN aptek z dzielnicami | `ST_Contains` |
| Q2 | COUNT aptek per dzielnica | `GROUP BY d.id` |
| Q3 | Wskaźnik mieszkańcy/apteka | `NULLIF` (bezpieczne dzielenie) |
| Q4 | Ranking + kwartyl (NTILE) | `RANK() OVER + NTILE(4) OVER` |

**Kluczowy fix logiczny**: Q4 wyłącza dzielnice z 0 aptek z `NTILE` (osobna kategoria `kwartyl=0` przez `UNION ALL`). Bez tego NULL z dzielenia trafiał w kwartyl 4 ("najlepsza dostępność") — fałszywie pozytywne.

**Wynik z real-data**:
```
     nazwa      | liczba_aptek | mieszkancy_na_apteke | kwartyl
----------------+--------------+----------------------+---------
 Śródmieście    |           59 |                 1661 |       4   (najlepsza)
 Ochota         |           32 |                 2480 |       4
 ...
 Białołęka      |           31 |                 5121 |       1   (najgorsza)
 Ursus          |           15 |                 4638 |       1
```

3× lepsza dostępność w Śródmieściu vs Białołęka.

---

## S5 — Najbliższa apteka od punktu (3 zapytania)

**Pytanie**: Gdzie jest najbliższa apteka od zadanego adresu? (Punkt referencyjny: Pałac Kultury i Nauki)

| # | Cel | Funkcje |
|---|---|---|
| Q1 | Apteki w 500 m z bbox prefilter | `geom && ST_Expand` + `ST_DWithin` |
| Q2 | 3 najbliższe (KNN) | `ORDER BY geom <-> :punkt` + `LIMIT 3` |
| Q3 | EXPLAIN ANALYZE z/bez GiST (`BEGIN/ROLLBACK`) | benchmark indeksu |

**Optymalizacja**: punkt referencyjny w `TEMP TABLE _s5_ref_point` zamiast `\set` (psql substitution) — `ST_Transform` wykonywane raz, nie 5 razy.

**Demonstracja KNN**: bez indeksu GiST `ORDER BY geom <-> point LIMIT 3` to Seq Scan z O(n) sortowaniem; z GiST to Index Scan z O(log n).

---

## S6 — Placówki w wybranej dzielnicy (2 zapytania)

**Pytanie**: Ile i jakie placówki są w wybranej dzielnicy?

| # | Cel | Funkcje |
|---|---|---|
| Q1 | Lista POZ w dzielnicy (parametr `:dzielnica_nazwa`) | `ST_Contains` + filter `WHERE d.nazwa = ?` |
| Q2 | Zbiorcze COUNT 3 typów placówek per dzielnica | **scalar subqueries** |

**Krytyczna optymalizacja**: zamiast `triple LEFT JOIN ... GROUP BY ... COUNT(DISTINCT)` (multiplikatywny wybuch — O(d×n×m×k)), używamy 3× scalar subqueries z `WHERE ST_Contains(d.geom, ...)` (O(d×(n+m+k))). Dla 18 dzielnic, 586 aptek, 231 POZ, 4 SOR: różnica ~5 tys. wierszy vs ~10 mln tymczasowych wierszy w pierwszym wariancie.

---

## Eksperymenty (E1–E6)

| # | Cel | Co mierzy | Plik |
|---|---|---|---|
| **E1** | Poprawność importu | Liczba rekordów, SRID, invalid geom, graph connectivity | `e1_data_import.sql` |
| **E2** | Poprawność 6 scenariuszy | Każdy scenariusz exit 0, brak ERROR | `run_experiment.sh 2` |
| **E3** | Wpływ indeksu GiST | EXPLAIN ANALYZE Q5.2 + Q1.4, N=10⁴, 10⁵ | `e3_gist_impact.sql` |
| **E4** | Wydajność pgRouting | Czas wykonania S2.5 dla siatki 500 m vs 1 km | `e4_pgrouting_perf.sql` |
| **E5** | Studium przypadku S1 | Materialised views z mapą pustyń + ranking | `e5_case_study_s1.sql` |
| **E6** | Powtarzalność środowiska | Czas od `docker compose down -v` do healthy DB | `run_experiment.sh 6` |

### Wyniki E6 (przykład)
```
=== E6: Reproducibility — clean rebuild timing ===
Elapsed: 13 seconds (target: < 900 s = 15 min)
```
**13 sekund** dla całego pipeline: pull image (cached) + start container + 5 init scripts + healthy → 69× szybciej niż target.

### Wyniki E3 (przykład — N=100k bench_points)
```
=== Q5.2 (KNN) — Z indeksem ===
  Index Scan using idx_bench_points_geom — 0.184 ms
  Limit cost=0.41..2.39

=== Q5.2 — BEZ indeksu ===
  Seq Scan on bench_points — 89.412 ms
  Sort cost=4117.83..4367.83
```
**~485× szybciej** z GiST dla `LIMIT 3` KNN na 100k punktach.
