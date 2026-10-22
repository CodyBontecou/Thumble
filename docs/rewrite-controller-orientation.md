# Explicit controller orientation

Entering Connect or Practice requests a landscape controller interface through the native app module. This is an OS request, not a successful orientation receipt or input admission. React continues to mount the controller only when actual window width exceeds height. An unavailable/refused request leaves the visible rotate instruction; map compilation and exact viewport checks are unchanged.

`requestControllerLandscape()` returns an opaque route token. `restoreControllerOrientation(token)` restores the prior interface request/policy only for the latest owner. A superseding request retains the original policy, so a late cleanup from an earlier route cannot undo the current route. React also restores a request that completes after its route unmounts.

On iOS the helper requires exactly one foreground key-window scene, remembers its actual orientation and requests scene landscape geometry. The app's supported-orientation mask stays unchanged. Cleanup requests the original orientation on the same scene. On Android it temporarily requests sensor landscape on the current Activity and restores the original `requestedOrientation` value. Destroyed/missing Activities and ambiguous/unavailable scenes fail closed. Tokens confer no input, host or credential authority.

Geometry changes still flow through existing input cancellation and viewport binding. Camera permission, background retirement, source epochs, input deadlines and grant policy remain unchanged. Physical release builds and measured phone behavior establish OS request/restore acceptance separately from deterministic React async cleanup tests.
