# Native control terminal diagnostic

The iOS native CI lane explicitly enables `THUMBLE_REWRITE_CONTROL_TERMINAL_PROBE=1` for its synthetic debug executables. A debug-only diagnostic records at most64 closed-control outcomes per process as `native_control_terminal code=FIXED_STATIC_SYMBOL elapsed_us=NUMBER`. Only nonempty lowercase/underscore static error symbols up to96 bytes survive; other values become `other`. No payload, credential, endpoint, phone label or exception text is logged.

The outcome is observed after authenticated-control locals have cleaned up. It describes the returned terminal outcome and must not be presented as a proven pre-cleanup first cause. Normal successful closure emits no diagnostic. Aggregate timing probes remain separately disabled by default, and release builds compile this call out. The diagnostic changes no grants, input deadlines, routing, retry or retirement behavior.

This is temporary evidence for runner failures where phone progress sees a closed TLS stream after native cleanup. A passing local or physical test does not certify a failing remote run; preserve the fixed outcome and reproduce before changing behavior.
