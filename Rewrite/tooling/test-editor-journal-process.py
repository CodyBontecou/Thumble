#!/usr/bin/env python3
"""Synthetic macOS process-kill witness for the actual Swift private journal adapter."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

HELPER = r'''
import Foundation
import Darwin
@main struct JournalProcessWitness {
  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { exit(2) }
    let pin = String(repeating: "a", count: 64)
    let scope = try EditorHostScope(certificateSHA256: pin, authorityInstanceID: "11111111-1111-1111-1111-111111111111")
    let mode = arguments[2]
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let store = try EditorJournalFileStore(directory: directory, certificateSHA256: pin, fault: { point in
      if (mode == "before" && point == .beforeReplace) || (mode == "after" && point == .afterReplace) { kill(getpid(), SIGKILL) }
    })
    let journal = try EditorJournal(certificateSHA256: pin, storage: store)
    if mode == "read" {
      print(journal.snapshot.entries.map { $0.intent.operationID }.joined(separator: ","))
      return
    }
    let intent = try EditorLabelIntent(scope: scope, operationID: mode == "seed" ? "first" : "second", expectedRevision: "7", profileID: "aaaaaaaa-0000-0000-0000-000000000001", controlID: "ce000000-0000-0000-0000-000000000001", label: "Synthetic")
    try journal.enqueue(intent)
  }
}
'''

def main():
    if sys.platform != "darwin":
        raise SystemExit("editor_journal_process_requires_macos")
    root = Path(__file__).resolve().parents[1]
    sources = root / "native/mobile-input/ios/Sources/MobileInputCore"
    with tempfile.TemporaryDirectory(prefix="thumble-editor-process-") as temporary:
        owned = Path(temporary).resolve()
        helper = owned / "witness.swift"
        helper.write_text(HELPER)
        binary = owned / "witness"
        built = subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *[str(sources / name) for name in ["EditorJournal.swift", "EditorJournalCodec.swift", "EditorJournalFileStore.swift"]], str(helper), "-o", str(binary)], capture_output=True, timeout=60)
        if built.returncode != 0:
            raise SystemExit("editor_journal_process_compile_failed")
        for mode, expected in [("before", "first"), ("after", "first,second")]:
            directory = owned / mode
            directory.mkdir(mode=0o700)
            def invoke(action):
                return subprocess.run([str(binary), str(directory), action], capture_output=True, timeout=5)
            if invoke("seed").returncode != 0:
                raise SystemExit("editor_journal_process_seed_failed")
            killed = invoke(mode)
            if killed.returncode != -signal.SIGKILL:
                raise SystemExit("editor_journal_process_kill_not_observed")
            reopened = invoke("read")
            if reopened.returncode != 0 or reopened.stdout.decode().strip() != expected:
                raise SystemExit("editor_journal_process_reopen_failed")
        print(json.dumps({"kind": "editor-journal-process-witness", "version": 1, "beforeReplace": "whole-old", "afterReplace": "whole-new", "powerLossTested": False}, sort_keys=True))

if __name__ == "__main__":
    main()
