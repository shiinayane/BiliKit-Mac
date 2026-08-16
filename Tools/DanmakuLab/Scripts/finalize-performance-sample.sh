#!/bin/sh

set -eu
umask 077

fail() {
    echo "Danmaku Lab sample finalization failed: $1" >&2
    exit 1
}

[ "$#" -eq 6 ] \
    || fail "usage: $0 ARTIFACT_ROOT PRESET_ID RENDERER_ID REPETITION ATTEMPT TEMPLATE_SLUG"
artifact_root=$1
preset_id=$2
renderer_id=$3
repetition=$4
attempt=$5
template_slug=$6
[ "$(sed -n 's/^protocol-version=//p' "$artifact_root/benchmark-manifest.txt" 2>/dev/null || true)" = 3 ] \
    || fail "benchmark manifest protocol version is unsupported"
decision_mode=$(sed -n 's/^decision-mode=//p' "$artifact_root/benchmark-manifest.txt" 2>/dev/null || true)
case "$decision_mode" in
    calibration|adjudication) ;;
    *) fail "benchmark decision mode is invalid" ;;
esac

case "$artifact_root" in
    /private/tmp/*) ;;
    *) fail "artifact root must be under /private/tmp" ;;
esac
artifact_name=${artifact_root#/private/tmp/}
case "$artifact_name" in
    ""|.|..|*/*) fail "artifact root must be one task-specific directory" ;;
esac
case "$preset_id" in
    steady-80|burst-320|capacity-640) ;;
    *) fail "unknown registered preset" ;;
esac
case "$renderer_id" in
    ""|*[!A-Za-z0-9._-]*) fail "renderer ID must be a static safe identifier" ;;
esac
case "$repetition" in
    1|2|3) ;;
    *) fail "repetition must be 1, 2, or 3" ;;
esac
case "$attempt" in
    *[!0-9]*|""|0) fail "attempt must be a positive integer" ;;
esac
case "$template_slug" in
    time-profiler|animation-hitches|allocations) ;;
    *) fail "unknown template slug" ;;
esac

trace_path="$artifact_root/raw/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug.trace"
summary_path="$artifact_root/summaries/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug.md"
[ -e "$trace_path" ] || fail "raw trace is missing"
[ -f "$summary_path" ] || fail "summary is missing"
[ "$(sed -n 's/^- protocol-version: //p' "$summary_path")" = 3 ] \
    || fail "summary protocol version is unsupported"
[ "$(sed -n 's/^- preset: //p' "$summary_path")" = "$preset_id@1" ] \
    || fail "summary preset does not match"
[ "$(sed -n 's/^- renderer: //p' "$summary_path")" = "$renderer_id" ] \
    || fail "summary renderer does not match the requested series"
[ "$(sed -n 's/^- repetition: //p' "$summary_path")" = "$repetition / 3" ] \
    || fail "summary repetition does not match"
[ "$(sed -n 's/^- attempt: //p' "$summary_path")" = "$attempt" ] \
    || fail "summary attempt does not match"
case "$template_slug" in
    time-profiler) expected_template="Time Profiler" ;;
    animation-hitches) expected_template="Animation Hitches" ;;
    allocations) expected_template="Allocations" ;;
esac
[ "$(sed -n 's/^- template: //p' "$summary_path")" = "$expected_template" ] \
    || fail "summary template does not match"
sample_id=$(sed -n 's/^- sample-id: //p' "$summary_path")
case "$sample_id" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*) ;;
    *) fail "summary sample ID is invalid" ;;
esac
claimed_sample="$artifact_root/claimed-samples/$sample_id.txt"
[ -f "$claimed_sample" ] || fail "claimed pending-sample manifest is missing"
[ "$(sed -n 's/^protocol-version=//p' "$claimed_sample")" = 3 ] \
    || fail "claimed sample protocol version is unsupported"
[ "$(sed -n 's/^sample-id=//p' "$claimed_sample")" = "$sample_id" ] \
    || fail "claimed sample identity mismatch"
[ "$(sed -n 's/^preset=//p' "$claimed_sample")" = "$preset_id@1" ] \
    || fail "claimed preset identity mismatch"
[ "$(sed -n 's/^renderer=//p' "$claimed_sample")" = "$renderer_id" ] \
    || fail "claimed renderer identity mismatch"
[ "$(sed -n 's/^repetition=//p' "$claimed_sample")" = "$repetition" ] \
    || fail "claimed repetition mismatch"
[ "$(sed -n 's/^binary-sha256=//p' "$claimed_sample")" = "$(sed -n '1p' "$artifact_root/binary-sha256.txt")" ] \
    || fail "claimed binary identity mismatch"
lab_result="$artifact_root/lab-results/$sample_id.txt"
[ -f "$lab_result" ] || fail "structured Lab result is missing"
result_hash_path="$artifact_root/frozen/$sample_id-lab-result-sha256.txt"
[ -f "$result_hash_path" ] || fail "frozen Lab result hash is missing"
[ "$(shasum -a 256 "$lab_result" | awk '{print $1}')" = "$(sed -n '1p' "$result_hash_path")" ] \
    || fail "structured Lab result changed after recording"
[ "$(sed -n 's/^- lab-result-sha256: //p' "$summary_path")" = "$(sed -n '1p' "$result_hash_path")" ] \
    || fail "summary Lab result hash mismatch"
result_value() {
    sed -n "s/^$1=//p" "$lab_result"
}
threshold_value() {
    sed -n "s/^- $1: //p" "$artifact_root/frozen/thresholds.md"
}
summary_value() {
    sed -n "s/^- $1: //p" "$summary_path"
}
exceeds() {
    awk -v actual="$1" -v limit="$2" 'BEGIN { exit !(actual > limit) }'
}
[ "$(result_value protocol-version)" = 3 ] || fail "Lab result protocol version is unsupported"
[ "$(result_value sample-id)" = "$sample_id" ] || fail "Lab result sample mismatch"
[ "$(result_value preset)" = "$preset_id@1" ] || fail "Lab result preset mismatch"
[ "$(result_value renderer)" = "$renderer_id" ] || fail "Lab result renderer mismatch"
[ "$(result_value repetition)" = "$repetition" ] || fail "Lab result repetition mismatch"
[ "$(result_value binary-sha256)" = "$(sed -n '1p' "$artifact_root/binary-sha256.txt")" ] \
    || fail "Lab result binary hash mismatch"
frozen_threshold_hash=$(shasum -a 256 "$artifact_root/frozen/thresholds.md" | awk '{print $1}')
[ "$(sed -n 's/^threshold-sha256=//p' "$claimed_sample")" = "$frozen_threshold_hash" ] \
    || fail "claimed threshold identity mismatch"
[ "$(result_value threshold-sha256)" = "$frozen_threshold_hash" ] \
    || fail "Lab result threshold hash mismatch"
[ "$(sed -n 's/^- binary-sha256: //p' "$summary_path")" = "$(result_value binary-sha256)" ] \
    || fail "summary binary hash mismatch"
[ "$(sed -n 's/^- threshold-sha256: //p' "$summary_path")" = "$frozen_threshold_hash" ] \
    || fail "summary threshold hash mismatch"
process_record="$artifact_root/frozen/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug-process.txt"
[ -f "$process_record" ] || fail "frozen process identity is missing"
process_fingerprint=$(sed -n '1p' "$process_record")
process_pid=${process_fingerprint%%|*}
process_remainder=${process_fingerprint#*|}
process_hash=${process_remainder##*|}
process_started=${process_remainder%|*}
[ "$(summary_value process)" = "DanmakuLab ($process_pid)" ] \
    || fail "summary PID does not match the frozen process"
[ "$(summary_value process-started)" = "$process_started" ] \
    || fail "summary process start time does not match"
[ "$(summary_value executable)" = "$(sed -n '1p' "$artifact_root/binary-path.txt")" ] \
    || fail "summary executable path does not match preparation"
[ "$(summary_value binary-sha256)" = "$process_hash" ] \
    || fail "summary binary hash does not match the frozen process"
registered_trace_limit=$(awk \
    -v warmup="$(sed -n 's/^warmup-seconds=//p' "$artifact_root/benchmark-manifest.txt")" \
    -v measurement="$(sed -n 's/^measurement-seconds=//p' "$artifact_root/benchmark-manifest.txt")" \
    -v setup="$(sed -n 's/^trace-setup-allowance-seconds=//p' "$artifact_root/benchmark-manifest.txt")" \
    'BEGIN { print int(warmup + measurement + setup) "s" }')
[ "$(summary_value trace-time-limit)" = "$registered_trace_limit" ] \
    || fail "summary trace time limit does not match the benchmark manifest"
if grep -Eq 'TODO|PENDING' "$summary_path"; then
    fail "summary still contains incomplete fields"
fi
grep -Eq '^- decision: (POLLUTED|REVISE|CALIBRATION|ACCEPTED)$' "$summary_path" \
    || fail "decision must be POLLUTED, REVISE, CALIBRATION, or ACCEPTED"
[ "$(summary_value decision-mode)" = "$decision_mode" ] \
    || fail "summary decision mode does not match the benchmark manifest"
grep -Eq '^- lab-disposition: (POLLUTED|REVISE|ELIGIBLE FOR TRACE REVIEW)$' "$summary_path" \
    || fail "Lab disposition is missing or invalid"
grep -Eq '^- environment-pollution: (YES|NO)$' "$summary_path" \
    || fail "environment pollution must be classified"
for operator_field in \
    operator-window-visible-entire-measurement \
    operator-target-display-confirmed \
    operator-no-unrelated-foreground-load \
    operator-power-and-thermal-state-stable
do
    grep -Eq "^- $operator_field: (YES|NO)$" "$summary_path" \
        || fail "$operator_field must be explicitly confirmed"
    if [ "$(summary_value "$operator_field")" = NO ] \
        && [ "$(summary_value environment-pollution)" != YES ]
    then
        fail "a failed operator environment check must mark the sample polluted"
    fi
done
if [ "$(summary_value environment-pollution)" = NO ]; then
    for operator_field in \
        operator-window-visible-entire-measurement \
        operator-target-display-confirmed \
        operator-no-unrelated-foreground-load \
        operator-power-and-thermal-state-stable
    do
        [ "$(summary_value "$operator_field")" = YES ] \
            || fail "an unpolluted sample requires every operator environment check"
    done
fi
grep -Eq '^- measurement-duration-seconds: [0-9]+([.][0-9]+)?$' "$summary_path" \
    || fail "measurement duration must be numeric"
result_attempt=$(result_value attempt-id)
summary_attempt=$(sed -n 's/^- run-attempt-id-from-signpost: //p' "$summary_path")
if [ "$result_attempt" = none ]; then
    [ "$summary_attempt" = none ] \
        || fail "a run without Measurement must record attempt none"
    grep -Eq '^- unique-complete-measurement-signpost: NO$' "$summary_path" \
        || fail "a pre-measurement pollution must not claim a signpost"
else
    [ "$summary_attempt" = "$result_attempt" ] \
        || fail "summary attempt does not match the structured Lab result"
    grep -Eq '^- unique-complete-measurement-signpost: YES$' "$summary_path" \
        || fail "one complete matching Measurement signpost must be verified"
fi
grep -Eq '^- logical-ticks-actual-expected: [0-9]+ / [0-9]+$' "$summary_path" \
    || fail "logical tick evidence must be numeric"
grep -Eq '^- generated-events-actual-expected: [0-9]+ / [0-9]+$' "$summary_path" \
    || fail "generated event evidence must be numeric"
grep -Eq '^- actual-display-refresh-hz: [0-9]+([.][0-9]+)?$' "$summary_path" \
    || fail "display refresh must be numeric"
grep -Eq '^- rss-and-physical-footprint-mib: [0-9]+([.][0-9]+)? / [0-9]+([.][0-9]+)?$' "$summary_path" \
    || fail "RSS and footprint evidence must be numeric"
grep -Eq '^- admitted-and-dropped-events: [0-9]+ / [0-9]+$' "$summary_path" \
    || fail "admitted and dropped evidence must be numeric"
grep -Eq '^- peak-active-presentations: [0-9]+$' "$summary_path" \
    || fail "peak active presentation evidence must be numeric"
case "$template_slug" in
    time-profiler)
        grep -Eq '^- process-cpu-percent: [0-9]+([.][0-9]+)?$' "$summary_path" \
            || fail "Time Profiler CPU result must be numeric"
        grep -Eq '^- main-thread-cpu-percent: [0-9]+([.][0-9]+)?$' "$summary_path" \
            || fail "Time Profiler main-thread CPU result must be numeric"
        awk -v main="$(summary_value main-thread-cpu-percent)" \
            -v process="$(summary_value process-cpu-percent)" \
            'BEGIN { exit !(main <= process) }' \
            || fail "main-thread CPU cannot exceed process CPU"
        grep -Eq '^- maximum-detected-main-thread-hang-ms: [0-9]+([.][0-9]+)?$' "$summary_path" \
            || fail "Time Profiler detected-hang result must be numeric"
        ;;
    animation-hitches)
        grep -Eq '^- hitch-count-and-maximum-duration-ms: [0-9]+ / [0-9]+([.][0-9]+)?$' "$summary_path" \
            || fail "Animation Hitches result must be numeric"
        ;;
    allocations)
        grep -Eq '^- persistent-allocation-growth-mib: [0-9]+([.][0-9]+)?$' "$summary_path" \
            || fail "Allocations growth must be numeric"
        ;;
esac
decision=$(sed -n 's/^- decision: //p' "$summary_path")
lab_disposition=$(sed -n 's/^- lab-disposition: //p' "$summary_path")
case "$(result_value disposition)" in
    polluted) expected_lab_disposition=POLLUTED ;;
    revise) expected_lab_disposition=REVISE ;;
    eligible) expected_lab_disposition="ELIGIBLE FOR TRACE REVIEW" ;;
    *) fail "structured Lab disposition is invalid" ;;
esac
[ "$lab_disposition" = "$expected_lab_disposition" ] \
    || fail "summary Lab disposition does not match the structured result"

ticks_actual=$(result_value logical-ticks-actual)
ticks_expected=$(result_value logical-ticks-expected)
generated_actual=$(result_value generated-events-actual)
generated_expected=$(result_value generated-events-expected)
[ "$(summary_value logical-ticks-actual-expected)" = "$ticks_actual / $ticks_expected" ] \
    || fail "summary logical ticks do not match the structured result"
[ "$(summary_value generated-events-actual-expected)" = "$generated_actual / $generated_expected" ] \
    || fail "summary generated events do not match the structured result"
[ "$(summary_value measurement-duration-seconds)" = "$(result_value measurement-duration-seconds)" ] \
    || fail "summary measurement duration does not match the structured result"
if [ "$lab_disposition" = "ELIGIBLE FOR TRACE REVIEW" ]; then
    [ "$ticks_actual" = "$ticks_expected" ] \
        || fail "eligible Lab result did not complete the expected ticks"
    [ "$generated_actual" = "$generated_expected" ] \
        || fail "eligible Lab result did not generate the expected events"
    [ "$(result_value manifest-matched)" = yes ] \
        || fail "eligible Lab result did not match the workload manifest"
    [ "$(result_value surface-changed)" = no ] \
        || fail "eligible Lab result changed surface during measurement"
fi

admitted_result=$(result_value admitted-events)
dropped_result=$(result_value dropped-events)
[ "$(summary_value admitted-and-dropped-events)" = "$admitted_result / $dropped_result" ] \
    || fail "summary admission totals do not match the structured result"
[ "$(summary_value peak-active-presentations)" = "$(result_value peak-active)" ] \
    || fail "summary peak active presentations do not match the structured result"
rss_result_mib=$(awk -v bytes="$(result_value rss-peak-bytes)" 'BEGIN { printf "%.1f", bytes / 1048576 }')
footprint_result_mib=$(awk -v bytes="$(result_value physical-footprint-peak-bytes)" 'BEGIN { printf "%.1f", bytes / 1048576 }')
[ "$(summary_value rss-and-physical-footprint-mib)" = "$rss_result_mib / $footprint_result_mib" ] \
    || fail "summary memory totals do not match the structured result"

metrics_failed=0
refresh=$(summary_value actual-display-refresh-hz)
environment_pollution=$(summary_value environment-pollution)
rss_pair=$(summary_value rss-and-physical-footprint-mib)
rss=$(echo "$rss_pair" | awk '{print $1}')
footprint=$(echo "$rss_pair" | awk '{print $3}')
admission_pair=$(summary_value admitted-and-dropped-events)
admitted=$(echo "$admission_pair" | awk '{print $1}')
dropped=$(echo "$admission_pair" | awk '{print $3}')
drop_fraction=$(awk -v admitted="$admitted" -v dropped="$dropped" \
    'BEGIN {
        total = admitted + dropped
        if (total == 0) print 0
        else print dropped / total
    }')
if [ "$decision_mode" = adjudication ]; then
    if awk -v actual="$refresh" -v target="$(threshold_value target-display-refresh-hz)" \
        -v limit="$(threshold_value maximum-display-refresh-deviation-hz)" \
        'BEGIN { difference = actual - target; if (difference < 0) difference = -difference; exit !(difference > limit) }'
    then
        [ "$environment_pollution" = YES ] \
            || fail "display refresh outside the registered range must mark the sample polluted"
    fi
    measurement_duration=$(summary_value measurement-duration-seconds)
    registered_measurement_seconds=$(sed -n 's/^measurement-seconds=//p' \
        "$artifact_root/benchmark-manifest.txt")
    measurement_deviation_ms=$(awk -v actual="$measurement_duration" \
        -v expected="$registered_measurement_seconds" \
        'BEGIN { difference = actual - expected; if (difference < 0) difference = -difference; print difference * 1000 }')
    exceeds "$measurement_deviation_ms" \
        "$(threshold_value maximum-measurement-duration-deviation-ms)" && metrics_failed=1
    exceeds "$rss" "$(threshold_value maximum-rss-mib)" && metrics_failed=1
    exceeds "$footprint" "$(threshold_value maximum-physical-footprint-mib)" && metrics_failed=1
    exceeds "$(summary_value peak-active-presentations)" \
        "$(threshold_value maximum-peak-active-presentations)" && metrics_failed=1
    exceeds "$drop_fraction" "$(threshold_value maximum-drop-fraction-$preset_id)" \
        && metrics_failed=1
    case "$template_slug" in
    time-profiler)
        exceeds "$(summary_value process-cpu-percent)" \
            "$(threshold_value maximum-process-cpu-percent)" && metrics_failed=1
        exceeds "$(summary_value main-thread-cpu-percent)" \
            "$(threshold_value maximum-main-thread-cpu-percent)" && metrics_failed=1
        exceeds "$(summary_value maximum-detected-main-thread-hang-ms)" \
            "$(threshold_value maximum-detected-main-thread-hang-ms)" && metrics_failed=1
        ;;
    animation-hitches)
        hitch_pair=$(summary_value hitch-count-and-maximum-duration-ms)
        hitch_count=$(echo "$hitch_pair" | awk '{print $1}')
        hitch_duration=$(echo "$hitch_pair" | awk '{print $3}')
        exceeds "$hitch_count" \
            "$(threshold_value maximum-hitch-count-in-measurement-window)" \
            && metrics_failed=1
        exceeds "$hitch_duration" "$(threshold_value maximum-hitch-duration-ms)" \
            && metrics_failed=1
        ;;
    allocations)
        exceeds "$(summary_value persistent-allocation-growth-mib)" \
            "$(threshold_value maximum-persistent-allocation-growth-mib)" \
            && metrics_failed=1
        ;;
    esac
fi

case "$lab_disposition" in
    POLLUTED) expected_decision=POLLUTED ;;
    REVISE) expected_decision=REVISE ;;
    "ELIGIBLE FOR TRACE REVIEW")
        if [ "$environment_pollution" = YES ]; then
            expected_decision=POLLUTED
        elif [ "$decision_mode" = calibration ]; then
            expected_decision=CALIBRATION
        elif [ "$metrics_failed" -eq 0 ]; then
            expected_decision=ACCEPTED
        else
            expected_decision=REVISE
        fi
        ;;
esac
[ "$decision" = "$expected_decision" ] \
    || fail "decision does not match the frozen thresholds and structured metrics"

trace_tree_sha256=$(find -s "$trace_path" -type f -exec shasum -a 256 {} \; \
    | shasum -a 256 \
    | awk '{print $1}')
existing_trace_hash=$(sed -n 's/^- raw-trace-tree-sha256: //p' "$summary_path")
if [ -z "$existing_trace_hash" ]; then
    echo "- raw-trace-tree-sha256: $trace_tree_sha256" >>"$summary_path"
else
    [ "$existing_trace_hash" = "$trace_tree_sha256" ] \
        || fail "existing raw trace hash does not match the trace"
fi
summary_sha256=$(shasum -a 256 "$summary_path" | awk '{print $1}')
finalized_sample="$artifact_root/frozen/$sample_id-finalized-sample.txt"
[ ! -e "$finalized_sample" ] || fail "sample finalization manifest already exists"

rm -rf -- "$trace_path"
[ ! -e "$trace_path" ] || fail "raw trace deletion did not complete"
{
    echo "protocol-version=3"
    echo "sample-id=$sample_id"
    echo "summary-path=$summary_path"
    echo "summary-sha256=$summary_sha256"
    echo "lab-result-sha256=$(sed -n '1p' "$result_hash_path")"
    echo "raw-trace-tree-sha256=$trace_tree_sha256"
} >"$finalized_sample"
chmod 0444 "$summary_path" "$finalized_sample"
echo "Deleted raw trace after completed summary:"
echo "$trace_path"
echo "Retained summary:"
echo "$summary_path"
