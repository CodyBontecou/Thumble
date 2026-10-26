-- Additive: existing subscribers and their original consent records are unchanged.
-- Apply before publishing the attribution-aware signup endpoint.
CREATE TABLE IF NOT EXISTS waitlist_attribution (
  subscriber_id INTEGER PRIMARY KEY REFERENCES waitlist_subscribers(id) ON DELETE CASCADE,
  first_source TEXT NOT NULL,
  latest_source TEXT NOT NULL,
  first_touch TEXT NOT NULL,
  latest_touch TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
