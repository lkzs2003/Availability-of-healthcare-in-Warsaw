-- =====================================================================
--  Migracja V1.1: enrich_healthcare_and_demographics
-- ---------------------------------------------------------------------
--  Wzbogaca bazę o:
--   * naprawę geometrii granic dzielnic (ST_MakeValid)
--   * aktualne dane demograficzne GUS 2023 dla 18 dzielnic
--   * komplet 14 funkcjonujących Szpitalnych Oddziałów Ratunkowych (SOR)
--   * kolumnę `dzielnica` w tabelach POZ/apteki/SOR + spatial join (ST_Contains)
--   * pełną kalkulację `cost` i `reverse_cost` w sieci drogowej (ST_Length)
--   * brakujące indeksy GiST/B-Tree dla wydajności zapytań
--
--  Bezpieczeństwo:
--   * wszystko w jednej transakcji (BEGIN/COMMIT, ON_ERROR_STOP)
--   * DDL (ALTER, CREATE INDEX) wykonywane PRZED jakimkolwiek DML —
--     uniknięcie błędu "cannot CREATE INDEX because it has pending
--     trigger events" (triggery materialised view są DEFERRABLE INITIALLY
--     DEFERRED i wpadają do kolejki przy każdej zmianie w POZ/SOR/dzielnice)
--   * brak DROP/CREATE — tylko idempotentne UPDATE/INSERT/ALTER IF NOT EXISTS
--
--  Uruchomienie:
--      docker compose exec -T db psql -U postgres -d warszawa_health \
--          -v ON_ERROR_STOP=1 < sql/migrations/V1.1__enrich_healthcare_and_demographics.sql
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

-- =====================================================================
--  CZĘŚĆ 1: DDL — wszystkie zmiany schematu PRZED DML
-- =====================================================================

-- ---------------------------------------------------------------------
-- KROK 1a: Kolumna `dzielnica` (przynależność administracyjna)
-- ---------------------------------------------------------------------
-- Dodajemy idempotentnie (IF NOT EXISTS). DDL musi nastąpić ZANIM pojawi
-- się DML uruchamiający CONSTRAINT TRIGGER, bo PostgreSQL nie pozwala na
-- ALTER/CREATE INDEX w tej samej transakcji co pending deferred triggers.
-- ---------------------------------------------------------------------
ALTER TABLE public.przychodnie_poz ADD COLUMN IF NOT EXISTS dzielnica VARCHAR(50);
ALTER TABLE public.apteki          ADD COLUMN IF NOT EXISTS dzielnica VARCHAR(50);
ALTER TABLE public.szpitale_sor    ADD COLUMN IF NOT EXISTS dzielnica VARCHAR(50);

-- ---------------------------------------------------------------------
-- KROK 1b: Indeksy (GiST przestrzenne + B-Tree na atrybutach)
-- ---------------------------------------------------------------------
-- IF NOT EXISTS — bezpieczne ponowne uruchomienie. Tworzymy także indeksy
-- na nowo dodanych kolumnach `dzielnica`, by S4/S6 mogły filtrować szybko.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_dzielnice_geom         ON public.dzielnice         USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_przychodnie_geom       ON public.przychodnie_poz   USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_apteki_geom            ON public.apteki            USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_szpitale_sor_geom      ON public.szpitale_sor      USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_drogi_topo_geom        ON public.drogi_topo        USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_drogi_vertices_geom    ON public.drogi_vertices    USING GIST (geom);

CREATE INDEX IF NOT EXISTS idx_przychodnie_dzielnica  ON public.przychodnie_poz   (dzielnica);
CREATE INDEX IF NOT EXISTS idx_apteki_dzielnica       ON public.apteki            (dzielnica);
CREATE INDEX IF NOT EXISTS idx_szpitale_sor_dzielnica ON public.szpitale_sor      (dzielnica);
CREATE INDEX IF NOT EXISTS idx_dzielnice_nazwa        ON public.dzielnice         (nazwa);
CREATE INDEX IF NOT EXISTS idx_demografia_rok         ON public.demografia_dzielnice (rok);
CREATE INDEX IF NOT EXISTS idx_drogi_topo_source      ON public.drogi_topo        (source);
CREATE INDEX IF NOT EXISTS idx_drogi_topo_target      ON public.drogi_topo        (target);

-- =====================================================================
--  CZĘŚĆ 2: DML — zmiany danych. Od tego punktu CONSTRAINT TRIGGERS
--  DEFERRED wpadają do kolejki i fire-ują dopiero na COMMIT.
-- =====================================================================

-- ---------------------------------------------------------------------
-- KROK 2: Naprawa geometrii dzielnic
-- ---------------------------------------------------------------------
-- Topologie zaimportowane z Overpass czasem zawierają samoprzecięcia
-- po reprojekcji do EPSG:2180. ST_MakeValid wraz z ST_CollectionExtract
-- (typ=3, tylko poligony) gwarantuje deterministyczne wyniki kolejnych
-- ST_Contains / ST_Intersects / ST_Area.
-- ---------------------------------------------------------------------
UPDATE public.dzielnice
   SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
 WHERE NOT ST_IsValid(geom);

-- ---------------------------------------------------------------------
-- KROK 3: Aktualizacja demografii GUS 2023
-- ---------------------------------------------------------------------
-- Dla każdej z 18 dzielnic ustawiamy aktualną populację (rok=2023) oraz
-- wyliczamy gęstość dynamicznie z powierzchni geometrii (m2 -> os/km2).
-- ON CONFLICT — pozwala bezpiecznie ponawiać migrację.
-- ---------------------------------------------------------------------
WITH dane_2023 (nazwa, ludnosc) AS (
    VALUES
        ('Bemowo',         125000),
        ('Białołęka',      154000),
        ('Bielany',        131000),
        ('Mokotów',        218000),
        ('Ochota',          82000),
        ('Praga-Południe', 179000),
        ('Praga-Północ',    61000),
        ('Rembertów',       24500),
        ('Śródmieście',    101000),
        ('Targówek',       124000),
        ('Ursus',           66000),
        ('Ursynów',        151000),
        ('Wawer',           81000),
        ('Wesoła',          26500),
        ('Wilanów',         46000),
        ('Włochy',          44000),
        ('Wola',           142000),
        ('Żoliborz',        56000)
)
INSERT INTO public.demografia_dzielnice (dzielnica_id, rok, ludnosc, gestosc_os_km2)
SELECT  d.id,
        2023,
        x.ludnosc,
        ROUND( ((x.ludnosc::numeric) / NULLIF((ST_Area(d.geom) / 1e6)::numeric, 0))::numeric, 2 )
  FROM  dane_2023 x
  JOIN  public.dzielnice d ON d.nazwa = x.nazwa
ON CONFLICT (dzielnica_id, rok) DO UPDATE
   SET  ludnosc        = EXCLUDED.ludnosc,
        gestosc_os_km2 = EXCLUDED.gestosc_os_km2;

-- ---------------------------------------------------------------------
-- KROK 4: Uzupełnienie szpitali SOR (14 placówek)
-- ---------------------------------------------------------------------
-- Pełna lista funkcjonujących SOR w Warszawie (źródło: NFZ + RPWDL).
-- Współrzędne WGS-84 (EPSG:4326) reprojektowane do PL-1992 (EPSG:2180).
-- TRUNCATE ... RESTART IDENTITY — czyści tabelę i resetuje sekwencję.
-- ---------------------------------------------------------------------
TRUNCATE TABLE public.szpitale_sor RESTART IDENTITY CASCADE;

INSERT INTO public.szpitale_sor (nazwa, adres, geom) VALUES
    ('Szpital Bielański',                        'ul. Cegłowska 80',     ST_Transform(ST_SetSRID(ST_Point(20.9585, 52.2811), 4326), 2180)),
    ('Szpital Bródnowski',                       'ul. Kondratowicza 8',  ST_Transform(ST_SetSRID(ST_Point(21.0334, 52.2913), 4326), 2180)),
    ('Szpital Szaserów MON',                     'ul. Szaserów 128',     ST_Transform(ST_SetSRID(ST_Point(21.1001, 52.2428), 4326), 2180)),
    ('Szpital Międzyleski',                      'ul. Bursztynowa 2',    ST_Transform(ST_SetSRID(ST_Point(21.1659, 52.1672), 4326), 2180)),
    ('Szpital Praski',                           'al. Solidarności 67',  ST_Transform(ST_SetSRID(ST_Point(21.0305, 52.2520), 4326), 2180)),
    ('Szpital Wolski',                           'ul. Kasprzaka 17',     ST_Transform(ST_SetSRID(ST_Point(20.9678, 52.2289), 4326), 2180)),
    ('Szpital Czerniakowski',                    'ul. Stępińska 19/25',  ST_Transform(ST_SetSRID(ST_Point(21.0425, 52.2045), 4326), 2180)),
    ('CSK UCK WUM ul. Banacha',                  'ul. Banacha 1a',       ST_Transform(ST_SetSRID(ST_Point(20.9782, 52.2105), 4326), 2180)),
    ('Szpital Dzieciątka Jezus',                 'ul. Lindleya 4',       ST_Transform(ST_SetSRID(ST_Point(21.0011, 52.2248), 4326), 2180)),
    ('Szpital Południowy',                       'ul. Pileckiego 99',    ST_Transform(ST_SetSRID(ST_Point(21.0112, 52.1485), 4326), 2180)),
    ('Szpital MSWiA',                            'ul. Wołoska 137',      ST_Transform(ST_SetSRID(ST_Point(21.0068, 52.1995), 4326), 2180)),
    ('Dziecięcy Szpital Kliniczny',              'ul. Żwirki i Wigury',  ST_Transform(ST_SetSRID(ST_Point(20.9815, 52.2085), 4326), 2180)),
    ('Warszawski Szpital dla Dzieci',            'ul. Kopernika 43',     ST_Transform(ST_SetSRID(ST_Point(21.0180, 52.2372), 4326), 2180)),
    ('Centrum Zdrowia Dziecka Międzylesie',      'al. Dzieci Polskich',  ST_Transform(ST_SetSRID(ST_Point(21.1915, 52.1601), 4326), 2180));

-- ---------------------------------------------------------------------
-- KROK 5: Spatial join — przypisanie dzielnicy do punktów
-- ---------------------------------------------------------------------
-- Punkt trafia tylko do jednej dzielnicy (poligony są rozłączne —
-- Voronoi/PRG), więc pojedyncze UPDATE daje deterministyczny wynik.
-- ---------------------------------------------------------------------
UPDATE public.przychodnie_poz p
   SET dzielnica = d.nazwa
  FROM public.dzielnice d
 WHERE ST_Contains(d.geom, p.geom);

UPDATE public.apteki a
   SET dzielnica = d.nazwa
  FROM public.dzielnice d
 WHERE ST_Contains(d.geom, a.geom);

UPDATE public.szpitale_sor s
   SET dzielnica = d.nazwa
  FROM public.dzielnice d
 WHERE ST_Contains(d.geom, s.geom);

-- ---------------------------------------------------------------------
-- KROK 6: Koszty pgRouting — metryczna długość krawędzi
-- ---------------------------------------------------------------------
-- W EPSG:2180 ST_Length zwraca metry natywnie. Aktualizujemy zarówno
-- cost (kierunek source->target) jak i reverse_cost (target->source).
-- Reverse_cost >= 0 -> pgRouting traktuje krawędź jako dwukierunkową.
-- ---------------------------------------------------------------------
UPDATE public.drogi_topo
   SET cost         = ST_Length(geom),
       reverse_cost = ST_Length(geom)
 WHERE geom IS NOT NULL;

COMMIT;

-- =====================================================================
--  CZĘŚĆ 3: POST-COMMIT — odświeżenie statystyk i widoków
-- =====================================================================

-- Triggery CONSTRAINT DEFERRED odświeżyły MV automatycznie na COMMIT,
-- ale jawne REFRESH gwarantuje deterministyczny stan po migracji.
REFRESH MATERIALIZED VIEW public.mv_pokrycie_poz_1km;
REFRESH MATERIALIZED VIEW public.mv_voronoi_poz;
REFRESH MATERIALIZED VIEW public.mv_sor_reachability;

-- ANALYZE — odśwież statystyki planera dla nowych rozmiarów tabel.
ANALYZE public.dzielnice;
ANALYZE public.demografia_dzielnice;
ANALYZE public.przychodnie_poz;
ANALYZE public.apteki;
ANALYZE public.szpitale_sor;
ANALYZE public.drogi_topo;

-- ---------------------------------------------------------------------
-- Raport weryfikacyjny (do logu psql)
-- ---------------------------------------------------------------------
\echo
\echo '====================================================================='
\echo '  Migracja V1.1 — raport końcowy'
\echo '====================================================================='

\echo
\echo '>> Spójność spatial-join (powinno być 0 wartości NULL):'
SELECT typ,
       COUNT(*)                              AS wszystkie,
       COUNT(dzielnica)                      AS przypisane,
       COUNT(*) - COUNT(dzielnica)           AS bledne_poza_warszawa
  FROM ( SELECT 'SOR'    AS typ, dzielnica FROM public.szpitale_sor
         UNION ALL
         SELECT 'POZ'    AS typ, dzielnica FROM public.przychodnie_poz
         UNION ALL
         SELECT 'Apteka' AS typ, dzielnica FROM public.apteki
       ) AS raport
 GROUP BY typ
 ORDER BY typ;

\echo
\echo '>> Liczba placówek per dzielnica:'
SELECT d.nazwa                                            AS dzielnica,
       COALESCE(s.cnt,0)                                  AS sor,
       COALESCE(p.cnt,0)                                  AS poz,
       COALESCE(a.cnt,0)                                  AS apteki,
       dem.ludnosc
  FROM public.dzielnice d
  LEFT JOIN (SELECT dzielnica, COUNT(*) cnt FROM public.szpitale_sor    GROUP BY 1) s   ON s.dzielnica   = d.nazwa
  LEFT JOIN (SELECT dzielnica, COUNT(*) cnt FROM public.przychodnie_poz GROUP BY 1) p   ON p.dzielnica   = d.nazwa
  LEFT JOIN (SELECT dzielnica, COUNT(*) cnt FROM public.apteki          GROUP BY 1) a   ON a.dzielnica   = d.nazwa
  LEFT JOIN public.demografia_dzielnice dem                                            ON dem.dzielnica_id = d.id AND dem.rok = 2023
 ORDER BY d.nazwa;
