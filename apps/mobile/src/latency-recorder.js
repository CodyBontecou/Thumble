// Opt-in diagnostics: monotonic clock samples and durations; never keys or input state.
export class LatencyRecorder {
  rows = [];
  counts = { sent: 0, acked: 0, pauses: 0, superseded: 0 };
  constructor(send) { this.send = send; }
  record(sent, receivedAt, jsNow, message) {
    const { receivedMs, hidMs, ackMs } = message.timing ?? {};
    const nativeRtt = receivedAt - sent.native;
    const jsRtt = jsNow - sent.js;
    if (![nativeRtt, jsRtt, receivedMs, hidMs, ackMs].every(Number.isFinite) || nativeRtt < 0 || jsRtt < 0 || hidMs < receivedMs || ackMs < hidMs) return;
    // Each row: kind, JS RTT, native RTT, Mac receive→HID submission,
    // Mac receive→ACK, native receive→JS callback + outbound bridge cost.
    this.counts.acked++;
    this.rows.push([sent.kind, jsRtt, nativeRtt, hidMs - receivedMs, ackMs - receivedMs, jsRtt - nativeRtt, sent.native, receivedMs, hidMs, ackMs, receivedAt, sent.transport ?? 'wss']);
    if (this.rows.length === 20) this.flush();
  }
  flush() {
    if (!this.rows.length && !this.counts.sent) return;
    this.send(JSON.stringify({ type: 'latency', counts: { ...this.counts }, rows: this.rows.map(row => row.map(value => typeof value === 'number' ? Math.round(value * 1000) / 1000 : value)) }));
    this.rows = [];
  }
}
