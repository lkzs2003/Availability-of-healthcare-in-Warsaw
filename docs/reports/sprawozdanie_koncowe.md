# Sprawozdanie końcowe — Dostępność opieki zdrowotnej w Warszawie

**Projekt SPDB · Wielokrokowa analiza przestrzenna PostgreSQL + PostGIS + pgRouting**
**Autorzy:** Łukasz Siemionek, Piotr Liszewski
**Branch:** `feature/enrich-and-refactor-healthcare`
**Data:** 2026-05-24

---

## 1. Wstęp i cel analiz

### Domena
Praca analizuje **przestrzenną dostępność ochrony zdrowia** w 18 dzielnicach m.st. Warszawy. Pod uwagę bierzemy trzy kategorie placówek:

- **POZ** — przychodnie podstawowej opieki zdrowotnej (źródło: OSM `healthcare=clinic`, proxy dla rejestru RPWDL),
- **SOR** — Szpitalne Oddziały Ratunkowe (zweryfikowana lista 14 funkcjonujących SOR z NFZ + RPWDL),
- **apteki** — placówki obrotu detalicznego lekami (OSM `amenity=pharmacy`, dane z 2026-05-24).

### Cele techniczne
1. **Identyfikacja "pustyń medycznych"** — obszarów Warszawy oddalonych >1 km od najbliższej POZ (`ST_Buffer` + `ST_Difference`).
2. **Modelowanie dostępności SOR po realnej sieci drogowej** — izochrony 5/10/15 min od każdego z 14 SOR (`pgr_drivingDistance` + `ST_ConcaveHull`).
3. **Wskazanie lokalizacji nowej przychodni POZ** — analiza Voronoia + selekcja centroidów największych stref (`ST_VoronoiPolygons`).
4. **Ranking dzielnic według gęstości aptek per capita** — kwartyle (`NTILE(4)`) z poprawnym handlingiem zer.
5. **Wyszukiwanie najbliższych aptek** — KNN z indeksu GiST (operator `<->`), benchmark `EXPLAIN ANALYZE`.
6. **Agregacja placówek dla zadanej dzielnicy** — scalar subqueries zamiast `LEFT JOIN`-ów.

### Stos technologiczny
- PostgreSQL **16** + PostGIS **3.4** + pgRouting **3.x**
- EPSG:**2180** (PL-1992) — natywne metry, bez ręcznej konwersji jednostek
- QGIS 3.x jako klient wizualizacji (DB Manager + virtual layers)
- Docker Compose v2 (port `127.0.0.1:5432` — bez ekspozycji na świat)

---

## 2. Schemat danych

Baza zawiera **7 tabel bazowych** i **3 materialised views** (auto-refresh przez `CONSTRAINT TRIGGER DEFERRED`).

### Diagram logiczny

```
┌────────────────┐          ┌──────────────────────┐
│   dzielnice    │ 1 ────∞  │ demografia_dzielnice │
│ (18 polygonów) │          │   (18 wierszy, 2023) │
└────────┬───────┘          └──────────────────────┘
         │ ST_Contains
         ├──────────────┬───────────────┬───────────────┐
         ▼              ▼               ▼               ▼
┌─────────────────┐  ┌────────────┐  ┌──────────────┐
│ przychodnie_poz │  │   apteki   │  │ szpitale_sor │
│  (231 punktów)  │  │ (582 pkty) │  │  (14 SOR)    │
└─────────────────┘  └────────────┘  └──────────────┘
                                          │ snap to graph
                                          ▼
                      ┌──────────────────────────────┐
                      │   drogi_topo (157 krawędzi)  │
                      │  ── source/target/cost ──    │
                      │   drogi_vertices (88 węzłów) │
                      └──────────────────────────────┘
                                  │
                                  │ pgr_drivingDistance
                                  ▼
                      ┌──────────────────────────────┐
                      │  mv_sor_reachability (MV)    │
                      └──────────────────────────────┘
```

### Słownik tabel

| Tabela | Klucz | Typ geometrii | Kolumny |
|---|---|---|---|
| `dzielnice` | `id SERIAL PK` | `MULTIPOLYGON(2180)` | `nazwa UNIQUE`, `powierzchnia_km2`, `geom NOT NULL` |
| `demografia_dzielnice` | `id SERIAL PK` | — | `dzielnica_id FK→dzielnice`, `rok DEFAULT 2023`, `ludnosc`, `gestosc_os_km2`, UNIQUE `(dzielnica_id, rok)` |
| `przychodnie_poz` | `id SERIAL PK` | `POINT(2180)` | `nazwa`, `adres`, `nr_rpwdl`, **`dzielnica VARCHAR(50)`** (V1.1), `geom` |
| `szpitale_sor` | `id SERIAL PK` | `POINT(2180)` | `nazwa`, `adres`, **`dzielnica VARCHAR(50)`** (V1.1), `geom` |
| `apteki` | `id SERIAL PK` | `POINT(2180)` | `nazwa`, `adres`, **`dzielnica VARCHAR(50)`** (V1.1), `geom` |
| `drogi_vertices` | `id BIGINT PK` | `POINT(2180)` | węzły grafu pgRouting |
| `drogi_topo` | `id BIGSERIAL PK` | `LINESTRING(2180)` | `source BIGINT FK`, `target BIGINT FK`, `cost`, `reverse_cost` (oba = `ST_Length(geom)`) |

### Zmaterializowane widoki

| MV | Definicja | Rozmiar | Refresh trigger |
|---|---|---|---|
| `mv_pokrycie_poz_1km` | `ST_Union(ST_Buffer(POZ.geom, 1000))` | 1 wiersz, ~50 kB | po INSERT/UPDATE/DELETE na `przychodnie_poz` |
| `mv_voronoi_poz` | komórki Voronoia POZ przycięte do granicy miasta | 231 wierszy | po INSERT/UPDATE/DELETE na POZ lub dzielnicach |
| `mv_sor_reachability` | `pgr_drivingDistance(directed=true, reverse_cost)` z budżetem 25 km, source = vertex najbliższy SOR | 14 × ~6 wierszy | po zmianie SOR lub grafu |

---

## 3. Charakterystyka danych przestrzennych

### Statystyki bazy (stan po migracji V1.2)

| Element | Wartość |
|---|---|
| Rozmiar bazy `warszawa_health` | **44 MB** |
| Liczba tabel | 7 (+ 3 MV + bench_points + topology meta) |
| Liczba indeksów (schemat `public`) | **34** (9 GiST + 25 B-Tree/UNIQUE) |
| CRS | **EPSG:2180** (PL-1992, jednostka: metr) |
| Bbox Warszawy (xmin/ymin/xmax/ymax) | 630 000 / 490 000 / 680 000 / 525 000 |
| Suma powierzchni dzielnic | 516.8 km² (99.9% PRG) |

### Liczność danych

| Tabela | Wierszy | Rozmiar | Walidacja |
|---|---:|---:|---|
| `dzielnice` | 18 | 320 kB | OSM admin_level=9, ST_IsValid = TRUE |
| `demografia_dzielnice` | 18 | — | GUS 2023 + auto-kalkulacja gęstości z `ST_Area` |
| `przychodnie_poz` | 231 | — | 0 invalid, 100% w granicach miasta |
| `apteki` | **582** | 320 kB | 91 outsiderów (Marki/Pruszków/Piaseczno) usunięte w V1.2 |
| `szpitale_sor` | **14** | 72 kB | pełna lista z NFZ + RPWDL |
| `drogi_topo` | 157 | 152 kB | 1 spójna składowa, cost = ST_Length |
| `drogi_vertices` | 88 | 40 kB | siatka 5 km (do `import_osm.sh` → ~10⁵) |

### Typy geometrii

| Tabela | Typ | SRID |
|---|---|---|
| `dzielnice.geom` | `MULTIPOLYGON` | 2180 |
| `przychodnie_poz/apteki/szpitale_sor.geom` | `POINT` | 2180 |
| `drogi_topo.geom` | `LINESTRING` | 2180 |
| `drogi_vertices.geom` | `POINT` | 2180 |
| `mv_voronoi_poz.geom` | `POLYGON` | 2180 |

---

## 4. Indeksy przestrzenne i nieprzestrzenne

Pełna lista 34 indeksów w schemacie `public`. Zaznaczone **pogrubieniem** to indeksy dodane lub potwierdzone w migracji V1.1.

### Indeksy GiST (geometryczne — wsparcie KNN `<->`, `ST_Contains`, `ST_DWithin`)

| Indeks | Tabela | Kolumna | Cel |
|---|---|---|---|
| **`idx_dzielnice_geom`** | dzielnice | geom | spatial join z punktami (POZ/apteki/SOR) |
| **`idx_przychodnie_geom`** + `idx_przychodnie_poz_geom` | przychodnie_poz | geom | S1 buffer, S3 Voronoi, S5 KNN |
| **`idx_apteki_geom`** | apteki | geom | S4, S5 KNN (`<->`) |
| **`idx_szpitale_sor_geom`** | szpitale_sor | geom | S2 routing, snap to graph |
| **`idx_drogi_topo_geom`** | drogi_topo | geom | S2/E4 pgRouting |
| **`idx_drogi_vertices_geom`** | drogi_vertices | geom | snap (`<->` SOR → węzeł) |
| `idx_mv_pokrycie_poz_1km_geom` | mv_pokrycie_poz_1km | geom | E5 S1 case study |
| `idx_mv_voronoi_poz_geom` | mv_voronoi_poz | geom | S3 kandydaci |
| `idx_bench_points_geom` | bench_points | geom | E3 benchmark GiST |

### Indeksy B-Tree (atrybutowe, FK, UNIQUE)

| Indeks | Tabela | Kolumna(y) | Cel |
|---|---|---|---|
| `*_pkey` (×7) | wszystkie | id | klucze główne |
| `dzielnice_nazwa_key` + **`idx_dzielnice_nazwa`** | dzielnice | nazwa | filtr po nazwie (S6) |
| **`idx_przychodnie_dzielnica`** | przychodnie_poz | dzielnica | S4/S6 GROUP BY |
| **`idx_apteki_dzielnica`** | apteki | dzielnica | S4 ranking, S6 |
| **`idx_szpitale_sor_dzielnica`** | szpitale_sor | dzielnica | raporty per dzielnica |
| **`idx_demografia_rok`** | demografia_dzielnice | rok | filtr `WHERE rok = 2023` |
| `demografia_dzielnice_dzielnica_id_rok_key` | demografia | (dzielnica_id, rok) | UNIQUE — wsparcie ON CONFLICT |
| **`idx_drogi_topo_source`**, **`idx_drogi_topo_target`** | drogi_topo | source, target | pgRouting graph traversal |
| `idx_przychodnie_poz_rpwdl` | przychodnie_poz | nr_rpwdl | identyfikacja po RPWDL |
| `idx_apteki_nazwa`, `idx_szpitale_sor_nazwa` | apteki/SOR | nazwa | wyszukiwanie tekstowe |
| `idx_mv_voronoi_poz_cell` | mv_voronoi_poz | cell_id | UNIQUE — wsparcie `REFRESH ... CONCURRENTLY` |
| `idx_mv_voronoi_poz_area` | mv_voronoi_poz | area_m2 | S3 sortowanie po wielkości strefy |
| `idx_mv_sor_reachability_vertex` | mv_sor_reachability | node | snap-to-vertex w S2 Q5/Q6 |

**Łącznie:** 9 GiST + 25 B-Tree/UNIQUE = **34 indeksy**.

---

## 5. Mapowanie wymagań projektowych na zapytania SQL

Tabela udowadnia, że projekt pokrywa wszystkie cztery klasy analiz przestrzennych wymaganych w instrukcji.

| # | Wymaganie instrukcji | Scenariusz / zapytanie | Klucz analityczny |
|---|---|---|---|
| **1** | **Analiza w zadanym poligonie** | **S6 Q1** (POZ w Mokotowie) + **S4** (agregacja aptek per dzielnica) | `ST_Contains(d.geom, p.geom)` |
| **2** | **Zdarzenia w określonym przedziale czasowym** | S3 (referencja do `demografia_dzielnice`), wszystkie scenariusze filtrujące dane GUS | `WHERE rok = 2023` |
| **3** | **Zastosowanie bufora** | **S1** (`ST_Buffer(POZ, 1000)` → pokrycie 1 km) + **S3 Q5** (zasięg 1 km kandydata) | `ST_Buffer` + `ST_Union` + `ST_Difference` |
| **4** | **Identyfikacja najbliższych sąsiadów** | **S5** (3 najbliższe apteki, KNN) + **S2 Q2** (snap SOR do węzła grafu) | KNN operator `<->` na GiST |

### Dowody — wyniki rzeczywiste

**Wymaganie 1 — analiza w poligonie (S6, Mokotów):**
```sql
SELECT COUNT(*) FROM przychodnie_poz WHERE dzielnica = 'Mokotów';
-- 35
```

**Wymaganie 2 — filtrowanie czasowe:**
```sql
SELECT dem.ludnosc FROM demografia_dzielnice dem
JOIN dzielnice d ON d.id = dem.dzielnica_id
WHERE d.nazwa = 'Śródmieście' AND dem.rok = 2023;
-- 101 000
```

**Wymaganie 3 — bufor 1 km (S1, top-5 pustyń medycznych):**

| Dzielnica | % pustyni medycznej |
|---|---:|
| Wilanów | 83.6% |
| Wawer | 82.6% |
| Białołęka | 76.2% |
| Bielany | 69.5% |
| Rembertów | 68.1% |

**Wymaganie 4 — KNN (S5, 3 najbliższe apteki od Pl. Defilad):**

| Apteka | Adres | Dzielnica | Odległość [m] |
|---|---|---|---:|
| Super-Pharm | Złota 59 | Śródmieście | 278 |
| Wawa | — | Śródmieście | 302 |
| Cosmedica | Śliska 3 | Śródmieście | 340 |

---

## 6. Instrukcja wizualizacji wyników w QGIS

### 6.1. Konfiguracja połączenia PostGIS

1. Uruchom QGIS 3.x.
2. **Panel Browser → PostGIS → New Connection…** → wprowadź:
   - **Name:** `Warszawa Health`
   - **Host:** `localhost` (lub `127.0.0.1`)
   - **Port:** `5432`
   - **Database:** `warszawa_health`
   - **Authentication → Basic:** `User: postgres`, `Password: postgres`
   - Zaznacz: `Also list tables with no geometry`, `Use estimated table metadata`
3. **Test Connection** → musi zwrócić *"Connection to … was successful."*
4. **OK** → połączenie pojawia się w panelu Browser.

### 6.2. Wczytanie warstw bazowych

Z panelu Browser przeciągnij na mapę:
- `public.dzielnice` (poligon — kontekst administracyjny),
- `public.drogi_topo` (linie — sieć drogowa),
- `public.przychodnie_poz`, `public.apteki`, `public.szpitale_sor` (punkty).

Wszystkie warstwy w EPSG:2180; QGIS sam ustawi CRS projektu na PL-1992.

### 6.3. Wczytanie zapytań SQL (DB Manager)

1. **Database → DB Manager…** → wybierz `Warszawa Health`.
2. **SQL Window** (ikona klucza francuskiego) → wklej zapytanie z `qgis/sql_layers/sX_*.sql`.
3. **Execute** → sprawdź wynik w tabeli.
4. **Load as new layer** → ustaw:
   - **Column with unique values:** `id`
   - **Geometry column:** `geom`
   - **Geometry type:** `Polygon` / `Linestring` / `Point` (zgodnie z zapytaniem)
   - **Layer name:** np. `S1_pustynie_medyczne`
5. **Load** → warstwa pojawia się na mapie.

### 6.4. Sugerowane style wizualizacji

| Warstwa | Renderer QGIS | Parametry |
|---|---|---|
| **S1 — pustynie medyczne** | Single Symbol | wypełnienie czerwone, opacity 40% |
| **S2 — izochrony 5/10/15 min** | Categorized (po polu `min`) | gradient zielony→żółty→czerwony |
| **S3 — kandydaci POZ** | Graduated (po polu `area_m2`) | Natural Breaks (5 klas), gradient niebieski |
| **S4 — kwartyle aptek** | Categorized (po polu `kwartyl`) | 4 klasy: zielony / żółty / pomarańczowy / czerwony |
| **S5 — najbliższe apteki** | Single Symbol + Label | wyświetl `odl_m` jako etykietę |
| **S6 — placówki dzielnicy** | Multi-layer (POZ, apteki, SOR) | różne kształty/kolory per typ |

### 6.5. Atlas i eksport

- **Project → Layout Manager → New Print Layout** → załaduj mapę + legendę + tytuł.
- **Atlas → Coverage Layer:** `dzielnice` → automatyczna seria 18 map (po jednej na dzielnicę).
- Export PNG (300 dpi) lub PDF.

---

## 7. Wybrane zapytania testowe — wyniki rzeczywiste

### 7.1. S5 — KNN, 3 najbliższe apteki od punktu (Pałac Kultury)

```sql
-- EPSG:2180 — odległości natywnie w metrach
WITH pkt AS (
    SELECT ST_Transform(ST_SetSRID(ST_Point(21.0067, 52.2319), 4326), 2180) AS g
)
SELECT a.nazwa, a.adres, a.dzielnica,
       ROUND(ST_Distance(a.geom, pkt.g)::numeric, 0) AS odl_m
  FROM apteki a, pkt
 ORDER BY a.geom <-> pkt.g     -- operator KNN — używa idx_apteki_geom
 LIMIT 3;
```

Wynik patrz tabela w §5 (Wymaganie 4). Komentarz: wszystkie 3 apteki w promieniu 340 m, w Śródmieściu — gęsta zabudowa, idealne pokrycie centrum.

### 7.2. S4 — Ranking dzielnic po dostępności aptek

```sql
SELECT d.nazwa,
       COUNT(a.id) AS apteki,
       dem.ludnosc,
       ROUND(dem.ludnosc::numeric / NULLIF(COUNT(a.id), 0), 0) AS mieszk_na_apteke,
       NTILE(4) OVER (ORDER BY dem.ludnosc::numeric / NULLIF(COUNT(a.id), 0)) AS kwartyl
  FROM dzielnice d
  LEFT JOIN apteki a ON a.dzielnica = d.nazwa
  JOIN demografia_dzielnice dem ON dem.dzielnica_id = d.id AND dem.rok = 2023
 GROUP BY d.nazwa, dem.ludnosc
 ORDER BY mieszk_na_apteke;
```

| # | Dzielnica | Apteki | Ludność | Mieszk./aptekę | Kwartyl |
|---|---|---:|---:|---:|---|
| 1 | **Śródmieście** | 59 | 101 000 | **1 712** | Q1 (najlepsza) |
| 2 | Wola | 56 | 142 000 | 2 536 | Q1 |
| 3 | Praga-Północ | 24 | 61 000 | 2 542 | Q1 |
| 4 | Ochota | 32 | 82 000 | 2 563 | Q1 |
| 5 | Praga-Południe | 61 | 179 000 | 2 934 | Q2 |
| … | … | … | … | … | … |
| 16 | Bemowo | 32 | 125 000 | 3 906 | Q4 |
| 17 | Ursus | 15 | 66 000 | 4 400 | Q4 |
| 18 | **Białołęka** | 31 | 154 000 | **4 968** | Q4 (najgorsza) |

**Wniosek:** **2.9× różnica** między najlepszą (Śródmieście) a najgorszą (Białołęka) dzielnicą.

### 7.3. S1 — Pustynia medyczna (bufor 1 km wokół POZ)

```sql
WITH pustynia AS (
    SELECT d.nazwa,
           ST_Area(ST_Difference(d.geom, (SELECT geom FROM mv_pokrycie_poz_1km)))
           / ST_Area(d.geom) * 100 AS pct
      FROM dzielnice d
)
SELECT nazwa, ROUND(pct::numeric, 1) AS pustynia_pct
  FROM pustynia
 ORDER BY pct DESC;
```

Wyniki — patrz §5 (Wymaganie 3). Komentarz: dzielnice z dużymi terenami leśnymi/parkowymi (Wilanów, Wawer — Mazowiecki Park Krajobrazowy) mają największe pustynie, ale to artefakt modelu (ludność równomierna w dzielnicy). W realnym scenariuszu wagi powinny uwzględniać użytkowanie terenu (CORINE Land Cover).

### 7.4. Dostępność SOR per dzielnica

```sql
SELECT d.nazwa, COUNT(s.id) AS sor
  FROM dzielnice d LEFT JOIN szpitale_sor s ON s.dzielnica = d.nazwa
 GROUP BY d.nazwa
 ORDER BY sor DESC, d.nazwa;
```

**Dzielnice z 0 SOR (8 z 18):** Bemowo, Białołęka, Rembertów, Ursus, Wesoła, Wilanów, Włochy, Żoliborz.
**Dzielnice z najlepszą obsługą:** Ochota (3), Mokotów (2), Wawer (2).

---

## 8. Wyniki eksperymentów wydajnościowych (E1–E6)

| # | Cel | Metoda | Wynik |
|---|---|---|---|
| **E1** | Poprawność importu danych | walidacja schematu, ST_IsValid, connectivity | 0 invalid, SRID=2180, 1 spójna składowa |
| **E2** | Poprawność 6 scenariuszy | end-to-end run S1–S6 | **6/6 OK** (exit 0) |
| **E3** | Wpływ indeksu GiST | `EXPLAIN ANALYZE` KNN dla N=10⁴, 10⁵ | **~485× speedup** (Seq Scan → Index Scan) |
| **E4** | Wydajność pgRouting | siatka 500 m vs 1 km | różnica 6.8×; dla 5 km grid: <1 s na SOR |
| **E5** | S1 jako MV | porównanie czasu z CTE-w-zapytaniu vs `mv_pokrycie_poz_1km` | 4× szybsze przez MV (1 wiersz cache) |
| **E6** | Powtarzalność środowiska | `docker compose down && up -d` | **13 s** vs target 900 s (**69× margines**) |

### Komentarz analityczny

- **GiST jest niezbędny przy N ≥ 10⁴** — przyrost kosztu Seq Scan jest kwadratowy względem N punktów (każdy punkt vs każdy poligon).
- **pgRouting drivingDistance** jest **~1700× szybszy niż naiwny Dijkstra z każdej komórki** — strategia "odwrócona" (start z 14 SOR) zamiast "z każdej komórki do najbliższego SOR".
- **Materialised views z `CONSTRAINT TRIGGER DEFERRED`** eliminują 9× duplikację `ST_Union(ST_Buffer(...))` i utrzymują spójność automatycznie po każdym INSERT/UPDATE/DELETE.

---

## 9. Pliki dostarczone w migracji V1.1 / V1.2

| Plik | Linie | Cel |
|---|---:|---|
| `sql/migrations/V1.1__enrich_healthcare_and_demographics.sql` | 196 | DDL + dane GUS 2023 + 14 SOR + spatial join + indeksy |
| `sql/migrations/V1.2__cleanup_out_of_warsaw_points.sql` | 49 | usunięcie 91 outsiderów (bbox > granica miasta) |
| `scripts/import_apteki.sh` | 121 | Overpass API + JSON → INSERT (z reprojekcją 4326→2180) |
| `docs/reports/sprawozdanie_koncowe.md` | (ten plik) | sprawozdanie końcowe |

### Uruchomienie pełnego pipeline'u

```bash
git checkout feature/enrich-and-refactor-healthcare
docker compose up -d --build

# 1. Realne apteki z OSM (582 wpisy po cleanup)
./scripts/import_apteki.sh

# 2. Migracja wzbogacająca (GUS 2023 + 14 SOR + spatial join)
docker compose exec -T db psql -U postgres -d warszawa_health \
    -v ON_ERROR_STOP=1 < sql/migrations/V1.1__enrich_healthcare_and_demographics.sql

# 3. Usunięcie placówek spoza granic Warszawy
docker compose exec -T db psql -U postgres -d warszawa_health \
    -v ON_ERROR_STOP=1 < sql/migrations/V1.2__cleanup_out_of_warsaw_points.sql

# 4. Walidacja
docker compose exec -T db psql -U postgres -d warszawa_health -c "
    SELECT typ, COUNT(*), COUNT(dzielnica), COUNT(*) - COUNT(dzielnica) AS bledy
    FROM ( SELECT 'SOR' typ, dzielnica FROM szpitale_sor
           UNION ALL SELECT 'POZ', dzielnica FROM przychodnie_poz
           UNION ALL SELECT 'Apteka', dzielnica FROM apteki ) r
    GROUP BY typ;"
# Oczekiwane: bledy = 0 dla wszystkich kategorii.
```

---

## 10. Ograniczenia świadome i kierunki rozwoju

- **Model ludności** — równomierne rozproszenie w obrębie dzielnicy. Wpływa na S1 (% pustyni medycznej zawyżony dla dzielnic z lasami) i S3 (kandydaci POZ).
  *Rozwój:* integracja CORINE Land Cover + danych spisowych GUGiK (siatka 1 km).
- **Siatka drogowa 5 km (seed)** — minimalny graf do testów. Realne izochrony wymagają `./scripts/import_osm.sh` (~10⁵ krawędzi z Geofabrik).
- **POZ z OSM** — best-effort proxy dla RPWDL. Pełny rejestr wymaga autoryzowanego dostępu lub parsowania HTML.
- **Apteki — outsiderzy bbox** — 91 placówek (Marki, Pruszków, Piaseczno, Legionowo) usuniętych w V1.2. Ostatecznie 582 apteki = wartość zgodna z liczbami z 2023 (~570–600 w granicach Warszawy).

---

## 11. Atrybucja

- **OpenStreetMap** — dane © OpenStreetMap contributors, licencja **ODbL 1.0** (apteki, POZ, dzielnice, sieć drogowa).
- **GUS BDL** — Bank Danych Lokalnych, dane publiczne (populacja 2023, var-id `72305`).
- **NFZ / RPWDL** — Narodowy Fundusz Zdrowia + Rejestr Podmiotów Wykonujących Działalność Leczniczą (lista SOR).
- **GUGiK / PRG** — Państwowy Rejestr Granic (walidacja pola powierzchni dzielnic).
