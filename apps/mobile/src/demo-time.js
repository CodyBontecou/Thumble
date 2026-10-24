// Round up so the first second reads 30:00 and 0:00 means fully exhausted.
export function formatDemoTime(remaining) {
  const seconds = Math.max(0, Math.ceil(remaining));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}
