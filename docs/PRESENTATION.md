# Przewodnik prezentacji / obrony projektu

Plan demo dla obrony SPDB: ~15 minut, 6 etapów.

## Etap 0 — Setup (zanim wejdziesz na salę)

```bash
git clone https://github.com/lkzs2003/Availability-of-healthcare-in-Warsaw.git
cd Availability-of-healthcare-in-Warsaw
cp .env.example .env
docker compose up -d --build       # 13 sekund
./scripts/import_real_data.sh      # ~30 sekund z cache, ~3 min od zera
```

Otwórz QGIS, podłącz PostGIS (`localhost:5432`, `warszawa_health` / `postgres` / `postgres`).

---

## Etap 1 — Cel projektu (1 min)

> "Projekt demonstruje analizę przestrzenną dostępności opieki zdrowotnej w Warszawie. Cała logika analityczna jest w PostgreSQL/PostGIS z pgRouting. QGIS to tylko klient wizualizacji. Wszystkie dane pochodzą z publicznych źródeł — GUS BDL, OpenStreetMap, RPWDL — i są w EPSG:2180 (PL-1992)."

Pokazać:
- README.md, sekcja "Opis"
- `docs/DATA_SOURCES.md` — tabela ze źródłami

---

## Etap 2 — Architektura (2 min)

Otworzyć `docs/ARCHITECTURE.md` — diagram warstw.

Kluczowe punkty:
- **7 tabel** zgodnie z dokumentacją wstępną
- **3 materialised views** eliminują duplikację CTE w S1/S2/S3
- **5 triggerów** auto-refresh MV po commit
- **EPSG:2180** wszędzie — `ST_Distance` zwraca metry natywnie

---

## Etap 3 — Demo każdego scenariusza w QGIS (8 min)

W QGIS, dla każdego scenariusza:
1. **Add Layer → Add/Edit Virtual Layer**
2. Wkleić query z `qgis/sql_layers/sN_*.sql`
3. Ustawić styl

### S1 — Pustynie medyczne
```sql
-- z qgis/sql_layers/s1_pustynie.sql
```
**Pokazać**: czerwony obszar ~60% Warszawy poza 1 km od POZ. Wskazać Wilanów, Wawer, Białołęka.

### S2 — Izochrony SOR (5/10/15 min)
```sql
-- z qgis/sql_layers/s2_izochrony.sql
```
**Pokazać**: kolorowe strefy wokół 4 SOR (real OSM data) lub 5 SOR (synthetic).
**Uwaga**: z syntetycznym 5 km grid izochrony są coarse. Wspomnieć że dla pełnego eksperymentu uruchamia się `./scripts/import_osm.sh`.

### S3 — Lokalizacja nowej POZ
```sql
-- z qgis/sql_layers/s3_kandydaci.sql
```
**Pokazać**: 5 punktów-kandydatów — centroidy największych stref Voronoi.

### S4 — Kwartyle dostępności aptek
```sql
-- z qgis/sql_layers/s4_kwartyle.sql
```
**Pokazać**: dzielnice kolorowane (1=czerwone, 4=zielone). Śródmieście zielone (1661 mieszk./aptekę), Białołęka czerwona (5121).
**Wytłumaczyć fix**: dzielnice z 0 aptek dostają `kwartyl=0` (poza skalą) — bez tego trafiały w kwartyl 4 ("najlepsza dostępność") = bug.

### S5 — Najbliższa apteka
```sql
-- z qgis/sql_layers/s5_najblizsze_apteki.sql
```
**Pokazać**: 3 punkty wokół Pałacu Kultury z dystansami w metrach.

### S6 — Placówki w dzielnicy
```sql
-- z qgis/sql_layers/s6_dzielnice_placowki.sql
```
**Pokazać**: dzielnice z liczbą aptek/POZ/SOR + mieszkańcy/przychodnię.

---

## Etap 4 — Eksperymenty (2 min)

Pokazać w terminalu:

```bash
./scripts/run_experiment.sh 1   # E1: walidacja importu
./scripts/run_experiment.sh 3   # E3: GiST benchmark
./scripts/run_experiment.sh 6   # E6: clean rebuild < 15 min
```

**Wnioski**:
- E1: 0 invalid geometries, SRID=2180, 1 connected component grafu
- E3: GiST przyspiesza KNN ~485× dla N=100k punktów
- E6: 13 sekund vs target 900 s — 69× margines

---

## Etap 5 — Kluczowe decyzje techniczne (1.5 min)

Wybrać 2–3 z `docs/ARCHITECTURE.md#5-strategie-optymalizacji`:

1. **S2 odwrócona strategia routingu**: `pgr_drivingDistance(H szpitali)` zamiast `pgr_dijkstra(N komórek)` → ~1700× szybciej.
2. **S6 scalar subqueries**: O(d×(n+m+k)) zamiast O(d×n×m×k) → brak row multiplication.
3. **DEFERRABLE FK + CONSTRAINT TRIGGER DEFERRED**: pozwala bulk-load w jednej transakcji bez utraty integralności i bez N refreshów MV.

---

## Etap 6 — Pytania i odpowiedzi (0.5 min na każde)

### Anticipated questions

**Q: Skąd dane?**
A: GUS BDL API (var-id=72305, exact match z oficjalnymi 1,861,599), OSM Overpass dla aptek/klinik/SOR/granic. Pełna dokumentacja w `docs/DATA_SOURCES.md` z endpointami i cache.

**Q: Dlaczego tylko 4 SOR zamiast ~13?**
A: OSM tagging `emergency=yes` jest niespójny. Pełna lista jest w NFZ/RPWDL ale bulk export wymaga autoryzowanego dostępu. To jest udokumentowane ograniczenie w README.

**Q: Dlaczego 88 vertices w grafie?**
A: Domyślny seed używa siatki 5 km dla szybkiego startu. Realna sieć drogowa (~10⁵ krawędzi) ładowana opcjonalnie przez `./scripts/import_osm.sh` (osm2pgrouting w kontenerze).

**Q: Co jeśli Overpass jest offline?**
A: Skrypt ma fallback przez 3 mirrory (`kumi.systems`, `private.coffee`, `overpass-api.de`). Plus cache w `data/cache/` — re-uruchomienie nie pobiera ponownie.

**Q: Pokażecie SQL bez wizualizacji?**
A: Tak — wszystko jest w `sql/scenarios/sN_*.sql`. Skomentowane, drill-down, każdy Q ma cel w nagłówku. Pokażę najbardziej złożone (S2 Q5 i S3 Q5).

**Q: Indeksy GiST?**
A: 4 GiST (apteki, POZ, SOR, dzielnice, drogi_vertices) + 4 GiST na MV + B-Tree na `nr_rpwdl`, `source`, `target`. Łącznie 11 indeksów. Pokazany efekt: E3 = ~485× speedup dla KNN.

**Q: Co z bezpieczeństwem?**
A: Porty `127.0.0.1:` only, `PGPASSWORD` env (nigdy CLI), `DEFERRABLE FK` + `NOT NULL`, escapowanie w fetcherze. Pełny opis w `docs/ARCHITECTURE.md#7-bezpieczeństwo`.

---

## Backup plan: jeśli QGIS nie działa

Pokazać wszystko przez psql:
```bash
docker compose exec -T db psql -U postgres -d warszawa_health < sql/scenarios/s4_pharmacy_density.sql
```

Wyniki Q4 (kwartyle) świetnie pokazują się w terminalu — tabelka z 18 dzielnicami posortowana.

---

## Checklist przed prezentacją

- [ ] `docker compose ps` → wszystkie healthy
- [ ] `./scripts/import_real_data.sh` zwraca 18/18/586/231/4
- [ ] QGIS podłączony, dzielnice + apteki + POZ + SOR widoczne na mapie
- [ ] Każdy `qgis/sql_layers/sN_*.sql` przetestowany — wczyta się jako virtual layer
- [ ] README na ekranie, gotowy do scrollowania
- [ ] Terminal z `cd` do projektu, history clean
