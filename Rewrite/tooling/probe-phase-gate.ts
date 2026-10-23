import assert from "node:assert/strict";
/** One bounded observer, quiesced before a command changes the recording phase. */
export class ProbePhaseGate {
  private observing = false;
  private commanding = false;
  private failure: { error: unknown } | undefined;
  private pending: Promise<void> = Promise.resolve();
  observe(work: () => Promise<void>): boolean {
    if (this.observing || this.commanding || this.failure) return false;
    this.observing = true;
    this.pending = Promise.resolve()
      .then(work)
      .catch((error: unknown) => {
        this.failure = { error };
      })
      .finally(() => {
        this.observing = false;
      });
    return true;
  }
  async command<T>(work: () => Promise<T>): Promise<T> {
    assert(!this.commanding, "probe_command_busy");
    this.commanding = true;
    try {
      await this.pending;
      if (this.failure) throw this.failure.error;
      return await work();
    } finally {
      this.commanding = false;
    }
  }
  async settle(): Promise<void> {
    await this.pending;
  }
}
