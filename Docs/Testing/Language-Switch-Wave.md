# Language-switch wave

The final wave lasts 80 ms. It starts at the language key and reveals the new
alphabet as it passes, with a small local refraction and a thin specular edge.
The effect does not gate input: another key press, suggestion selection, layout
rebuild, repeated switch or keyboard dismissal removes it immediately.

The outgoing snapshot covers the live layout during rebuilding. Refraction
reuses that rendered snapshot without forcing screen updates. The earlier live
glass material band was removed to avoid the bright flash. Reduce Motion uses
a short fade; Reduce Transparency omits the transparent lens and sheen.

Validated on the existing iPhone 17 Pro simulator (iOS 26.5): both language
directions, repeated toggles and typing immediately after a double toggle.
The typed H was retained, the suggestion rail remained usable, and no overlay
or mask remained after the transition. The containing app and extension build
successfully. No commit or push was made.
