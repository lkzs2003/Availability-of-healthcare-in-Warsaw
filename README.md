# Dostępność opieki zdrowotnej w Warszawie — projekt SPDB

Wizualizacja analitycznych zapytań przestrzennych SQL — dostępność opieki zdrowotnej w Warszawie
Łukasz Siemionek, Piotr Liszewski · kwiecień 2026

## Opis

Projekt demonstruje wielokrokową analizę przestrzenną prowadzoną w czystym SQL
z PostgreSQL + PostGIS + pgRouting. Wyniki wizualizowane są bezpośrednio w QGIS
podłączonym do bazy danych. Cała logika analityczna znajduje się w bazie.

**Domena:** dostępność opieki zdrowotnej w 18 dzielnicach m.st. Warszawy
**Układ współrzędnych:** EPSG:2180 (PL-1992)

## Struktura projektu

```
.
├── Dockerfile                  # PostgreSQL 16 + PostGIS 3.4 + pgRouting
├── docker-compose.yml          # db + pgAdmin
├── .dockerignore
├── .env.example                # zmienne środowiskowe
├── sql/
│   ├── init/                   # skrypty auto-wykonywane przy starcie kontenera
│   │   ├── 01_extensions.sql   # PostGIS, pgRouting
│   │   ├── 02_schema.sql       # 7 tabel + indeksy GiST (BIGINT w grafie)
│   │   └── 03_seed_data.sql    # syntetyczne dane (Voronoi dla dzielnic)
│   ├── scenarios/              # 6 scenariuszy analitycznych (drill-down)
│   │   ├── s1_medical_deserts.sql       # 7 zapytań
│   │   ├── s2_sor_routing.sql           # 6 zapytań (auto-wybór wierzchołka)
│   │   ├── s3_new_clinic_location.sql   # 5 zapytań
│   │   ├── s4_pharmacy_density.sql      # 4 zapytania
│   │   ├── s5_nearest_pharmacy.sql      # 3 zapytania
│   │   └── s6_district_facilities.sql   # 2 zapytania (scalar subqueries)
│   └── experiments/            # eksperymenty E1–E6 z dokumentacji
│       ├── e1_data_import.sql       # walidacja importu, SRID, topologia
│       ├── e3_gist_impact.sql       # benchmark z/bez GiST, N=10³..10⁵
│       ├── e4_pgrouting_perf.sql    # 500 m vs 1 km grid
│       └── e5_case_study_s1.sql     # materialised views pustyń medycznych
├── scripts/
│   ├── run_scenario.sh         # uruchomienie jednego scenariusza
│   ├── run_experiment.sh       # uruchomienie jednego eksperymentu
│   └── import_osm.sh           # import OSM w kontenerze (osm2pgrouting)
└── qgis/
    └── README.md               # konfiguracja warstw w QGIS
```

## Szybki start

### Wymagania

- Docker Desktop (≥ 20.10, Compose v2)
- QGIS 3.x (klient GIS)
- `psql` (opcjonalnie — skrypty wykonują wszystko w kontenerze)

### 1. Uruchom bazę danych

```bash
cp .env.example .env
docker compose up -d --build
```

Skrypty `sql/init/` uruchamiane są automatycznie w kolejności numerycznej:
1. `01_extensions.sql` — PostGIS, pgRouting
2. `02_schema.sql` — 7 tabel z indeksami GiST (BIGINT dla grafu)
3. `03_seed_data.sql` — 18 dzielnic z Voronoi + dane zdrowotne + siatka dróg

pgAdmin: http://localhost:8080 (`admin@localhost.pl` / `admin`)

### 2. Weryfikacja poprawności danych (E1)

```bash
./scripts/run_experiment.sh 1
```

Oczekiwany wynik:
- `dzielnice`: 18 rekordów, brak nakładania się (test: `pary_z_nakladem = 0`)
- SRID = 2180 we wszystkich tabelach przestrzennych
- `pgr_connectedComponents` zwraca jeden dominujący komponent (graf spójny)

### 3. Połącz QGIS z bazą

Patrz [qgis/README.md](qgis/README.md).

### 4. Uruchom scenariusze analityczne

```bash
./scripts/run_scenario.sh 1   # Pustynie medyczne
./scripts/run_scenario.sh 2   # SOR routing
./scripts/run_scenario.sh 3   # Lokalizacja nowej przychodni
./scripts/run_scenario.sh 4   # Gęstość aptek
./scripts/run_scenario.sh 5   # Najbliższa apteka
./scripts/run_scenario.sh 6   # Placówki w dzielnicy
```

### 5. Eksperymenty (E1–E6)

```bash
./scripts/run_experiment.sh 1   # Poprawność danych (record counts, SRID, topologia)
./scripts/run_experiment.sh 2   # End-to-end run wszystkich scenariuszy
./scripts/run_experiment.sh 3   # GiST benchmark, N=10³..10⁵
./scripts/run_experiment.sh 4   # pgRouting — 500 m vs 1 km
./scripts/run_experiment.sh 5   # Studium przypadku S1 (materialised views)
./scripts/run_experiment.sh 6   # Clean rebuild < 15 min (target z dokumentacji)
```

### 6. Import prawdziwej sieci OSM (opcjonalnie)

Domyślna siatka 5 km jest syntetyczna. Aby podmienić ją na realny graf
z OpenStreetMap (pracuje **wewnątrz kontenera** — nie wymaga instalacji
osm2pgrouting na hoście):

```bash
./scripts/import_osm.sh
```

### 7. Import RZECZYWISTYCH danych źródłowych (RPWDL/GUS/OSM/PRG)

Domyślny seed (synthetic) używa 18 aproksymowanych dzielnic Voronoi,
25 placówek POZ, 5 SOR i 40 aptek. Aby zastąpić go **prawdziwymi danymi**
z publicznych API zgodnie z dokumentacją projektu:

```bash
./scripts/import_real_data.sh
```

Pobiera (z cache w `data/cache/`):
- **18 dzielnic** — OSM `admin_level=9` (matches PRG)
- **Ludność 2023** — GUS BDL API (`var-id=72305`)
- **Apteki (~580)** — OSM `amenity=pharmacy`
- **POZ (~230)** — OSM `healthcare=clinic`
- **SOR (~4–13)** — OSM `emergency=yes` (varies; OSM tagging niespójny)

Następnie automatycznie:
- wyłącza triggery refresh MV (bulk-load)
- ładuje 5 plików SQL do bazy
- refreshuje wszystkie MV
- raportuje liczniki

Bez parametrów importuje wszystko; opcja `--only <name>` (`dzielnice`/`demografia`/`sor`/`poz`/`apteki`) pobiera tylko jeden dataset.

**Źródła danych** (zgodnie z dokumentacją wstępną):

| Tabela | Endpoint | Cache |
|---|---|---|
| `dzielnice`            | `overpass.kumi.systems` (admin_level=9)    | `data/cache/osm_dzielnice.json` |
| `demografia_dzielnice` | `bdl.stat.gov.pl/api/v1` (var-id=72305)    | `data/cache/bdl_*.json`         |
| `szpitale_sor`         | Overpass (emergency=yes ∪ SOR in name)     | `data/cache/osm_sor.json`       |
| `przychodnie_poz`      | Overpass (healthcare=clinic)               | `data/cache/osm_poz.json`       |
| `apteki`               | Overpass (amenity=pharmacy)                | `data/cache/osm_apteki.json`    |

## Model danych

| Tabela                  | Geometria / typ        | Źródło                      |
|-------------------------|------------------------|-----------------------------|
| `apteki`                | POINT (2180)           | OpenStreetMap               |
| `przychodnie_poz`       | POINT (2180)           | RPWDL / OSM                 |
| `szpitale_sor`          | POINT (2180)           | RPWDL / NFZ (dane.gov.pl)   |
| `dzielnice`             | MULTIPOLYGON (2180)    | Voronoi (seed) / PRG (prod) |
| `demografia_dzielnice`  | atrybuty               | GUS BDL 2023                |
| `drogi_topo`            | LINESTRING (2180) + BIGINT source/target | osm2pgrouting |
| `drogi_vertices`        | POINT (2180), id BIGINT | osm2pgrouting              |

## Scenariusze analityczne

| #  | Scenariusz                  | Q   | Kluczowe funkcje                              |
|----|-----------------------------|----:|-----------------------------------------------|
| S1 | Pustynie medyczne           | 7   | `ST_Buffer`, `ST_Union`, `ST_Difference`      |
| S2 | Dojazd do SOR               | 6   | `pgr_drivingDistance`, `ST_ConcaveHull`       |
| S3 | Lokalizacja nowej POZ       | 5   | `ST_VoronoiPolygons`, `ST_Intersection`       |
| S4 | Gęstość aptek               | 4   | `ST_Contains`, `RANK()`, `NTILE()`            |
| S5 | Najbliższa apteka           | 3   | `ST_DWithin`, KNN `<->`, `EXPLAIN ANALYZE`    |
| S6 | Placówki w dzielnicy        | 2   | scalar subqueries z `ST_Contains`             |

## Kluczowe decyzje projektowe

- **Dzielnice jako Voronoi** — seed generuje tessellację Voronoi z centroidów
  dzielnic przyciętą do uproszczonej granicy Warszawy. Gwarantuje brak
  nakładania się (istotne dla `ST_Contains` w S4/S6).
- **Graf w BIGINT** — `drogi_vertices.id`, `drogi_topo.source/target` są
  `BIGINT`, zgodnie z zwracanymi typami pgRouting. Zapobiega to konwersjom
  i problemom przy dużych grafach OSM.
- **S2 Q5 — odwrócona strategia** — zamiast uruchamiać `pgr_dijkstra` z
  każdej z ~7 000 komórek, używamy `pgr_drivingDistance` z ~5 szpitali
  z budżetem 30 min; to O(hosp × graf) zamiast O(komórek × graf).
- **S6 Q2 — scalar subqueries** — zamiast triple `LEFT JOIN` z `COUNT(DISTINCT)`
  (rząd wierszy O(n·m·k)) używamy skorelowanych podzapytań O(n+m+k).
- **Import OSM w kontenerze** — `scripts/import_osm.sh` wywołuje
  `osm2pgrouting` i `osmium` przez `docker compose exec`; host nie musi
  mieć tych narzędzi.

## Ograniczenia (świadome)

- **Model ludności** — równomierne rozproszenie w obrębie dzielnicy
  (jawnie odnotowane w dokumentacji; wpływa na S1 Q7, S3 Q4).
- **Voronoi vs. PRG** — seed używa syntetycznych granic; proporcje
  `powierzchnia_km2` liczone są z geometrii Voronoi i różnią się
  od GUS. W produkcji podmień na PRG/Geoportal.
- **Siatka drogowa 5 km (seed)** — minimalny graf do testów; prawdziwe
  izochrony wymagają importu OSM (krok 6).
