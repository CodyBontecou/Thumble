import { readFileSync } from 'node:fs';
const rows = readFileSync(process.argv[2], 'utf8').trim().split('\n').filter(Boolean).flatMap(line => JSON.parse(line).rows);
const percentile = (values, p) => [...values].sort((a,b)=>a-b)[Math.max(0,Math.ceil(values.length*p)-1)];
const metrics = ['jsRttMs', 'nativeRttMs', 'macReceiveToHidMs', 'macReceiveToAckMs', 'jsBridgeAndCallbackMs'];
const result = {};
for (const kind of ['all', 'touch', 'heartbeat', 'neutral']) {
  const group = rows.filter(row => kind === 'all' || row[0] === kind);
  if (!group.length) continue;
  result[kind] = { count: group.length };
  metrics.forEach((metric,i) => {
    const values = group.map(row=>row[i+1]);
    result[kind][metric] = Object.fromEntries([['p50', .50], ['p95', .95], ['p99', .99], ['max', 1]].map(([name,p])=>[name, percentile(values,p)]));
  });
  // The ACK can only return after HID submission. Removing the known ACK-side
  // Mac work gives a conservative native-send→HID upper bound, not a one-way estimate.
  const bounds = group.map(row=>row[2] - (row[4]-row[3]));
  result[kind].nativeSendToHidUpperBoundMs = { p50: percentile(bounds,.5), p95: percentile(bounds,.95) };
}
console.log(JSON.stringify(result,null,2));
