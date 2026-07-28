-- Lab tables for the connector spike (docs/design.md "Data model").
-- Run in the Free Edition SQL editor. Adjust catalog if not using the default.

CREATE SCHEMA IF NOT EXISTS idm_lab;

-- Inbound source: IDM reads (recon + liveSync) and writes (CRUD spike).
CREATE TABLE IF NOT EXISTS idm_lab.business_records (
  record_id     STRING NOT NULL,
  ref_id        STRING,
  last_modified TIMESTAMP NOT NULL
)
TBLPROPERTIES (delta.enableChangeDataFeed = true);  -- serves ScriptedSQL sync path if fallback triggers

-- Outbound target: IDM writes via the outbound mapping. Disjoint dataset.
CREATE TABLE IF NOT EXISTS idm_lab.outbound_records (
  record_id     STRING NOT NULL,
  ref_id        STRING,
  last_modified TIMESTAMP NOT NULL
)
TBLPROPERTIES (delta.enableChangeDataFeed = true);

-- Seed rows (timestamps: UTC, full microseconds — see design.md format spec)
INSERT INTO idm_lab.business_records VALUES
  ('br-001', 'ref-100', TIMESTAMP'2026-07-28T08:00:00.000001Z'),
  ('br-002', 'ref-101', TIMESTAMP'2026-07-28T08:00:00.000002Z'),
  ('br-003', 'ref-102', TIMESTAMP'2026-07-28T08:00:00.000003Z');

-- liveSync probe rows are inserted manually during the spike, e.g.:
-- INSERT INTO idm_lab.business_records VALUES ('br-999','ref-999', current_timestamp());
