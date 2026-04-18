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
├── .env.example                # zmienne środowiskowe
├── sql/
│   ├── init/                   # skrypty auto-wykonywane przy starcie kontenera
│   │   ├── 01_extensions.sql   # PostGIS, pgRouting
│   │   ├── 02_schema.sql       # 7 tabel + indeksy GiST
│   │   └── 03_seed_data.sql    # syntetyczne dane testowe
│   └── scenarios/              # 6 scenariuszy analitycznych (drill-down)
│       ├── s1_medical_deserts.sql      # 7 zapytań — pustynie medyczne
│       ├── s2_sor_routing.sql          # 6 zapytań — czas dojazdu do SOR
│       ├── s3_new_clinic_location.sql  # 5 zapytań — lokalizacja nowej przychodni
│       ├── s4_pharmacy_density.sql     # 4 zapytania — gęstość aptek
│       ├── s5_nearest_pharmacy.sql     # 3 zapytania — najbliższa apteka
│       └── s6_district_facilities.sql # 2 zapytania — placówki w dzielnicy
├── scripts/
│   ├── run_scenario.sh         # uruchomienie scenariusza psql
│   └── import_osm.sh           # import prawdziwej sieci OSM (osm2pgrouting)
└── qgis/
    └── README.md               # konfiguracja warstw w QGIS
```

## Szybki start (< 15 min od git clone do pierwszej warstwy w QGIS)

### Wymagania
- Docker Desktop
- QGIS 3.x (klient GIS)
- `psql` (opcjonalnie, dla scenariuszy z CLI)

### 1. Uruchom bazę danych

```bash
cp .env.example .env
docker compose up -d --build
```

Kontener automatycznie uruchomi skrypty z `sql/init/` w kolejności numerycznej:
1. `01_extensions.sql` — PostGIS, pgRouting
2. `02_schema.sql` — 7 tabel z indeksami GiST
3. `03_seed_data.sql` — syntetyczne dane (18 dzielnic, 5 SOR, 25 POZ, 40 aptek, sieć dróg)

Sprawdź status:
```bash
docker compose logs -f db
# Gdy zobaczysz "database system is ready to accept connections" — gotowe
```

pgAdmin dostępny pod: http://localhost:8080 (admin@localhost.pl / admin)

### 2. Połącz QGIS z bazą

Patrz [qgis/README.md](qgis/README.md)

### 3. Uruchom scenariusze analityczne

```bash
chmod +x scripts/run_scenario.sh

# Wszystkie scenariusze po kolei
for i in 1 2 3 4 5 6; do
    ./scripts/run_scenario.sh $i
done

# Lub bezpośrednio przez psql (z psql variables)
psql -h localhost -U postgres -d warszawa_health \
    -f sql/scenarios/s1_medical_deserts.sql
```

### 4. Import prawdziwej sieci drogowej OSM (opcjonalny)

Domyślnie baza zawiera syntetyczną siatkę 5 km. Aby zastąpić ją rzeczywistą
siecią z OpenStreetMap (wymagany `osm2pgrouting` i `osmium`/`osmosis`):

```bash
chmod +x scripts/import_osm.sh
./scripts/import_osm.sh
```

## Model danych

| Tabela               | Geometria           | Źródło danych                |
|----------------------|---------------------|------------------------------|
| `apteki`             | POINT (2180)        | OpenStreetMap                |
| `przychodnie_poz`    | POINT (2180)        | RPWDL / OSM                  |
| `szpitale_sor`       | POINT (2180)        | RPWDL / NFZ (dane.gov.pl)    |
| `dzielnice`          | MULTIPOLYGON (2180) | PRG / Geoportal              |
| `demografia_dzielnice` | — (atrybuty)      | GUS BDL                      |
| `drogi_topo`         | LINESTRING (2180)   | OpenStreetMap (osm2pgrouting)|
| `drogi_vertices`     | POINT (2180)        | OpenStreetMap (osm2pgrouting)|

## Scenariusze analityczne

| # | Scenariusz | Zapytania | Kluczowe funkcje PostGIS |
|---|-----------|-----------|--------------------------|
| S1 | Pustynie medyczne | 7 | `ST_Buffer`, `ST_Union`, `ST_Difference` |
| S2 | Czas dojazdu do SOR | 6 | `pgr_drivingDistance`, `pgr_dijkstra`, `ST_ConcaveHull` |
| S3 | Lokalizacja nowej przychodni | 5 | `ST_VoronoiPolygons`, `ST_Intersection` |
| S4 | Gęstość aptek | 4 | `ST_Contains`, `RANK()`, `NTILE()` |
| S5 | Najbliższa apteka | 3 | `ST_DWithin`, KNN `<->`, `EXPLAIN ANALYZE` |
| S6 | Placówki w dzielnicy | 2 | `ST_Contains`, `LEFT JOIN` przestrzenny |

## Ryzyka i ograniczenia

- **Dane syntetyczne** — seed data używa uproszczonych okrągłych granic dzielnic
  i siatki drogowej; wyniki na prawdziwych danych będą się różnić
- **Model ludności** — równomierne rozproszenie w obrębie dzielnicy (S1 Q7, S3 Q4)
- **Sieć OSM** — mogą istnieć izolowane fragmenty grafu; walidacja: `pgr_analyzeGraph`
- **RPWDL** — rejestr bywa niekompletny; uzupełnienie z OSM tagiem `amenity=clinic`
