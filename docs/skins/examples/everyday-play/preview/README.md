# Everyday Play review fixture

`prepare-preview.py` derives a stable review profile from the committed canonical
`classic-16-bit-v1` export. It preserves native geometry and bindings, assigns
`com.thumble.everyday-play@1.0.0`, and requests dark landscape presentation.
Run from any directory with Python 3. It does not modify app state.

The website uses the exact native normal render, without composited controls or
app chrome. The editable appearance lives in the parent workspace; native primary
legends and all interaction states remain renderer-owned.

Local Mac review uses a separate Everyday Play profile and retains existing
profiles and the default selection. It does not require a new app/CLI feature.
