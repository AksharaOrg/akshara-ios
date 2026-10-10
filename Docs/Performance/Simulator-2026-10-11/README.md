# Simulator typing performance — 2026-10-11

A Release build of `243ada7` ran on the iPhone 17 Pro simulator, iOS 26.5, on the development Mac. The containing app's Setup text field hosted the actual Akshara extension. The initial 48-event Wijesekara sample is preserved below. The resumed [expanded study](Expanded/README.md) covers 512 events in each of the four modes and a separate hidden-rail correction exercise. Neither study establishes physical-device acceptance or a before/after improvement.

## Measurements

Durations below come from paired `OSSignposter` begin/end events exported from the simulator's unified log. Mach timestamps use the host's 125/3 timebase to convert ticks to milliseconds. All 48 KeyHandling intervals and three queued DeleteHandling intervals were paired. Percentiles use the nearest-rank method.

| Interval | Samples | Median ms | p95 ms | Max ms |
|---|---:|---:|---:|---:|
| KeyHandling | 48 | 0.6413 | 2.8582 | 10.0369 |
| KeyHandling excluding nested host calls | 48 | 0.6123 | 2.8355 | 7.1748 |
| DeleteHandling | 3 | 0.3293 | 0.6918 | 0.6918 |
| RailRendering | 30 | 0.1013 | 0.2086 | 0.2692 |
| CandidateLabel | 113 | 0.0397 | 0.1319 | 1.0510 |
| SinhalaRanking (background) | 30 | 0.2338 | 10.1660 | 12.4605 |
| WorkerQueueDelay | 30 | 0.0276 | 0.0545 | 0.0597 |
| HostReadBefore | 60 | 0.0057 | 0.0222 | 1.0142 |
| HostReadSelection | 18 | 0.0024 | 0.3095 | 0.3095 |
| HostInsert | 45 | 0.0235 | 0.0876 | 1.8409 |
| HostDelete | 5 | 0.0388 | 0.1884 | 0.1884 |
| SinhalaModelPreparation (background) | 1 | 463.0299 | — | 463.0299 |
| CorrectionPreparation (background) | 1 | 235.5134 | — | 235.5134 |

The key intervals contained 57 before-context reads, 15 selection reads, 45 inserts and two deletes. Queued DeleteHandling and startup/callback work account for additional host calls outside those key intervals. Host-subtracted timing removes the union of enclosed same-thread proxy intervals, avoiding double subtraction if callbacks nest.

The observed key-handler and rail work are small in this scenario. Background ranking has a considerably larger tail; startup preparation also remains expensive on the simulator. These results do not establish perceptual/input-to-present latency, a 30% improvement, or the complete 8 ms main-thread budget. Touch feedback, layout/display work outside the marked handlers, and host rendering are not included in KeyHandling.

## Scope and limitations

- Initial sample: Wijesekara only; predictions enabled, autocorrect disabled, predictive touch areas/emoji suggestions/clipboard history disabled, portrait Liquid Glass appearance. The extension recorded Full Access as available in the simulator; the original report incorrectly described it as off. The containing app and extension used separate simulator preference files.
- 48 key events, including three Delete touch handlers; three actual deletes were handled on later main-loop turns. No rapid overlapping-touch validation.
- No pre-optimization baseline, three-run comparison, 500-event sample per mode, messaging-app host, CPU flamegraph or peak-memory measurement.
- Direct Instruments attachment could not locate the extension process. An all-process Time Profiler/Points of Interest capture stalled during recorder startup and was stopped. No CPU conclusions are drawn from that trace.
- Thirty other begin/end pairs had malformed names (`mode=%{public}ld` / empty) in the unified-log export and are excluded from named interval statistics. Correction-evaluation timing needs a clean Instruments capture or investigation of the signpost export before attribution.
- The Mac locked when starting the expanded run. After manual unlock, testing resumed; see the expanded results linked above.
- Physical-device acceptance and TestFlight distribution remain pending.

The archived statistics can be reproduced with:

```sh
python3 Scripts/analyze_keyboard_signposts.py \
  Docs/Performance/Simulator-2026-10-11/signposts.ndjson.gz \
  --timebase-numer 125 --timebase-denom 3 --output /tmp/intervals.json
```

## Artifacts

- [Paired intervals](intervals.json): timestamps, durations, thread/process IDs and numeric metadata only.
- [Raw compressed signposts](signposts.ndjson.gz): filtered to Akshara's Performance category, without typed text or touch coordinates.
- The rejected/stalled Instruments recording at `/tmp/akshara-simulator-all.trace` is not a valid profile and should not be used as evidence.

To reproduce, build/install the Release app, enable Akshara, focus the Setup text field, show the software keyboard, and switch to Akshara. Set `AKSHARA_PERF_TRACE=1` in the extension environment before its launch. Capture the Performance category while driving actual taps, then export with `simctl spawn booted log show --signpost --info --debug --style ndjson` and a subsystem/category predicate. Remove the tracing environment after testing. See [the full acceptance procedure](../../Typing-Performance.md).
