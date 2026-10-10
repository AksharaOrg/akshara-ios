# Expanded simulator typing study — 2026-10-11

The Release extension built from `243ada7` ran in the containing app's vertical Setup `TextField` on an iPhone 17 Pro simulator, iOS 26.5. All four primary runs contain exactly 512 paired KeyHandling intervals with the expected mode ID, including 320 letter taps, 128 Space taps and 64 Delete taps. Each also contains 64 actual DeleteHandling intervals on later main-loop turns. A separate 137-event Smart Phonetic run exercised autocorrect with the suggestion rail hidden.

The measured handlers are short in these scenarios. This is an optimized-build diagnostic, with no pre-optimization comparison. The 30% improvement target and physical-device acceptance remain unverified.

## Typing and word boundaries

All values are milliseconds; percentiles use nearest rank. Host-subtracted timing removes the union of enclosed proxy calls on the same thread. It does not include deferred rendering or other main-thread work outside KeyHandling.

| Mode | Key median | Key p95 | Key max | Key p95 excluding host calls | Space p95 | DeleteHandling p95 |
|---|---:|---:|---:|---:|---:|---:|
| Wijesekara | 0.5862 | 1.0152 | 7.4934 | 0.9372 | 1.0320 | 0.7810 |
| Phonetic | 0.7520 | 1.2420 | 12.6373 | 1.1802 | 1.4792 | 0.6141 |
| Smart Phonetic | 0.7249 | 1.3310 | 8.9856 | 1.2648 | 1.6597 | 0.5253 |
| English | 0.8445 | 1.2517 | 9.2309 | 1.1916 | 1.2645 | 0.7312 |

Space and letter attribution comes from the controlled tap order, checked against the exact paired event count; signposts do not record typed keys. The Wijesekara sequence repeats `ම`, `ම`, Space, `ක`, `ම`, `ල`, Space, Delete. The other three modes repeat `m`, `a`, `m`, `a`, Space, `k`, Space, Delete. The field visibly followed those sequences. The same field retained earlier test text between modes, so workloads and context lengths differ; this table is not a controlled ranking of the four modes.

## Rendering, background work and startup

| Mode | Rail p95 | Background ranking p95 | Ranking max | Worker queue delay p95 | Sinhala preparation | Correction preparation |
|---|---:|---:|---:|---:|---:|---:|
| Wijesekara | 0.1643 | 9.8517 | 46.2896 | 0.0512 | 368.0462 | 189.5405 |
| Phonetic | 0.1155 | 0.2492 | 3.2697 | 0.0552 | 349.4421 | 63.9004 |
| Smart Phonetic | 0.1272 | 0.2923 | 3.4183 | 0.0654 | 262.2383 | 88.6048 |
| English | 0.1855 | 2.1532 | 7.0564 | 0.0782 | — | — |

Each mode used a fresh extension process, with warmed host filesystem caches. Preparation finished before automated taps began; these are startup task durations, not cold first-key latency. The differing preparation times should not be interpreted as mode-specific model changes. English preparation took 0.4459 ms in its primary run.

Sinhala ranking's Wijesekara tail remains the largest prediction cost in these samples. Low observed queue delays do not establish behavior under rapid typing. Outliers also remain outside ranking: Wijesekara RailRendering reached 9.2596 ms, and Phonetic KeyHandling reached 12.6373 ms. The initial 8 ms target applies to p95 of complete extension-owned main-thread work, which these individual intervals do not fully measure.

Nested proxy counts across 512 KeyHandling intervals were:

| Mode | Before reads | After reads | Selection reads | Inserts | Deletes |
|---|---:|---:|---:|---:|---:|
| Wijesekara | 576 | 0 | 128 | 448 | 0 |
| Phonetic | 704 | 0 | 128 | 320 | 128 |
| Smart Phonetic | 704 | 0 | 128 | 320 | 128 |
| English | 576 | 576 | 576 | 448 | 0 |

Deletes handled later and prediction/host-callback reads are outside this table. English's total exported reads are higher because suggestion capture also accesses the host. Simulator reads are inexpensive; these counts cannot establish their cost in a messaging app on a device.

## Autocorrect with predictions hidden

Smart Phonetic used autocorrect on and suggestions off for 137 taps: 103 letters, 26 Space taps and eight Delete taps. No RailRendering or SinhalaRanking intervals were exported for this run. The keyboard visibly corrected the fixture `ගෙදරා` to `ගෙදර` on Space, restored `ගෙදරා` on immediate Delete, and retained the rejected spelling on the next Space. Later repetitions kept the rejected spelling. An initial nine-tap spelling exercise is included in this sample; `gedharaa` produced the intended fixture.

KeyHandling measured 1.9740 ms p95, or 1.9157 ms excluding nested host calls. Space measured 3.8973 ms p95; the observed ready correction's Space took 4.0523 ms. Actual DeleteHandling reached 2.0684 ms during undo. Correction preparation took 111.0041 ms. One Sinhala persistence interval lasted 595.8029 ms on a different thread from key handling; with only two persistence samples, this does not establish a distribution or its cause.

The ready-result case, undo and rejection were checked in the simulator. Immediate literal commit when a result is unavailable remains covered by regression fixtures, rather than a controlled delayed-provider simulator exercise.

## Reproduction and artifacts

[runs.json](runs.json) records process IDs, mode IDs, feature settings, capture times and the tap-role sequences. Each run has compressed raw Performance-category signposts, compressed paired intervals and a readable statistics table. Metadata contains durations, IDs, generations and counts, without typed text or touch coordinates. Mach conversion uses the recording Mac's 125/3 timebase.

For example:

```sh
python3 Scripts/analyze_keyboard_signposts.py \
  Docs/Performance/Simulator-2026-10-11/Expanded/phonetic.ndjson.gz \
  --timebase-numer 125 --timebase-denom 3 \
  --key-pattern letter,letter,letter,letter,space,letter,space,delete \
  --expected-keys 512 --output /tmp/phonetic-intervals.json

python3 Scripts/analyze_keyboard_signposts.py \
  Docs/Performance/Simulator-2026-10-11/Expanded/hidden.ndjson.gz \
  --timebase-numer 125 --timebase-denom 3 --expected-keys 137 \
  --key-prefix space,letter,letter,letter,letter,letter,letter,letter,space \
  --key-pattern letter,letter,letter,letter,letter,letter,letter,letter,space,delete,space,letter,letter,letter,letter,space
```

Primary runs used predictions on, autocorrect off, predictive touch areas/emoji suggestions/clipboard history off, portrait Liquid Glass. English was enabled for the English and hidden-rail runs. The extension recorded Full Access as available, including in the original preference backup; no permission change was made. App and extension preferences occupied separate simulator files. Temporary preferences and test learning were restored to the pre-expanded-run backup, and `AKSHARA_PERF_TRACE` was removed after capture.

## Remaining limits

- Serial UI automation averaged about 5 taps/s for Wijesekara and 2.2 taps/s for the other primary runs, including pauses between batches. This does not exercise fast burst input, cancellation pressure or overlapping touches.
- One 512-event run per mode, not three independent runs per mode. No baseline comparison, physical iPhone, messaging-app host, CPU flamegraph, peak-memory measurement, or input-to-display latency.
- Named CorrectionEvaluation intervals could not be paired from the unified-log export. The three primary Sinhala runs each contain 320 malformed-name pairs; the hidden-rail run contains 103. They are excluded, without inferring their identity. A clean Instruments capture or instrumentation investigation is still needed.
- Instruments recorder startup/attachment failed in the earlier attempt; no new valid CPU trace was obtained. Visual/accessibility, rotation, Classic appearance, feature-heavy emoji/clipboard/predictive-area scenarios, long words and host edge cases still require runtime checks.
- [Physical-device acceptance and TestFlight gates](../../../Typing-Performance.md#device-acceptance-and-testflight-gate--unverified) remain pending.
