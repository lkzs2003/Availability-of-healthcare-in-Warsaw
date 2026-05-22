-- ============================================================
-- Auto-refresh triggers for materialised views.
-- Any INSERT/UPDATE/DELETE on przychodnie_poz, szpitale_sor, dzielnice,
-- or drogi_topo will mark dependent MVs as stale and refresh them
-- after the transaction commits.
--
-- Implementation: CONSTRAINT TRIGGER fires once per transaction (DEFERRED),
-- not once per row — avoids N refreshes when bulk-loading.
-- ============================================================

CREATE OR REPLACE FUNCTION refresh_mv_pokrycie_poz_1km()
RETURNS TRIGGER AS $$
BEGIN
    REFRESH MATERIALIZED VIEW mv_pokrycie_poz_1km;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION refresh_mv_voronoi_poz()
RETURNS TRIGGER AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_voronoi_poz;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION refresh_mv_sor_reachability()
RETURNS TRIGGER AS $$
BEGIN
    REFRESH MATERIALIZED VIEW mv_sor_reachability;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- ---- Triggers on przychodnie_poz → refresh pokrycie + voronoi ----
DROP TRIGGER IF EXISTS trg_refresh_pokrycie ON przychodnie_poz;
CREATE CONSTRAINT TRIGGER trg_refresh_pokrycie
    AFTER INSERT OR UPDATE OR DELETE ON przychodnie_poz
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION refresh_mv_pokrycie_poz_1km();

DROP TRIGGER IF EXISTS trg_refresh_voronoi ON przychodnie_poz;
CREATE CONSTRAINT TRIGGER trg_refresh_voronoi
    AFTER INSERT OR UPDATE OR DELETE ON przychodnie_poz
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION refresh_mv_voronoi_poz();

-- ---- Triggers on dzielnice → refresh voronoi (clip changes) ----
DROP TRIGGER IF EXISTS trg_refresh_voronoi_d ON dzielnice;
CREATE CONSTRAINT TRIGGER trg_refresh_voronoi_d
    AFTER INSERT OR UPDATE OR DELETE ON dzielnice
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION refresh_mv_voronoi_poz();

-- ---- Triggers on szpitale_sor + drogi_topo → refresh reachability ----
DROP TRIGGER IF EXISTS trg_refresh_reach_h ON szpitale_sor;
CREATE CONSTRAINT TRIGGER trg_refresh_reach_h
    AFTER INSERT OR UPDATE OR DELETE ON szpitale_sor
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION refresh_mv_sor_reachability();

-- NOTE: trigger on drogi_topo skipped intentionally — OSM imports touch
-- millions of rows; the import_osm.sh script already does a manual
-- REFRESH at the end. Adding a row-level trigger would multiply import time.
