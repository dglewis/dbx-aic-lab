-- Lab tables for the ScriptedSQL spike (docs/design.md "Data model").
-- Catalog: Free Edition default catalog `workspace` — adjust here (and the
-- TABLES map in idm-config/script/*.groovy) if current_catalog() differs.
-- Apply with: databricks/apply-sql.sh databricks/sql/001_lab_tables.sql

CREATE SCHEMA IF NOT EXISTS workspace.idm_lab;

-- Inbound source-of-record table. CDF on: the connector's sync token is the
-- Delta commit version via table_changes(), which also surfaces deletes.
CREATE TABLE IF NOT EXISTS workspace.idm_lab.business_records (
  record_id     STRING NOT NULL,
  ref_id        STRING,
  last_modified TIMESTAMP,
  CONSTRAINT business_records_pk PRIMARY KEY (record_id)
) TBLPROPERTIES (delta.enableChangeDataFeed = true);

-- Outbound target table: same shape, disjoint data (no sync loop possible).
CREATE TABLE IF NOT EXISTS workspace.idm_lab.outbound_records (
  record_id     STRING NOT NULL,
  ref_id        STRING,
  last_modified TIMESTAMP,
  CONSTRAINT outbound_records_pk PRIMARY KEY (record_id)
) TBLPROPERTIES (delta.enableChangeDataFeed = true);

-- Seed rows (idempotent).
MERGE INTO workspace.idm_lab.business_records t
USING (
  SELECT 'BR-001' AS record_id, 'REF-100' AS ref_id UNION ALL
  SELECT 'BR-002', 'REF-101' UNION ALL
  SELECT 'BR-003', 'REF-102'
) s ON t.record_id = s.record_id
WHEN NOT MATCHED THEN INSERT (record_id, ref_id, last_modified)
  VALUES (s.record_id, s.ref_id, current_timestamp());

MERGE INTO workspace.idm_lab.outbound_records t
USING (
  SELECT 'OB-901' AS record_id, 'REF-900' AS ref_id UNION ALL
  SELECT 'OB-902', 'REF-901'
) s ON t.record_id = s.record_id
WHEN NOT MATCHED THEN INSERT (record_id, ref_id, last_modified)
  VALUES (s.record_id, s.ref_id, current_timestamp());
