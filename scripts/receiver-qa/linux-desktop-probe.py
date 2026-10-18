#!/usr/bin/env python3
"""Isolated guest UI witness: records input delivered to this Tk window by Xorg.
Run with DISPLAY pointing at the guest desktop, never on a personal desktop.
"""
import json
import os
import pathlib
import time
import tkinter as tk

output = pathlib.Path(os.environ.get("THUMBLE_DESKTOP_EVIDENCE", "/tmp/thumble-desktop-events.jsonl"))
root = tk.Tk()
root.title("Thumble Linux desktop input witness")
root.geometry("1100x720+20+20")
root.configure(bg="#111827")
label = tk.Label(root, text="Thumble → Linux VM\nNative keyboard and mouse delivery", bg="#111827", fg="white", font=("Sans", 25))
label.pack(pady=24)
entry = tk.Entry(root, font=("Sans", 30), width=32)
entry.pack(pady=20)
status = tk.StringVar(value="Waiting for iPhone input")
tk.Label(root, textvariable=status, bg="#111827", fg="#86efac", font=("Sans", 18)).pack(pady=12)
log = tk.Text(root, font=("Monospace", 13), width=95, height=16)
log.pack(padx=20, pady=12)

def observe(event):
    record = {"time": time.time(), "type": str(event.type), "x": event.x_root, "y": event.y_root}
    if event.type in (tk.EventType.KeyPress, tk.EventType.KeyRelease):
        record.update(keysym=event.keysym, keycode=event.keycode, char=event.char, state=event.state)
    elif event.type in (tk.EventType.ButtonPress, tk.EventType.ButtonRelease):
        record["button"] = event.num
    with output.open("a") as handle:
        handle.write(json.dumps(record) + "\n")
    status.set("iPhone input observed: " + record["type"] + " " + record.get("keysym", str(record.get("button", ""))))
    log.insert("end", json.dumps(record) + "\n")
    log.see("end")

for sequence in ("<KeyPress>", "<KeyRelease>", "<ButtonPress>", "<ButtonRelease>", "<Motion>"):
    root.bind_all(sequence, observe, add="+")
root.after(500, lambda: (root.lift(), entry.focus_force()))
root.mainloop()
