-- Aggregate tracked subscribers, without selecting emails or pairing data.
SELECT json_extract(first_touch, '$.landing') AS first_landing,
       first_source, COUNT(*) AS tracked_subscribers
FROM waitlist_attribution
GROUP BY first_landing, first_source
ORDER BY tracked_subscribers DESC;

SELECT json_extract(latest_touch, '$.landing') AS latest_landing,
       latest_source, COUNT(*) AS tracked_subscribers
FROM waitlist_attribution
GROUP BY latest_landing, latest_source
ORDER BY tracked_subscribers DESC;
