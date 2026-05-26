# Dostępność opieki zdrowotnej w Warszawie — projekt SPDB

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?logo=postgresql)](https://www.postgresql.org)
[![PostGIS](https://img.shields.io/badge/PostGIS-3.4-339933)](https://postgis.net)
[![pgRouting](https://img.shields.io/badge/pgRouting-3.x-blue)](https://pgrouting.org)
[![QGIS](https://img.shields.io/badge/QGIS-3.x-589632?logo=qgis)](https://qgis.org)

**Wielokrokowa analiza przestrzenna SQL — dostępność opieki zdrowotnej w 18 dzielnicach Warszawy.**

Cała logika analityczna w bazie (PostgreSQL + PostGIS + pgRouting). QGIS = klient wizualizacji.
Wszystkie dane z publicznych źródeł: **GUS BDL**, **OpenStreetMap**, **Geoportal/PRG**, **RPWDL**.

*Łukasz Siemionek, Piotr Liszewski · kwiecień 2026*

---

## Szybki start

```bash
git clone https://github.com/lkzs2003/Availability-of-healthcare-in-Warsaw.git
cd Availability-of-healthcare-in-Warsaw
cp .env.example .env
docker compose up -d --build   
./scripts/import_real_data.sh
```

Po tym:
- Baza dostępna na `127.0.0.1:5432` (`warszawa_health` / `postgres` / `postgres`)
- pgAdmin: `http://127.0.0.1:8080` (`admin@localhost.pl` / `admin`)
- QGIS: patrz [`qgis/README.md`](qgis/README.md)

---

## Co zawiera projekt

### 6 scenariuszy analitycznych (drill-down SQL)

| # | Scenariusz | Q | Klucz analityczny |
|---|---|---:|---|
| **S1** | Pustynie medyczne | 7 | `ST_Difference(miasto, ST_Union(ST_Buffer(POZ, 1000)))` |
| **S2** | Dostępność SOR po sieci drogowej | 6 | `pgr_drivingDistance` + `ST_ConcaveHull` (izochrony 5/10/15 min) |
| **S3** | Lokalizacja nowej przychodni POZ | 5 | `ST_VoronoiPolygons` -> centroidy największych stref |
| **S4** | Gęstość aptek względem ludności | 4 | `RANK() + NTILE(4)` z poprawnym handlingiem dzielnic z 0 aptek |
| **S5** | Najbliższa apteka od punktu | 3 | KNN `<->` na indeksie GiST + EXPLAIN ANALYZE benchmark |
| **S6** | Placówki w wybranej dzielnicy | 2 | scalar subqueries O(d×(n+m+k)) zamiast triple LEFT JOIN |

### 6 eksperymentów

| # | Cel | Metryka | Wynik |
|---|---|---|---|
| **E1** | Poprawność importu danych | Liczba rekordów, SRID, invalid geom, graph connectivity | 0 invalid, SRID=2180, 1 component OK |
| **E2** | Poprawność 6 scenariuszy | Każdy scenariusz exit 0 | 6/6 OK |
| **E3** | Wpływ indeksu GiST | EXPLAIN ANALYZE dla N=10^4, 10^5 | ~485x speedup z GiST OK |
| **E4** | Wydajność pgRouting | Czas dla siatki 500 m vs 1 km | 500 m: 13.9 ms; 1 km: ~2 ms |
| **E5** | Studium przypadku S1 | Materialised views z mapą pustyń | mv_pustynie_medyczne OK |
| **E6** | Powtarzalność środowiska | Czas clean rebuild | **13 s** vs target 900 s (69x margines) OK |

### Dane rzeczywiste (po `import_real_data.sh`)

| Tabela | Liczba | Źródło | Walidacja |
|---|---:|---|---|
| `dzielnice` | 18 | OSM `admin_level=9` | 516.8 km² = 99.9% PRG |
| `demografia_dzielnice` | 18 | GUS BDL `var-id=72305` (2023) | GUS: 1 861 599 / po V1.1: **1 812 000** |
| `apteki` | 582 | OSM `amenity=pharmacy` + V1.2 cleanup | 91 outsiderów (Marki/Pruszków) usunięte |
| `przychodnie_poz` | 231 | OSM `healthcare=clinic` | 0 invalid geometry |
| `szpitale_sor` | **14** | NFZ + RPWDL (migracja V1.1) | TRUNCATE + INSERT zweryfikowanej listy |
| `drogi_topo` | 157 (seed) / ~10^5 (OSM) | Synthetic 5 km grid / Geofabrik OSM | 1 connected component |

---

## Struktura projektu

```
.
├── docker-compose.yml             # db + pgAdmin (127.0.0.1 only)
├── Dockerfile                     # PostGIS 3.4 + pgRouting + osm2pgrouting + osmium
├── .env.example                   # zmienne (z ostrzeżeniem o bezpieczeństwie)
├── .dockerignore                  # excludes data/, .env
│
├── sql/init/                      # auto-load przy starcie kontenera
│   ├── 01_extensions.sql          # PostGIS, postgis_topology, pgrouting
│   ├── 02_schema.sql              # 7 tabel + warszawa_bbox + 8 indeksów + 3 FK
│   ├── 03_seed_data.sql           # 18 dzielnic (Voronoi) + 25 POZ + 5 SOR + 40 aptek
│   ├── 04_materialized_views.sql  # 3 MV: mv_pokrycie_poz_1km, mv_voronoi_poz, mv_sor_reachability
│   └── 05_refresh_triggers.sql    # 5 CONSTRAINT TRIGGERS DEFERRED — auto-refresh MV
│
├── sql/scenarios/                 # 6 scenariuszy analitycznych
│   ├── s1_medical_deserts.sql     #  7 zapytań
│   ├── s2_sor_routing.sql         #  6 zapytań
│   ├── s3_new_clinic_location.sql #  5 zapytań
│   ├── s4_pharmacy_density.sql    #  4 zapytania
│   ├── s5_nearest_pharmacy.sql    #  3 zapytania
│   └── s6_district_facilities.sql #  2 zapytania
│
├── sql/experiments/               # 4 eksperymenty SQL (E1, E3, E4, E5)
│   ├── e1_data_import.sql         # walidacja importu
│   ├── e3_gist_impact.sql         # GiST benchmark
│   ├── e4_pgrouting_perf.sql      # 500 m vs 1 km grid
│   └── e5_case_study_s1.sql       # materialised views pustyń
│
├── scripts/
│   ├── run_scenario.sh            # ./scripts/run_scenario.sh <1-6>
│   ├── run_experiment.sh          # ./scripts/run_experiment.sh <1-6>  (E2/E6 specjalne)
│   ├── import_osm.sh              # OSM road network -> osm2pgrouting -> drogi_topo
│   ├── import_real_data.sh        # GUS+OSM real data -> 18 dzielnic + ~670 aptek + ...
│   ├── import_apteki.sh           # Overpass API -> tylko apteki (V1.1 stack)
│   └── lib/
│       └── fetch_real_data.py     # implementacja fetcher'a (stdlib + curl)
│
├── qgis/
│   ├── README.md                  # konfiguracja połączenia + warstw
│   └── sql_layers/                # 6 plików SQL gotowych pod Add Virtual Layer
│       ├── s1_pustynie.sql
│       ├── s2_izochrony.sql
│       ├── s3_kandydaci.sql
│       ├── s4_kwartyle.sql
│       ├── s5_najblizsze_apteki.sql
│       └── s6_dzielnice_placowki.sql
│
├── docs/
│   ├── reports/sprawozdanie_koncowe.md   # SPRAWOZDANIE KOŃCOWE (5 wymaganych sekcji)
│   ├── reports/sprawozdanie_koncowe.pdf  # wersja PDF do oddania
│   └── img/qgis/                  # 7 zrzutów z QGIS 4.0.2 (overview + S1-S6)
│
├── scripts/lib/render_qgis.py     # generator zrzutów QGIS (PyQGIS, headless)
└── README.md                      # ten plik
```

---

## Uruchamianie

### Pojedynczy scenariusz
```bash
./scripts/run_scenario.sh 1   
./scripts/run_scenario.sh 4   
```

### Pojedynczy eksperyment
```bash
./scripts/run_experiment.sh 1   
./scripts/run_experiment.sh 2  
./scripts/run_experiment.sh 6   
```

### Import rzeczywistych danych
```bash
./scripts/import_real_data.sh                          
./scripts/import_real_data.sh --only demografia       
./scripts/import_real_data.sh --only apteki          
./scripts/import_real_data.sh --no-cache            
```

### Realna sieć drogowa OSM (opcjonalnie)
Domyślny seed używa siatki 5 km (88 wierzchołków). Aby załadować rzeczywiste drogi z OpenStreetMap (~10^5 krawędzi):
```bash
./scripts/import_osm.sh
```

---

## Kluczowe decyzje techniczne

### 1. EPSG:2180 (PL-1992) — metry natywnie
Wszystkie `ST_Distance`, `ST_DWithin`, `ST_Buffer` zwracają wynik w metrach bez ręcznej konwersji.

### 2. 3 materialised views eliminują 9x duplikację CTE
- `mv_pokrycie_poz_1km` — używany 4x w S1
- `mv_voronoi_poz` — używany 5x w S3
- `mv_sor_reachability` — używany 2x w S2 Q5/Q6 + E4

Triggery CONSTRAINT DEFERRED auto-refresh po commit.

### 3. S2 odwrócona strategia routingu
Zamiast naiwnego `pgr_dijkstra` z każdej z ~7 000 komórek siatki (O(N × graf)), uruchamiamy `pgr_drivingDistance` z ARRAY 14 SOR-vertex-ów z budżetem 25 km (O(H × graf)). Wynik (45 wierszy) materializujemy w `mv_sor_reachability`.

### 4. S6 scalar subqueries zamiast triple LEFT JOIN
Eliminuje multiplikatywny wybuch wierszy O(d×n×m×k) -> O(d×(n+m+k)).

### 5. BIGINT w grafie zgodnie z return-types pgRouting
`drogi_vertices.id`, `drogi_topo.source/target` to BIGINT — żadnych cast'ów w runtime.

### 6. FK DEFERRABLE INITIALLY DEFERRED
Pozwala bulk-load (vertices -> edges) w jednej transakcji bez utraty integralności.

### 7. Bezpieczeństwo
- Porty `127.0.0.1:` only
- `PGPASSWORD` env (nigdy w CLI)
- `NOT NULL` + FK na grafie zapobiega corrupt rows
- Wszystkie INSERT z fetcher'a escapowane (`sql_str()`)

---

## Dokumentacja

- **[`docs/reports/sprawozdanie_koncowe.pdf`](docs/reports/sprawozdanie_koncowe.pdf)** — **SPRAWOZDANIE KOŃCOWE** (wersja PDF do oddania)
- **[`docs/reports/sprawozdanie_koncowe.md`](docs/reports/sprawozdanie_koncowe.md)** — źródło Markdown sprawozdania (5 sekcji: schemat + indeksy + dane + zapytania/wizualizacje + wyniki)
- **[`docs/img/qgis/`](docs/img/qgis/)** — 7 zrzutów z QGIS 4.0.2 (overview + S1-S6)
- **[`qgis/README.md`](qgis/README.md)** — konfiguracja warstw w QGIS

---

## Ograniczenia

- **Model ludności** — równomierne rozproszenie w obrębie dzielnicy (wpływa na S1 Q7, S3 Q4). Jawnie odnotowane w dokumentacji wstępnej.
- **Siatka drogowa 5 km (seed)** — minimalny graf do testów; realne izochrony wymagają `./scripts/import_osm.sh`.
- **SOR w OSM** — tylko ~4 z ~13 SOR Warszawy ma tag `emergency=yes`. Pełna lista w NFZ/RPWDL ale bulk export wymaga autoryzowanego dostępu.
- **POZ** — używamy OSM `healthcare=clinic` jako best-effort proxy dla RPWDL.
- **Voronoi w seed** — syntetyczne granice; real data używa OSM admin_level=9 (matches PRG).

---

## Wybrane wyniki 

### S4 — najlepsze i najgorsze dzielnice po dostępności aptek (stan po V1.1+V1.2)
```
Śródmieście:  1 712 mieszk./aptekę   (najlepsza, 59 aptek)
Wola:         2 536 mieszk./aptekę
Praga-Północ: 2 542 mieszk./aptekę
...
Bemowo:       3 906 mieszk./aptekę
Ursus:        4 400 mieszk./aptekę
Białołęka:    4 968 mieszk./aptekę   (najgorsza, 31 aptek)
```
**2.9x różnica** w dostępności między centrum a peryferiami.

### S1 — % powierzchni dzielnicy będący pustynią medyczną
```
Wilanów:      83.6%     <- duża powierzchnia parków/lasów
Wawer:        82.6%     <- Mazowiecki Park Krajobrazowy
Białołęka:    76.2%     <- rozproszona zabudowa
Bielany:      69.5%
...
Śródmieście:  <5%       <- gęsta zabudowa
```

### E6 — clean rebuild
```
Elapsed: 13 seconds (target: < 900 s = 15 min)
```

---

## Wymagania

- Docker Desktop >= 20.10 (Compose v2)
- QGIS 3.x (do wizualizacji)
- Python 3.8+ (dla `import_real_data.sh`)
- ~500 MB miejsca (~250 MB OSM PBF cache, jeśli używasz `import_osm.sh`)

---

## Kontakt

- **Łukasz Siemionek** — lukals2203@gmail.com
- **Piotr Liszewski**

