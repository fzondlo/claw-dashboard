# Raizia live listings import recommendation

## Recommended strategy

Start with a **pipeline-based importer architecture inside the Raizia app**, with **source-specific adapters** feeding a **shared normalized listing ingestion pipeline**.

**Primary recommendation:**
1. **Prefer licensed/API/feed sources first** for both sale and rental inventory.
2. Support **source-specific pull jobs** on schedules run by the app/job system, not by OpenClaw.
3. Normalize all raw records into a shared canonical listing model before dedupe, enrichment, and publish/deactivate logic.
4. Keep **raw payload snapshots + provenance** for every import so data can be audited, replayed, and corrected.
5. Start with **one source for rentals and one source for sales** only if legally allowed; otherwise start with the best single source that covers both and prove the pipeline end to end.

OpenClaw should only help design/build this. The actual ingestion must run via normal app jobs/cron/queue workers.

---

## Likely source options

### Tier 1: licensed feeds / partner APIs / broker exports
Best first choice.

Examples:
- MLS-style or portal partner feeds
- broker/agency XML/JSON exports
- property manager exports for rentals
- internal operator CSV/SFTP drops during early rollout

Why this is best:
- strongest legal footing
- usually more stable schemas
- easier update/deactivation handling
- lower scraper maintenance burden
- clearer permission for photos and listing text

Tradeoffs:
- slower business development
- may cost money
- coverage may start narrow

### Tier 2: aggregator contracts / paid data vendors
Good if direct partner coverage is too fragmented.

Why:
- faster geographic coverage
- sometimes includes change feeds
- can cover both sales and rentals faster than individual broker deals

Tradeoffs:
- higher cost
- dependency on vendor contract and SLA
- less control over provenance depth

### Tier 3: controlled scraping of sources you are explicitly allowed to ingest
Only use where terms/permission are clear.

Why:
- can fill gaps when feeds do not exist
- useful for narrowly targeted launch markets

Tradeoffs:
- highest legal/compliance risk
- fragile selectors / anti-bot issues
- image/text licensing may be restricted
- higher ops burden
- harder to guarantee freshness and deletion compliance

### Tier 4: manual uploads as temporary bootstrap only
Useful for getting the pipeline live before external integrations are ready.

Why:
- fastest way to validate the pipeline architecture
- lets Raizia build normalization/dedupe/provenance now

Tradeoffs:
- not truly live
- operationally heavy
- should be treated as a temporary source type only

---

## Recommendation on source acquisition

For Raizia, the best starting move is:

1. **Secure at least one permitted feed/export source for rentals** (property managers / agencies).
2. **Secure at least one permitted feed/export source for sale listings** (broker networks / agencies).
3. If one partner can provide both, use that first.
4. Build scraping adapters only after the normalized pipeline exists and only for explicitly approved sources.

This gives Raizia a system that can later mix:
- partner API feeds
- CSV/XML uploads
- SFTP drops
- paid vendor feeds
- approved scraping adapters

without changing downstream pipeline logic.

---

## Recommended ingestion architecture

```text
Source adapter job
  -> raw source fetch
  -> raw payload storage
  -> source record checkpointing
  -> normalization into canonical listing shape
  -> identity resolution / dedupe
  -> validation + rule checks
  -> enrichment pipeline
  -> upsert canonical listing
  -> publish/update status
  -> missing-record reconciliation / deactivate
  -> metrics + alerts
```

### 1) Source-specific importers
Create one importer class per source, for example:
- `Importers::PartnerApi::AcmeRealtyImporter`
- `Importers::Sftp::RentalFeedImporter`
- `Importers::Csv::BrokerUploadImporter`
- `Importers::ApprovedScrape::FooPortalImporter`

Each importer should handle only:
- authentication / fetch
- pagination / checkpoints
- source schema parsing
- source-specific rate limits
- mapping to a shared normalized record format

Do **not** let source importers write directly to user-facing listing tables.

### 2) Raw ingestion layer
Persist every fetch batch and optionally each raw listing record.

Recommended tables/storage:
- `listing_sources`
- `listing_import_runs`
- `listing_raw_records`
- blob/file storage for large raw payload snapshots

Store:
- source name
- external listing id
- fetched_at
- checksum/hash of raw payload
- import run id
- raw JSON/XML payload
- source URL / feed path
- license/permission metadata

Why:
- replayability
- audit trail
- easier parser debugging
- supports backfills and reprocessing after mapper changes

### 3) Canonical normalized schema
Define a single internal listing contract used by every source.

Core fields:
- source_id
- source_listing_id
- listing_type (`sale` / `rent`)
- property_type
- status (`active`, `pending`, `off_market`, `deactivated`)
- price
- currency
- address components
- lat/lng
- neighborhood / city / country
- beds / baths / area
- description
- features/amenities
- photos
- contact/broker info
- first_seen_at
- last_seen_at
- source_updated_at
- provenance fields

Use a normalized intermediary object, e.g. `NormalizedListing`, before database upsert.

### 4) Identity resolution and dedupe
Dedupe is critical because the same property may appear:
- in multiple feeds
- as both sale and rent at different times
- with slightly different address formatting
- after relisting with new source ids

Recommended identity model:
- **Primary key:** `(source_id, source_listing_id)` for exact source tracking
- **Secondary fingerprint:** stable property fingerprint from normalized address + unit + geocode + area + key attributes
- **Candidate duplicate matching:** fuzzy match on location, bedrooms, area, photos, broker, and price band

Recommendation:
- Start with conservative dedupe.
- Merge only when confidence is high.
- Otherwise keep separate records linked by a `duplicate_group_id` / `property_cluster_id` for later review.

### 5) Enrichment layer
Run enrichment after normalization, not inside fetchers.

Possible enrichments:
- geocoding / address cleanup
- neighborhood and polygon assignment
- price-per-m2
- amenity extraction
- language cleanup / translation normalization
- image hashing for duplicate detection
- quality scoring / completeness scoring

This should run as queued follow-up jobs so imports remain robust even if enrichment is slow.

### 6) Publish + update + deactivate handling
Recommended behavior:
- Upsert active listings when present in a feed.
- Update mutable fields when source checksum changes.
- Mark records `stale` if missing from a source for N consecutive imports.
- Mark records `deactivated` / `off_market` after a configurable threshold.
- Never hard-delete immediately; keep historical provenance.

This is especially important for rentals, where turnover is faster.

---

## Operational model

## Scheduling
Use normal app scheduling and background jobs.

Recommended cadence:
- rentals: every 15-60 minutes depending on source limits
- sales: every 1-6 hours depending on source freshness and volume
- full reconciliation/backfill jobs: nightly
- enrichment retries / dead-letter reprocessing: continuous or every few minutes

Implementation options in Rails:
- cron -> `bin/rails runner` / scheduler entrypoints
- or a scheduler gem / platform scheduler that enqueues Active Jobs
- Active Job + Solid Queue workers for execution and retries

### Job types to build
- `ListingSourceSyncJob` - kick off source sync for one source
- `ListingImportBatchJob` - process a fetched page/file/batch
- `ListingNormalizeAndUpsertJob` - normalize and upsert records
- `ListingEnrichmentJob` - geocode/derive metrics
- `ListingReconcileMissingJob` - handle stale/deactivation logic
- `ListingBackfillJob` - replay historical/raw data

### Retries and failure isolation
- Retry transient network/auth failures with exponential backoff.
- Isolate failures by source and by batch.
- Do not fail the whole import because one listing record is malformed.
- Send alerts on repeated source failures, schema drift, or high deactivation spikes.

### Backfills
Backfills should be first-class.

Needed capabilities:
- rerun a source for a date range
- replay from stored raw payloads after mapper changes
- re-run enrichment on existing listings
- rebuild fingerprints / duplicate clusters

### Provenance
Each published listing should retain:
- current source
- first seen timestamp
- last seen timestamp
- last imported run id
- raw record reference
- source URL
- license/permission tag

This supports trust, debugging, and takedown handling.

---

## Tradeoffs

## Freshness
- APIs/feeds: usually best balance of freshness and stability
- scraping: can be fresh but often blocked or inconsistent
- manual uploads: lowest freshness

**Recommendation:** optimize rentals for faster cadence than sales.

## Legality / compliance
- licensed feeds and direct exports are safest
- scraping without clear permission is the riskiest path
- photos/descriptions often have stricter rights than factual listing fields

**Recommendation:** require source-level compliance metadata and approval before activation.

## Reliability
- APIs/feeds are usually more predictable
- source-specific parser drift is manageable with versioned adapters
- scraping is highest-maintenance

**Recommendation:** build source adapters behind a common interface with import-run observability.

## Deduping difficulty
- multi-source aggregation creates duplicate risk
- rentals may churn quickly and relist often
- sale/rent may refer to same property but different commercial records

**Recommendation:** separate listing identity from property identity; keep both concepts.

## Enrichment value
- geocoding, neighborhood assignment, and price-per-m2 materially improve search quality
- enrichment should be asynchronous and replayable

**Recommendation:** make enrichment downstream and optional, never blocking ingestion success.

## Ops burden
- single-source API/feed is low burden
- many sources and scraping adapters raise pager/maintenance load quickly

**Recommendation:** ship one robust source pipeline first, then add sources gradually.

---

## Smallest viable pipeline to build first

Build the minimum system that proves the architecture end to end:

### Phase 1 MVP
1. One source adapter using the easiest legal structured source (CSV, XML, JSON API, or SFTP export).
2. Support both `sale` and `rent` in the canonical schema even if the first live source only fills one heavily.
3. Raw payload persistence.
4. Normalization layer.
5. Basic upsert into canonical listings table.
6. Exact-source dedupe using `(source_id, source_listing_id)`.
7. `last_seen_at` tracking and stale/deactivation job.
8. Basic observability: import runs, counts, failures, changed records.

### Phase 2
1. Second source adapter.
2. Property fingerprinting and cross-source duplicate detection.
3. Enrichment jobs.
4. Backfill/replay tooling.
5. Alerting and dashboards.

### Phase 3
1. Approved scrape adapters if still needed.
2. Source quality scoring.
3. Broker/agent dedupe and entity resolution.
4. Better image-based duplicate matching.

---

## Concrete implementation recommendation

If Raizia is a Rails app, implement this as:

### Data model additions
- `listing_sources`
- `listing_import_runs`
- `listing_raw_records`
- `property_clusters` or equivalent
- `listings` (canonical user-facing records)
- optional `listing_versions` / change log

### Service objects / pipeline classes
- `Listings::Sources::<SourceName>::Client`
- `Listings::Sources::<SourceName>::Mapper`
- `Listings::Ingestion::NormalizedListing`
- `Listings::Ingestion::Upserter`
- `Listings::Ingestion::DuplicateResolver`
- `Listings::Ingestion::Reconciler`
- `Listings::Enrichment::*`

### Jobs
- one scheduler entrypoint per source
- fan out by page/batch
- follow-up enrichment and reconcile jobs

### Storage pattern
- raw source payloads in DB or object storage
- canonical searchable records in app DB
- checksums to avoid no-op rewrites

### Idempotency rules
Every job should be idempotent using:
- import run ids
- source record hashes
- unique keys on `(source_id, source_listing_id)`
- safe upsert semantics

---

## Recommended first build after approval

1. **Choose the first approved live source** with the best legal footing and structured data access.
2. Define the **canonical listing schema** and normalized object contract.
3. Build the **import run + raw payload tables** first.
4. Implement **one importer + mapper + upsert path**.
5. Add **scheduled job execution** via the app scheduler/queue, not OpenClaw.
6. Add **stale/deactivation reconciliation**.
7. Add lightweight **ops visibility**:
   - last successful sync per source
   - listings imported/updated/deactivated
   - failure counts
   - schema drift warnings
8. Only then add a second source and cross-source dedupe.

---

## Bottom-line recommendation

**Raizia should not start with ad-hoc scraping scripts or OpenClaw-triggered imports.**

Raizia should start with a **licensed-feed-first, source-adapter-based ingestion pipeline inside the app’s normal jobs system**, with:
- scheduled source sync jobs
- raw payload storage
- canonical normalization
- idempotent upserts
- provenance on every listing
- stale/deactivation reconciliation
- source-specific adapters behind a shared pipeline

This is the smallest path that is:
- legally safer
- operationally maintainable
- compatible with both sale and rental listings
- expandable to more sources later
- runnable fully outside OpenClaw in normal production workflows
