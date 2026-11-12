# Thumble Search Console baseline — October 26, 2026

The existing `sc-domain:thumble.io` property is accessible through the signed-in browser, and Settings confirms verified ownership. The property was added to the account on October 25, 2026. No new Google permissions, DNS verification records, paid integrations or API credentials were created. This confirms access to the existing property; it does not establish a new API/MCP connection.

## Initial search-performance snapshot

[Open the exact report](https://search.google.com/search-console/performance/search-analytics?resource_id=sc-domain%3Athumble.io&start_date=20260927&end_date=20261024).

The requested reporting window is September 27–October 24, 2026, inclusive: 28 days, Web search, all countries and devices, no query/page filters. Search Console dates use Pacific Time. The UI chart currently contains only October 24 and reports its last update as three hours ago. Do not interpret this as 28 fully populated reporting days or as evidence that no traffic existed before the property was available.

| Metric | Observed value | Interpretation |
| --- | --- | --- |
| Clicks | 0 | Current reported snapshot |
| Impressions | 0 | Current reported snapshot |
| CTR | UI displays 0% | No meaningful rate without impressions |
| Average position | UI displays 0 | No measured ranking; not position zero |
| Queries | No data | No query opportunities can be ranked yet |
| Landing pages | No data | No page-performance comparison yet |
| Countries | No data | No market priorities supported yet |
| Devices | No data | No device-performance comparison yet |

This is an initial baseline, not a mature pre/post experiment. New guide batches were deployed October 26, after the report's latest chart date. The snapshot cannot measure their results yet.

## Discovery and indexing

The overall Page indexing report says “Processing data, please check again in a day or so.” Indexed and excluded totals are unavailable, not zero.

The guide hub (`https://thumble.io/guides`) was inspected: Google Index reports it is unknown and not indexed, with no referring sitemap detected. Google's live test on October 26 says “URL is available to Google” and “Page can be indexed,” with one valid breadcrumb item. An indexing request was accepted and the URL was added to the priority crawl queue. This is a queued request, not confirmation of indexing; other article URLs were not individually inspected in this pass.

The sitemap submitted October 25 had “Couldn't fetch,” unknown type and zero discovered pages. A direct HTTPS check on October 26 returned HTTP 200, application/xml, valid XML and 18 URLs with both ordinary and Googlebot user agents. Spoofing a user-agent alone does not reproduce Googlebot's network path; the separate live hub test is the positive Google-side fetch evidence.

The same sitemap URL was resubmitted October 26 and Google displayed “Sitemap submitted successfully.” The table still showed “Couldn't fetch” at the end of this inspection. Successful ingestion is therefore unconfirmed. Do not mark all 18 URLs discovered or indexed. Settings also has no robots.txt or crawl-stat data yet; that is a Search Console observation, not proof the public robots file is absent.

## Follow-up decisions

1. Recheck sitemap status after Google processes the submission. If the fetch failure persists, inspect Google's latest error and Cloudflare security/request evidence before changing DNS, robots or WAF rules. The current public XML is valid, and Google can fetch the hub.
2. Inspect the homepage and individual guides as indexing data becomes available. The hub request is enough to start; repeatedly submitting the same URL does not improve its queue priority.
3. Revisit the exact date range and a rolling 28-day Web report around November 2. Capture totals and query/page/country/device tables with the actual available dates and data freshness.
4. Once impressions appear, separate branded from relevant nonbrand queries, assess pages with impressions but few clicks, and compare qualified signup attribution by landing page. No keyword priorities or uplift claims are justified by the current empty report.
5. For repeatable API retrieval later, connect an authorized Search Console data integration or a read-only OAuth client. Existing Google Cloud CLI login is not proof it has Search Console API scopes. The optional Windsor.ai integration was discovered but was not installed or connected, and it was not needed to access the browser reports. No recurring job has been created.

## Evidence

[Machine-readable baseline](../evidence/search-console-2026-10-26/baseline.json) and [observed metrics CSV](../evidence/search-console-2026-10-26/metrics.csv) are transcriptions of the visible reports, not claims of a successful Google export. The UI CSV export was invoked, but no downloaded artifact was confirmed and it is not used as evidence.

Screenshots and accessibility captures are stored in `docs/evidence/search-console-2026-10-26/`. They cover performance tables, verified property settings, pending indexing, successful sitemap resubmission, the live hub test and accepted indexing request. Account labels in text captures are redacted; no browser cookies or OAuth tokens were read or saved.

Primary references: [Google performance report definitions](https://support.google.com/webmasters/answer/7576553), [Search Analytics API and Pacific reporting dates](https://developers.google.com/webmaster-tools/v1/searchanalytics/query), [URL Inspection guidance](https://support.google.com/webmasters/answer/9012289).
