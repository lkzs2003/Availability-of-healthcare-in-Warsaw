# Źródła danych

Dokumentacja **każdego** rekordu w bazie — skąd pochodzi, jak się go odświeża, jakie są ograniczenia.

## 1. Domyślny seed (synthetic, w `03_seed_data.sql`)

Uruchamiany automatycznie przy `docker compose up -d` — pozwala na natychmiastowy start projektu bez wywołań sieciowych.

| Tabela | Liczba | Pochodzenie | Uwagi |
|---|---:|---|---|
| `dzielnice`            | 18  | Voronoi z centroidów + uproszczona granica (10 punktów) | Aproksymacja, nie odpowiada rzeczywistym granicom |
| `demografia_dzielnice` | 18  | Wartości GUS BDL 2023 (statyczne, wbite w plik) | Te same liczby co realne dane |
| `przychodnie_poz`      | 25  | Realne nazwy + adresy + przybliżone współrzędne | Próbka |
| `szpitale_sor`         | 5   | 5 głównych SOR Warszawy (Bielański, Wolski, Bródnowski, Praski, Południowy) | Realne |
| `apteki`               | 40  | Realne sieci (DOZ, Gemini, Cefarm) z przybliżonymi współrzędnymi | Próbka |
| `drogi_vertices`       | 88  | Siatka 11×8 z step 5 km | Syntetyczna — `import_osm.sh` zastępuje |
| `drogi_topo`           | 157 | Krawędzie poziome + pionowe siatki | Syntetyczna |

Seed zapewnia:
- Deterministyczny start-up (test reprodukowalności)
- Pełną funkcjonalność wszystkich 6 scenariuszy bez I/O sieci
- Smoke test schematu i triggerów

## 2. Real data (`./scripts/import_real_data.sh`)

Po starcie kontenera, wywołanie tego skryptu zastępuje seed prawdziwymi danymi z publicznych API.

### 2.1. Dzielnice — OSM admin_level=9

**Źródło**: OpenStreetMap Overpass API
**Endpoint**: `overpass.kumi.systems` (fallback: `overpass.private.coffee`, `overpass-api.de`)
**Query**:
```overpassql
[out:json][timeout:180];
relation["name"="Warszawa"]["admin_level"="6"];
map_to_area->.w;
relation["admin_level"="9"](area.w);
out body geom;
```

**Co dostajemy**: 18 relacji OSM z geometrią członków (way segments). Skrypt:
1. Asembluje rings z way-fragmentów (matching endpoints z tolerancją 1e-7°)
2. Wymusza zamknięcie ring-ów z luką (1 znany przypadek: Wawer ma ~1.5 km gap)
3. Reprojektuje EPSG:4326 → EPSG:2180 z `ST_Transform`
4. Aplikuje `ST_MakeValid` + `ST_CollectionExtract(_, 3)` + `ST_Multi`
5. Liczy `powierzchnia_km2 = ST_Area(geom) / 1e6`

**Walidacja**: suma powierzchni = 516.8 km² (oficjalnie Warszawa = 517.2 km² → 99.9% zgodność).

**Cache**: `data/cache/osm_dzielnice.json` (~5 MB).

### 2.2. Demografia — GUS BDL API

**Źródło**: Główny Urząd Statystyczny, Bank Danych Lokalnych
**Endpoint**: `https://bdl.stat.gov.pl/api/v1/data/by-unit/{unit_id}`
**Zmienna**: `var-id=72305` — *"Ludność ogółem, stan w dniu 31 XII"*
**Rok**: 2023
**Klucze unit_id (TERYT)**: zdefiniowane w `BDL_DZIELNICE` w `scripts/lib/fetch_real_data.py`.

| Dzielnica | Unit ID | Populacja 2023 |
|---|---|---:|
| Bemowo         | 071412865028 | 129,188   |
| Białołęka      | 071412865038 | 158,749   |
| Bielany        | 071412865048 | 131,420   |
| Mokotów        | 071412865058 | 225,519   |
| Ochota         | 071412865068 |  79,357   |
| Praga-Południe | 071412865078 | 185,810   |
| Praga-Północ   | 071412865088 |  59,632   |
| Rembertów      | 071412865098 |  24,822   |
| Śródmieście    | 071412865108 |  97,983   |
| Targówek       | 071412865118 | 123,067   |
| Ursus          | 071412865128 |  69,574   |
| Ursynów        | 071412865138 | 149,775   |
| Wawer          | 071412865148 |  88,512   |
| Wesoła         | 071412865158 |  26,632   |
| Wilanów        | 071412865168 |  52,472   |
| Włochy         | 071412865178 |  50,143   |
| Wola           | 071412865188 | 150,319   |
| Żoliborz       | 071412865198 |  58,625   |
| **SUMA**       |              | **1,861,599** |

Oficjalna populacja Warszawy 2023 wg GUS: **1 861 599** — **exact match**.

**Cache**: `data/cache/bdl_*.json` (18 plików, łącznie <100 KB).

### 2.3. Apteki — OSM amenity=pharmacy

**Źródło**: OpenStreetMap Overpass
**Query**:
```overpassql
area["name"="Warszawa"]["admin_level"="6"]->.w;
(
  node["amenity"="pharmacy"](area.w);
  way["amenity"="pharmacy"](area.w);
);
out center tags;
```
**Co dostajemy**: 586 aptek w Warszawie z atrybutami:
- `name` lub `brand` (Apteka Gemini, DOZ, SuperPharm, …)
- `addr:street + addr:housenumber`
- Opcjonalnie `ref:csioz` (mapowanie na CSIOZ — Centrum Systemów Informacyjnych Ochrony Zdrowia)

De-duplikacja: po `(name, round(lon,6), round(lat,6))`. Brak duplikatów ze zaokrąglonych współrzędnych = ~3 m precyzja.

**Cache**: `data/cache/osm_apteki.json` (~600 KB).

### 2.4. Przychodnie POZ — OSM healthcare=clinic

**Źródło**: OpenStreetMap Overpass
**Query**:
```overpassql
area["name"="Warszawa"]["admin_level"="6"]->.w;
(
  node["healthcare"="clinic"](area.w);
  node["amenity"="clinic"](area.w);
  node["healthcare"="doctor"]["healthcare:speciality"~"general"](area.w);
  way["healthcare"="clinic"](area.w);
  way["amenity"="clinic"](area.w);
);
out center tags;
```
**Co dostajemy**: 231 przychodni (klinik, przychodni POZ, gabinetów lekarzy ogólnych).

**Ograniczenie**: pełna lista wszystkich aktywnych POZ jest w **RPWDL** (Rejestr Podmiotów Wykonujących Działalność Leczniczą — https://rpwdl.ezdrowie.gov.pl), ale eksport masowy wymaga autoryzowanego dostępu / parsowania HTML. W tym buildzie używamy OSM jako best-effort proxy. Dla produkcji udokumentowano alternatywę w `docs/SCENARIOS.md`.

**Cache**: `data/cache/osm_poz.json` (~200 KB).

### 2.5. Szpitale SOR — OSM emergency=yes

**Źródło**: OpenStreetMap Overpass
**Query**:
```overpassql
area["name"="Warszawa"]["admin_level"="6"]->.w;
(
  node["amenity"="hospital"]["emergency"="yes"](area.w);
  way["amenity"="hospital"]["emergency"="yes"](area.w);
  relation["amenity"="hospital"]["emergency"="yes"](area.w);
);
out center tags;
```
**Co dostajemy**: ~4 szpitale z taggiem `emergency=yes`.

**ZNANA LIMITACJA**: Warszawa ma ~13 SOR w rzeczywistości, ale OSM tagging jest niespójny — wiele szpitali nie ma `emergency=yes`. Pełna lista w **NFZ** (dane.gov.pl) i **RPWDL**. W tym buildzie przyjmujemy OSM bez retuszu — udokumentowane w README.

**Cache**: `data/cache/osm_sor.json` (~20 KB).

### 2.6. Sieć drogowa — Geofabrik OSM (opcjonalnie, `./scripts/import_osm.sh`)

**Źródło**: Geofabrik Poland → mazowieckie → osmium clip do bbox Warszawy → osm2pgrouting
**Endpoint**: `https://download.geofabrik.de/europe/poland/mazowieckie-latest.osm.pbf` (~250 MB)
**Pipeline**:
1. Download PBF z Geofabrik
2. `osmium extract --bbox 20.85,52.10,21.27,52.37` → warszawa.osm.pbf
3. `osmium cat` → warszawa.osm (XML)
4. `osm2pgrouting --conf mapconfig_for_cars.xml` → stage tables `ways/ways_vertices_pgr`
5. Reprojekcja EPSG:4326 → 2180 + `ST_MakeValid(ST_Force2D(ST_LineMerge(...)))`
6. Insert do `drogi_topo` z honorem FK (`source IS NOT NULL AND target IS NOT NULL`)
7. `REINDEX` + `ANALYZE` + connectivity check (`pgr_connectedComponents`)
8. `REFRESH MATERIALIZED VIEW mv_sor_reachability`

**Cache**: `data/osm/mazowieckie-latest.osm.pbf` (~250 MB).

## 3. Refresh / aktualizacja

| Dane | Komenda | Częstotliwość |
|---|---|---|
| Wszystkie (full re-fetch) | `./scripts/import_real_data.sh --no-cache` | Rocznie / na rocznice GUS |
| Tylko demografia | `python3 scripts/lib/fetch_real_data.py --only demografia` | Po publikacji nowego rocznika BDL |
| Tylko apteki | `python3 scripts/lib/fetch_real_data.py --only apteki` | Co kwartał (zmienne dane OSM) |
| Sieć drogowa | `./scripts/import_osm.sh` | Co kwartał (Geofabrik update) |

Każda fetch automatycznie:
1. Korzysta z cache jeśli istnieje (chyba że `--no-cache`)
2. Generuje SQL w `sql/init/data_real/`
3. `import_real_data.sh` aplikuje go z wyłączonymi triggerami → re-enable → manual REFRESH

## 4. Atrybucja

- Wszystkie dane z OSM są pod **ODbL 1.0**. Wymagane atrybuty: `© OpenStreetMap contributors`.
- GUS BDL — dane publiczne, brak restrykcji.
- PRG via GUGiK — dane publiczne.
- RPWDL — rejestr publiczny.
