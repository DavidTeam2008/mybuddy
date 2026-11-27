# Test media

- `TED.mp3` — Lauren Weinstein, *Don't believe everything you think* (TEDxPaloAlto). Used only as the source for the DEBUG fixture replay; the app never bundles or plays it.
- The fixture lasts 13:05 (08:31–21:36 of the talk). `tools/fixture-run.sh` derives a 48 kHz mono WAV or AAC copy under `.device-state/fixture-runs/<run-id>/`, pushes it to the app's Documents, and deletes it with the app container.
- The matching cue text for mechanical scoring is `tools/fixtures/ted-cue132-331.tsv`.
- Do not add derived WAV/AAC files or run evidence to git; `.device-state/` is gitignored.
