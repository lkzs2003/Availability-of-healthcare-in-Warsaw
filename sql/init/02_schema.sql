-- ============================================================
-- Schema — Dostępność opieki zdrowotnej w Warszawie
-- Układ współrzędnych: EPSG:2180 (PL-1992)
-- ============================================================

-- Centralised Warsaw bounding box in EPSG:2180.
-- Single source of truth — used by seed grid, S2 grid queries, E3 random points.
-- xmin/ymin/xmax/ymax expressed in metres (PL-1992).
CREATE OR REPLACE VIEW warszawa_bbox AS
SELECT 630000::NUMERIC AS xmin,
       490000::NUMERIC AS ymin,
       680000::NUMERIC AS xmax,
       525000::NUMERIC AS ymax,
       ST_MakeEnvelope(630000, 490000, 680000, 525000, 2180) AS geom;

-- Districts (18 districts of Warsaw)
CREATE TABLE IF NOT EXISTS dzielnice (
    id               SERIAL PRIMARY KEY,
    nazwa            TEXT NOT NULL UNIQUE,
    powierzchnia_km2 NUMERIC(8, 3),
    geom             GEOMETRY(MULTIPOLYGON, 2180) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dzielnice_geom ON dzielnice USING GiST (geom);

-- District demographics
CREATE TABLE IF NOT EXISTS demografia_dzielnice (
    id             SERIAL PRIMARY KEY,
    dzielnica_id   INTEGER NOT NULL REFERENCES dzielnice (id),
    rok            INTEGER NOT NULL DEFAULT 2023,
    ludnosc        INTEGER NOT NULL,
    gestosc_os_km2 NUMERIC(10, 2),
    UNIQUE (dzielnica_id, rok)
);

-- Primary healthcare clinics (POZ — Podstawowa Opieka Zdrowotna)
CREATE TABLE IF NOT EXISTS przychodnie_poz (
    id        SERIAL PRIMARY KEY,
    nazwa     TEXT NOT NULL,
    adres     TEXT,
    nr_rpwdl  TEXT,
    geom      GEOMETRY(POINT, 2180) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_przychodnie_poz_geom  ON przychodnie_poz USING GiST (geom);
CREATE INDEX IF NOT EXISTS idx_przychodnie_poz_rpwdl ON przychodnie_poz (nr_rpwdl);

-- Hospitals with emergency rooms (SOR — Szpitalny Oddział Ratunkowy)
CREATE TABLE IF NOT EXISTS szpitale_sor (
    id    SERIAL PRIMARY KEY,
    nazwa TEXT NOT NULL,
    adres TEXT,
    geom  GEOMETRY(POINT, 2180) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_szpitale_sor_geom ON szpitale_sor USING GiST (geom);
CREATE INDEX IF NOT EXISTS idx_szpitale_sor_nazwa ON szpitale_sor (nazwa);

-- Pharmacies
CREATE TABLE IF NOT EXISTS apteki (
    id    SERIAL PRIMARY KEY,
    nazwa TEXT NOT NULL,
    adres TEXT,
    geom  GEOMETRY(POINT, 2180) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_apteki_geom  ON apteki USING GiST (geom);
CREATE INDEX IF NOT EXISTS idx_apteki_nazwa ON apteki (nazwa);

-- Road network vertices (nodes) — BIGINT to match pgRouting return types
CREATE TABLE IF NOT EXISTS drogi_vertices (
    id   BIGINT PRIMARY KEY,
    geom GEOMETRY(POINT, 2180)
);

CREATE INDEX IF NOT EXISTS idx_drogi_vertices_geom ON drogi_vertices USING GiST (geom);

-- Road network edges (topology) — BIGINT throughout.
-- NOT NULL on (source, target, cost) prevents corrupt graph rows that crash pgRouting.
-- FK to drogi_vertices(id) is DEFERRABLE so bulk seed inserts (vertices then edges)
-- still work and OSM import can stage rows before referential validation.
CREATE TABLE IF NOT EXISTS drogi_topo (
    id           BIGSERIAL PRIMARY KEY,
    source       BIGINT NOT NULL,
    target       BIGINT NOT NULL,
    cost         DOUBLE PRECISION NOT NULL,   -- metres
    reverse_cost DOUBLE PRECISION,            -- metres; nullable (one-way edges may use -1)
    geom         GEOMETRY(LINESTRING, 2180),
    CONSTRAINT fk_drogi_topo_source
        FOREIGN KEY (source) REFERENCES drogi_vertices (id)
        DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_drogi_topo_target
        FOREIGN KEY (target) REFERENCES drogi_vertices (id)
        DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX IF NOT EXISTS idx_drogi_topo_source ON drogi_topo (source);
CREATE INDEX IF NOT EXISTS idx_drogi_topo_target ON drogi_topo (target);
CREATE INDEX IF NOT EXISTS idx_drogi_topo_geom   ON drogi_topo USING GiST (geom);
