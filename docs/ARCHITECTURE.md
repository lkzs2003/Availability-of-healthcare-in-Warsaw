# Architektura systemu

## 1. Warstwy

```
┌─────────────────────────────────────────────────────────┐
│                      KLIENT (QGIS 3)                    │
│  · Add PostGIS Layer    · Add Virtual Layer (SQL)      │
│  · Styling/Symbology    · Print Layout                  │
└────────────────────────┬────────────────────────────────┘
                         │ TCP 5432 (loopback only)
                         │ PostgreSQL wire protocol
┌────────────────────────▼────────────────────────────────┐
│              POSTGRESQL 16 + POSTGIS 3.4                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │   Tabele     │  │  Widoki MV   │  │   Triggery   │   │
│  │              │  │              │  │              │   │
│  │  7 tabel     │  │ 3 MV (S1/S2  │  │ 5 CONSTRAINT │   │
│  │  domenowych  │  │  /S3) z idx  │  │ TRIGGER —    │   │
│  │  + 4 indeksy │  │  GiST/B-Tree │  │ auto-refresh │   │
│  │  GiST + B-T  │  │              │  │ MV           │   │
│  └──────────────┘  └──────────────┘  └──────────────┘   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ 6 scenariu-  │  │ 5 eksperymen │  │ pgRouting    │   │
│  │ szy SQL      │  │ tów SQL      │  │ topo + algo  │   │
│  │ (drill-down) │  │ (E1/E3-E6)   │  │              │   │
│  └──────────────┘  └──────────────┘  └──────────────┘   │
└─────────────────────────────────────────────────────────┘
                         ▲
                         │ docker-entrypoint-initdb.d (5 plików)
                         │ docker volume mount /sql
┌────────────────────────┴────────────────────────────────┐
│                       DOCKER COMPOSE                    │
│  · db   (PostGIS image + osm2pgrouting + osmium)        │
│  · pgadmin (UI w przeglądarce, loopback only)           │
└─────────────────────────────────────────────────────────┘
                         ▲
                         │ scripts/lib/fetch_real_data.py
                         │ HTTP + cache (data/cache/)
┌────────────────────────┴────────────────────────────────┐
│              ZEWNĘTRZNE ŹRÓDŁA DANYCH                   │
│  · GUS BDL API           — ludność 2023                │
│  · OSM Overpass API      — apteki / POZ / SOR / granice│
│  · Geofabrik             — sieć drogowa (PBF)          │
│  · RPWDL (opcjonalnie)   — rejestr placówek (ref)      │
└─────────────────────────────────────────────────────────┘
```

## 2. Kolejność inicjalizacji bazy

PostgreSQL automatycznie uruchamia pliki z `/docker-entrypoint-initdb.d/` w kolejności alfabetycznej:

| # | Plik | Czas | Rola |
|---|---|---|---|
| 1 | `01_extensions.sql`        | <1 s | `CREATE EXTENSION postgis, postgis_topology, pgrouting` |
| 2 | `02_schema.sql`            | <1 s | 7 tabel + 1 view (warszawa_bbox) + 8 indeksów + 3 FK |
| 3 | `03_seed_data.sql`         | ~2 s | Voronoi 18 dzielnic + 25 POZ + 5 SOR + 40 aptek + grid 5 km |
| 4 | `04_materialized_views.sql` | <1 s | 3 MV + 4 indeksy (1 UNIQUE → CONCURRENTLY) |
| 5 | `05_refresh_triggers.sql`  | <1 s | 5 CONSTRAINT TRIGGERS DEFERRED |

**Total cold start**: ~13 sekund (target z dokumentacji wstępnej: <900 s = 15 min — spełnione 69×).

## 3. Diagram danych (encje)

```
       dzielnice (18) ◄───────────┐
       │ id, nazwa, geom MULTIPOLYGON│
       │ powierzchnia_km2           │
       └────────┬───────────────────┘
                │ 1:1
                ▼
  demografia_dzielnice (18)
  ├── dzielnica_id FK
  ├── rok (2023)
  ├── ludnosc INT NOT NULL
  └── gestosc_os_km2

  przychodnie_poz (231)   szpitale_sor (4)   apteki (586)
  ├── id SERIAL           ├── id              ├── id
  ├── nazwa TEXT          ├── nazwa           ├── nazwa
  ├── adres               ├── adres           ├── adres
  ├── nr_rpwdl            └── geom POINT      └── geom POINT
  └── geom POINT 2180         2180                2180

  drogi_vertices (88)  ────────┐
  ├── id BIGINT PRIMARY KEY     │
  └── geom POINT 2180           │ FK DEFERRABLE
                                │ INITIALLY DEFERRED
  drogi_topo (157) ◄────────────┘
  ├── id BIGSERIAL
  ├── source BIGINT NOT NULL
  ├── target BIGINT NOT NULL
  ├── cost DOUBLE PRECISION NOT NULL  (metres)
  ├── reverse_cost (nullable; -1 dla oneway)
  └── geom LINESTRING 2180
```

Liczby w nawiasach: ile rekordów po `./scripts/import_real_data.sh`.

## 4. Materialised views (3)

| MV | Źródło | Wymiar | Indeks | Użycie |
|---|---|---|---|---|
| `mv_pokrycie_poz_1km`     | `przychodnie_poz`            | 1 row (geometria łączona) | GiST | S1 Q3–Q7 (zamiast 4× `ST_Union(ST_Buffer(...))`) |
| `mv_voronoi_poz`          | `przychodnie_poz` + `dzielnice` | 25 rows (cells)        | GiST + UNIQUE(cell_id) + B-Tree(area_m2) | S3 Q1–Q5 (zamiast 5× pipeline pts/envelope/voronoi/miasto) |
| `mv_sor_reachability`     | `szpitale_sor` + `drogi_topo` | ~7 000 rows (vertex→cost) | UNIQUE(vertex_id) | S2 Q5–Q6 (zamiast 2× pełny `pgr_drivingDistance`) |

Każdy MV ma `CONSTRAINT TRIGGER DEFERRED` na tabelach źródłowych — automatyczny refresh po commit. Triggery są **wyłączane** przy bulk-load (`import_real_data.sh`) i włączane ponownie z pojedynczym `REFRESH MATERIALIZED VIEW` na końcu, by uniknąć N refreshów per row.

## 5. Strategie optymalizacji

| Problem | Rozwiązanie | Zysk |
|---|---|---|
| **Powtórzony CTE w 4 zapytaniach S1** | `mv_pokrycie_poz_1km` z indeksem GiST | ~10× szybciej dla S1 |
| **Powtórzony 5× pipeline Voronoi w S3** | `mv_voronoi_poz` z indeksem B-Tree na area_m2 DESC | ~6× szybciej dla S3 |
| **Naiwne S2 Q5: dijkstra z każdej z 7000 komórek** | Odwrócona strategia: `pgr_drivingDistance` z 4 SOR | O(H × graf) zamiast O(N × graf), ~1700× szybciej |
| **Triple LEFT JOIN w S6 Q2 → O(d×n×m×k)** | Scalar subqueries → O(d×(n+m+k)) | Brak row-multiplication, 100× szybciej |
| **`ROUND(SUM(...))` per row akumuluje błąd** | `ROUND` po `SUM` na poziomie agregacji | Eliminuje błąd ±9 osób w S3 Q5 |
| **`DROP INDEX` permanentnie modyfikuje schemat** | `BEGIN; DROP INDEX; EXPLAIN; ROLLBACK;` | Bezpieczny benchmark, indeks zachowany |
| **KNN snap distance ukryty w pgRouting** | Surfacing `snap_m` jawnie w wyniku S2 Q5 | Użytkownik widzi rzeczywisty koszt total |

## 6. Założenia projektowe

- **EPSG:2180 (PL-1992)** — natywne metry; wszystkie `ST_Distance/ST_DWithin/ST_Buffer` zwracają wynik w metrach bez ręcznej konwersji.
- **BIGINT w grafie** — `drogi_vertices.id`, `drogi_topo.source/target` zgodne z return-types pgRouting (`pgd.node BIGINT`). Brak rzutowania = brak przesunięć wydajności.
- **FK DEFERRABLE INITIALLY DEFERRED** — pozwala bulk-load (`INSERT vertices` → `INSERT edges`) w tej samej transakcji bez utraty integralności.
- **Triggery jako CONSTRAINT TRIGGER DEFERRED** — refresh MV raz per commit, nie raz per row.
- **Synthetic seed = 5 km grid (88 vertices)** — start-up bez I/O; do realnej analizy `import_osm.sh` zastępuje na pełny graf OSM (~10⁵ krawędzi).
- **Voronoi vs PRG** — seed używa Voronoi (gwarantuje nieprzecięcia); produkcja używa OSM admin_level=9 (matches PRG).

## 7. Bezpieczeństwo

- Porty wystawione tylko na `127.0.0.1` — brak ekspozycji na LAN/internet (`docker-compose.yml`).
- Hasła przekazywane przez `PGPASSWORD` env, **nigdy** w argumentach CLI (`scripts/import_osm.sh`).
- `.env.example` ma jawne ostrzeżenie żeby zmienić wartości przed pierwszym uruchomieniem.
- FK + NOT NULL zapobiega corrupt graph rows które mogłyby crashować pgRouting.
- Wszystkie INSERT-y z fetcher'a używają `''` escapingu w `sql_str()` — brak SQL injection nawet dla danych OSM o niekontrolowanej zawartości.
