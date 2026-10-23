import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const quantile = (values, p) => values.length ? [...values].sort((a,b)=>a-b)[Math.max(0,Math.ceil(values.length*p)-1)] : null;
export function analyzeClockBounds(rows, { windowMs = 2000, driftPpm = 200, warmupMs = 0, durationMs = 60000 } = {}) {
  const timed = rows.filter(r=>r.length===12 && r.slice(6,11).every(Number.isFinite));
  const first = Math.min(...timed.map(r=>r[6]));
  const result = {};
  for (const transport of ['wss','udp']) {
    const group = timed.filter(r=>r[11]===transport && r[6]-first>=warmupMs && r[6]-first<warmupMs+durationMs);
    if (!group.length) continue;
    const intervals=[], native=[], mac=[];
    let forwardSpikes=0, returnSpikes=0, bothSpikes=0, ambiguousSpikes=0, invalid=0;
    for (const r of group) {
      let lower=-Infinity, upper=Infinity;
      // A sample bounds offset without assuming equal forward/return delay.
      // Nearby samples tighten it; expand each by the declared drift allowance.
      for (const s of timed) {
        const distance=Math.abs(s[6]-r[6]); if(distance>windowMs)continue;
        const drift=distance*driftPpm/1e6;
        lower=Math.max(lower,s[9]-s[10]-drift);
        upper=Math.min(upper,s[7]-s[6]+drift);
      }
      if(lower>upper || !Number.isFinite(lower+upper)) { invalid++; continue; }
      const forward=[Math.max(0,r[7]-r[6]-upper),Math.max(0,r[7]-r[6]-lower)];
      const backward=[Math.max(0,r[10]-r[9]+lower),Math.max(0,r[10]-r[9]+upper)];
      const hid=r[8]-r[7];
      intervals.push({forward,backward,hid:[forward[0]+hid,forward[1]+hid],uncertainty:upper-lower});
      native.push(r[2]);mac.push(r[3]);
      if(r[2]>40) {
        const f=forward[0]>20,b=backward[0]>20;
        if(f&&b)bothSpikes++;else if(f)forwardSpikes++;else if(b)returnSpikes++;else ambiguousSpikes++;
      }
    }
    const bounds = key => ({p50Lower:quantile(intervals.map(i=>i[key][0]),.5),p50Upper:quantile(intervals.map(i=>i[key][1]),.5),p95Lower:quantile(intervals.map(i=>i[key][0]),.95),p95Upper:quantile(intervals.map(i=>i[key][1]),.95)});
    result[transport]={count:group.length,validBounds:intervals.length,invalidBounds:invalid,nativeRtt:{p50:quantile(native,.5),p95:quantile(native,.95),p99:quantile(native,.99),max:quantile(native,1)},macReceiveToHidP95:quantile(mac,.95),forwardMs:bounds('forward'),returnMs:bounds('backward'),nativeSendToHidMs:bounds('hid'),offsetWidthP95:quantile(intervals.map(i=>i.uncertainty),.95),spikesOver40ms:{forwardSpikes,returnSpikes,bothSpikes,ambiguousSpikes},model:{windowMs,driftPpm,warmupMs,durationMs}};
  }
  return result;
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  const batches=readFileSync(process.argv[2],'utf8').trim().split('\n').filter(Boolean).map(line=>JSON.parse(line));
  const rows=batches.flatMap(b=>b.rows);
  console.log(JSON.stringify({bounds:analyzeClockBounds(rows,{warmupMs:Number(process.argv[3]??5000)}),lastCounts:[...batches].reverse().find(b=>b.counts)?.counts??null,receiverCounts:batches.at(-1)?.receiverCounts??null},null,2));
}
