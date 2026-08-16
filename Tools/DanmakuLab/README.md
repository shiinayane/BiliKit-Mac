# Danmaku Lab

Danmaku Lab is a standalone, synthetic-data macOS developer tool. It directly hosts BiliKit's
production `CoreAnimationDanmakuRenderer` through `DanmakuPresentationController`; it is not a
BiliKit App route, test runner, or second renderer implementation.

## Run

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run --package-path Tools/DanmakuLab \
  --scratch-path /private/tmp/danmaku-lab-task-id/swiftpm DanmakuLab
```

Run the deterministic contract tests with a task-local scratch directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path Tools/DanmakuLab \
  --scratch-path /private/tmp/danmaku-lab-task-id/swiftpm
```

The first spike uses only bounded synthetic events. It has no Bilibili network access, Keychain,
Cookie/token handling, AVPlayer dependency, persistence, real comments, remote URLs, or content
identifiers. `swift run` is an unsigned developer process and provides no signing or distribution
evidence.

Each run freezes a source-owned scenario ID/version, seed, effective rate, burst bound, filters,
duration, and fixed logical tick rate in a `LabRunManifest`. Wall-clock callbacks only reveal which
fixed logical ticks are due; callback grouping cannot change event IDs, timestamps, or batch
boundaries. A callback backlog beyond the manifest hard bound marks the run `POLLUTED` and stops it
instead of skipping input or tuning toward a desired result.

Renderer style is also frozen per run. Font scale, semantic font weight, and adaptive-shadow blur use
the same bounded `CoreAnimationDanmakuStyle` consumed by the production renderer. The App always uses
`.production`; changing style in the Lab tears down the old run and replays the same synthetic input.
Canvas shape and background remain observation context and are never passed to the renderer.

The production Core Animation renderer is the registry baseline. A candidate renderer must be
compiled into the Lab and registered with a distinct static descriptor; the BiliKit App does not
import this registry. When no real candidate is registered, the Lab does not show a renderer
selector. Selecting a registered candidate tears down the old run and creates a fresh backend,
controller, surface layer, statistics owner, and telemetry baseline with the same manifest input.
The selector is for sequential manual visual comparison only. Quantitative comparisons must launch
one renderer per process with fixed input and telemetry disabled.

## Performance protocol

Performance presets are source-owned and versioned. The initial catalog fixes scenario, seed, rate,
burst bound, an 854 × 480 point canvas, 2× backing scale, production-matched 30 Hz presentation
cadence, 5 seconds of warmup, 30 seconds of measurement, and three repetitions. Renderer identity is a
separate dimension; the production Core Animation renderer remains the baseline, while a statically
registered Lab-only candidate can use the identical workload. `Prepare` applies the selected workload and renderer, disables display-link telemetry, freezes
the statistics HUD, locks ordinary controls, and creates a paused run. Start an Instruments attachment
before clicking `Run repetition`. Warmup and measurement use the same backend. At the boundary the
Lab clears presentation state, resets the controller/statistics/logical input while retaining that
warmed backend, waits for a ready surface, then begins the Measurement signpost.

Measurement ends only after the exact logical tick and generated-event targets have completed; a wall
timer is not allowed to make a slow run do less work. Any detach, resize, or backing-scale change after
the signpost begins irreversibly pollutes that attempt, even if the final surface later returns to the
expected geometry. Each signpost contains a unique attempt UUID, preset identity, expected ticks, and
expected generated count. Formal intervals use the system Points of Interest category so the stock
Time Profiler template records the same quantitative window without a custom Instruments template.

The UI classifies samples before trace interpretation:

- `POLLUTED`: telemetry, renderer, canvas, backing scale, continuous surface lifecycle, exact logical
  ticks/events, or logical-run inputs did not match the preset. The repetition does not count and must
  be repeated unchanged.
- `REVISE`: generator overflow, a formal-run logical backlog, event-accounting mismatch,
  presentation-accounting mismatch, or the hard active-layer cap failed. These are workload results,
  not environmental excuses. Stop; do not tune the workload toward a passing result.
- `ELIGIBLE FOR TRACE REVIEW`: deterministic and lifecycle contracts held. This is not a performance
  pass; the Instruments interval still needs comparison with preregistered budgets.

Formal traces require a clean worktree and a task-specific root under `/private/tmp`. Preparation
builds an unsigned SwiftPM Release executable and records its canonical path and SHA-256 together with
the package lock, toolchain, machine, and a read-only hashed protocol manifest; Debug runs remain functional evidence only. Developer
ID signing is not required by the Lab contract. If the local Instruments attachment policy requires
different signing or entitlements, that is a separate explicitly authorized runtime step and must be
recorded with the sample.

```sh
Tools/DanmakuLab/Scripts/prepare-performance-run.sh \
  /private/tmp/danmaku-lab-performance-task-id adjudication
```

Use `calibration` instead of `adjudication` for the first controlled pilot when no approved budgets
exist. Calibration still requires complete trace metrics and all deterministic/lifecycle contracts,
but an eligible sample is labeled `CALIBRATION`, never `ACCEPTED`; its observations may inform a
separately approved future threshold set and cannot be retroactively adjudicated. In adjudication
mode, fill every numeric field in the generated `thresholds.md`. The first recording
freezes a read-only copy and hash; later edits make the artifact root invalid. Any valid sample outside
an approved threshold remains `REVISE`. Drop-fraction thresholds use the closed `0...1` range, not
percent. The target refresh and its allowed deviation must be preregistered for the chosen display so
59.94/60 Hz or variable-refresh behavior is handled explicitly rather than by a hard-coded equality.
Launch the exact printed command, including its
`DANMAKU_LAB_PERFORMANCE_ROOT` environment, select the matching preset, renderer, and repetition,
click `Prepare`, and obtain its PID. Recording resolves the PID executable and refuses anything that
does not match the prepared Release path and SHA-256. In a second terminal, start one template for one
repetition:

```sh
Tools/DanmakuLab/Scripts/record-performance-trace.sh \
  /private/tmp/danmaku-lab-performance-task-id \
  steady-80 production-core-animation 1 1 "Time Profiler" PID
```

The trace envelope reserves 60 seconds for the human handoff before the fixed warmup and measurement.
Only the unique Measurement signpost interval is quantitative; the extra setup capture is excluded
from metric extraction and prevents UI round-trip latency from truncating an otherwise valid run.

Use Time Profiler for process CPU, retained main-thread CPU, temporary call-tree review before
finalization, and detected main-thread hangs (the stock template reports hangs at 250 ms or longer),
Animation Hitches for shorter frame-lifetime and hitch
evidence, and Allocations for allocation lifetime and memory trends. Workload preset and
renderer identity are separate sample dimensions. Each repetition uses a fresh process, and each
preset/renderer/template tuple forms one three-repetition series; metrics from different traces are
never called the same sample. Renderer admission/drop accounting and peak active presentations come
from the frozen Lab run. For the production Core Animation baseline, one active presentation owns one
`CATextLayer`; candidate renderers must not claim that mapping. RSS and Physical Footprint are sampled
at 1 Hz with the low-frequency `task_vm_info` sampler while
the HUD remains frozen; record those as in-process supporting metrics, not as Allocations evidence.
HUD cadence and visual smoothness are not trace evidence. Run only one renderer in the process;
side-by-side visual comparison is never a quantitative sample.

The recorder machine-validates exactly one complete `DanmakuLab Measurement` Points of Interest
interval whose attempt UUID matches the Lab result. For Time Profiler it also exports the samples in
that interval, computes process and main-thread CPU from sample weights, and records the maximum
detected hang; zero means no hang met the template's 250 ms reporting floor, not that every
main-thread interval was zero.
Complete only the remaining human-review fields in the generated Markdown summary. The summary
already binds the sample to binary, protocol-manifest, and frozen-threshold hashes. After Measurement, the operator must
explicitly answer every generated checklist field: full-window visibility, target-display identity,
absence of unrelated foreground load, and stable power/thermal state. An unconfirmed or failed item
cannot be represented as an unpolluted sample. Window occlusion, loss of visibility, display
movement, power-source/thermal-state changes, and material unrelated foreground load are environment
pollution and must be marked `YES`;
an adjudication sample whose measured refresh rate falls outside the preregistered range must also be
marked `YES` rather than retaining contradictory unpolluted evidence.
The automatically recorded machine/display/power files are provenance, not proof that none occurred.
The Lab atomically claims the recorder's pending sample and writes a machine-readable
result containing preset, renderer, repetition, attempt UUID, exact ticks/events, disposition,
admission totals, measurement duration, and low-frequency memory samples. Finalization cross-checks
the hand-reviewed trace fields against the frozen result hash and refuses incomplete or inconsistent
Lab/trace decisions. The recorder deletes its temporary xctrace XML exports after extracting the
machine-readable metrics. Finalization records a raw-trace tree hash and deletes the corresponding raw
trace by default while retaining the summary and environment record. It then freezes a sample-finalization manifest and
summary hash; downstream aggregation carries the same manifest identity and rejects a missing marker
or any post-finalization edit:

```sh
Tools/DanmakuLab/Scripts/finalize-performance-sample.sh \
  /private/tmp/danmaku-lab-performance-task-id \
  steady-80 production-core-animation 1 1 time-profiler
```

The numeric attempt argument starts at `1`. If a sample is `POLLUTED`, retain and finalize that
summary, relaunch a fresh process, and repeat the same repetition with attempt `2`, then `3`, and so
on. Polluted attempts never occupy one of the three valid repetitions.

An adjudication run repeats every template and preset exactly as preregistered. All three valid
repetitions must satisfy the budgets, and each metric's relative spread must remain within its own
preregistered limit; there is no shared catch-all spread budget and no silent outlier deletion. A
calibration pilot may preregister only one tuple, but it
still uses three fresh-process repetitions and reports median, worst, and spread without turning them
into a pass. After finalizing the three samples, run
`finalize-performance-series.sh ARTIFACT_ROOT PRESET_ID RENDERER_ID TEMPLATE_SLUG`; it verifies shared
binary and threshold identities, binds all three finalized sample hashes, freezes its own hash, and
produces the aggregate series decision. A finalized `REVISE` sample stops further recording in that
artifact root. A polluted trace is
discarded and repeated; a threshold or contract failure remains
`REVISE`. After all nine preset/template series exist, run
`finalize-performance-matrix.sh ARTIFACT_ROOT RENDERER_ID`; it refuses an incomplete matrix and binds
the overall decision to one binary and threshold hash plus nine frozen series hashes. Do not change rates, canvas, duration,
renderer, or budgets after seeing a result. This is a human-reviewed, fixed-machine,
fixed-environment regression benchmark for the presentation controller plus renderer, not an
autonomous metric extractor, cross-machine score, or full-App playback benchmark. Close Instruments and remove the remaining
task-local build/cache root after retained summaries have been reviewed and copied to their reviewed
destination.

Performance artifact protocol 4 binds the read-only benchmark manifest throughout the sample,
series, and matrix hash chain. It retains protocol 3's explicit operator checklist, main-thread CPU,
peak-active evidence, and metric-specific spread budgets. Protocol 2 and 3 calibration summaries
remain historical evidence only and cannot be mixed into a protocol 4 adjudication root.
