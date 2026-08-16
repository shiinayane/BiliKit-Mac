#!/bin/sh

set -eu
umask 077

fail() {
    echo "Danmaku Lab trace recording failed: $1" >&2
    exit 1
}

developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[ -x "$developer_dir/usr/bin/xctrace" ] || fail "full Xcode with xctrace is required"
export DEVELOPER_DIR=$developer_dir
command -v xmllint >/dev/null || fail "xmllint is required for trace evidence extraction"

[ "$#" -eq 7 ] \
    || fail "usage: $0 ARTIFACT_ROOT PRESET_ID RENDERER_ID REPETITION ATTEMPT TEMPLATE PID"
artifact_root=$1
preset_id=$2
renderer_id=$3
repetition=$4
attempt=$5
template=$6
pid=$7

case "$artifact_root" in
    /private/tmp/*) ;;
    *) fail "artifact root must be under /private/tmp" ;;
esac
artifact_name=${artifact_root#/private/tmp/}
case "$artifact_name" in
    ""|.|..|*/*) fail "artifact root must be one task-specific directory" ;;
esac
[ -f "$artifact_root/environment.txt" ] || fail "run preparation first"
[ -f "$artifact_root/benchmark-manifest.txt" ] || fail "benchmark manifest is missing"
[ -f "$artifact_root/binary-path.txt" ] || fail "prepared binary path is missing"
[ -f "$artifact_root/binary-sha256.txt" ] || fail "prepared binary hash is missing"
[ -f "$artifact_root/thresholds.md" ] || fail "threshold preregistration is missing"
decision_mode=$(sed -n 's/^decision-mode=//p' "$artifact_root/benchmark-manifest.txt")
case "$decision_mode" in
    calibration|adjudication) ;;
    *) fail "benchmark decision mode is invalid" ;;
esac
for finalized_sample in "$artifact_root"/frozen/*-finalized-sample.txt
do
    [ -f "$finalized_sample" ] || continue
    finalized_summary=$(sed -n 's/^summary-path=//p' "$finalized_sample")
    if [ -f "$finalized_summary" ] \
        && [ "$(sed -n 's/^- decision: //p' "$finalized_summary")" = REVISE ]
    then
        fail "a finalized REVISE sample stops this artifact root"
    fi
done
if [ "$decision_mode" = adjudication ]; then
    if grep -q 'TODO' "$artifact_root/thresholds.md"; then
        fail "complete threshold preregistration before recording"
    fi
    for threshold in \
    target-display-refresh-hz \
    maximum-display-refresh-deviation-hz \
    maximum-detected-main-thread-hang-ms \
    maximum-measurement-duration-deviation-ms \
    maximum-hitch-count-in-measurement-window \
    maximum-hitch-duration-ms \
    maximum-process-cpu-percent \
    maximum-rss-mib \
    maximum-physical-footprint-mib \
    maximum-persistent-allocation-growth-mib \
    maximum-drop-fraction-steady-80 \
    maximum-drop-fraction-burst-320 \
    maximum-drop-fraction-capacity-640 \
    maximum-relative-spread-percent-across-three-repetitions
    do
        grep -Eq "^- $threshold: [0-9]+([.][0-9]+)?$" "$artifact_root/thresholds.md" \
            || fail "threshold $threshold must be a nonnegative number"
    done
    for drop_threshold in \
    maximum-drop-fraction-steady-80 \
    maximum-drop-fraction-burst-320 \
    maximum-drop-fraction-capacity-640
    do
        drop_value=$(sed -n "s/^- $drop_threshold: //p" "$artifact_root/thresholds.md")
        awk -v value="$drop_value" 'BEGIN { exit !(value >= 0 && value <= 1) }' \
            || fail "threshold $drop_threshold must be in the closed 0...1 range"
    done
fi
frozen_thresholds="$artifact_root/frozen/thresholds.md"
if [ ! -e "$frozen_thresholds" ]; then
    cp "$artifact_root/thresholds.md" "$frozen_thresholds"
    chmod 0444 "$frozen_thresholds"
fi
threshold_sha256=$(shasum -a 256 "$artifact_root/thresholds.md" | awk '{print $1}')
frozen_threshold_sha256=$(shasum -a 256 "$frozen_thresholds" | awk '{print $1}')
[ "$threshold_sha256" = "$frozen_threshold_sha256" ] \
    || fail "thresholds changed after the first recording"
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
case "$template" in
    "Time Profiler")
        template_slug=time-profiler
        cpu_result=PENDING
        main_thread_result=PENDING
        hitch_result=N/A
        allocation_result=N/A
        ;;
    "Animation Hitches")
        template_slug=animation-hitches
        cpu_result=N/A
        main_thread_result=N/A
        hitch_result=PENDING
        allocation_result=N/A
        ;;
    "Allocations")
        template_slug=allocations
        cpu_result=N/A
        main_thread_result=N/A
        hitch_result=N/A
        allocation_result=PENDING
        ;;
    *) fail "template must be Time Profiler, Animation Hitches, or Allocations" ;;
esac
case "$pid" in
    *[!0-9]*|"") fail "PID must be numeric" ;;
esac
kill -0 "$pid" 2>/dev/null || fail "target PID is not running"
process_name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
case "$process_name" in
    */DanmakuLab|DanmakuLab) ;;
    *) fail "target PID is not DanmakuLab" ;;
esac
prepared_binary=$(sed -n '1p' "$artifact_root/binary-path.txt")
prepared_directory=$(CDPATH= cd -- "$(dirname "$prepared_binary")" && pwd -P)
prepared_binary="$prepared_directory/$(basename "$prepared_binary")"
process_binary=$(ps -p "$pid" -o command= 2>/dev/null | sed 's/^ *//')
[ -n "$process_binary" ] || fail "could not resolve target executable"
[ "$process_binary" = "$prepared_binary" ] \
    || fail "target process has arguments or is not the prepared executable"
[ "$process_binary" = "$prepared_binary" ] \
    || fail "target PID is not the prepared Release binary"
prepared_sha256=$(sed -n '1p' "$artifact_root/binary-sha256.txt")
process_sha256=$(shasum -a 256 "$process_binary" | awk '{print $1}')
[ "$process_sha256" = "$prepared_sha256" ] \
    || fail "target binary hash does not match preparation"
process_started=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//')
sample_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
process_fingerprint="$pid|$process_started|$process_sha256"
sample_process="$artifact_root/frozen/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug-process.txt"
if [ -f "$sample_process" ]; then
    [ "$(sed -n '1p' "$sample_process")" = "$process_fingerprint" ] \
        || fail "a retried sample must use its originally bound process"
else
    for existing_series in "$artifact_root"/frozen/*-process.txt
    do
        [ -e "$existing_series" ] || continue
        [ "$(sed -n '1p' "$existing_series")" != "$process_fingerprint" ] \
            || fail "each performance sample requires a fresh process"
    done
    echo "$process_fingerprint" >"$sample_process"
    chmod 0444 "$sample_process"
fi

trace_path="$artifact_root/raw/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug.trace"
summary_path="$artifact_root/summaries/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug.md"
runtime_path="$artifact_root/summaries/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug-runtime.txt"
[ ! -e "$trace_path" ] || fail "trace already exists"
[ ! -e "$summary_path" ] || fail "summary already exists"
pending_sample="$artifact_root/pending-sample.txt"
[ ! -e "$pending_sample" ] \
    || fail "another sample is pending; finish or discard it first"
{
    echo "protocol-version=2"
    echo "sample-id=$sample_id"
    echo "preset=$preset_id@1"
    echo "renderer=$renderer_id"
    echo "repetition=$repetition"
    echo "binary-sha256=$process_sha256"
    echo "threshold-sha256=$frozen_threshold_sha256"
} >"$pending_sample"

warmup_seconds=$(sed -n 's/^warmup-seconds=//p' "$artifact_root/benchmark-manifest.txt")
measurement_seconds=$(sed -n 's/^measurement-seconds=//p' "$artifact_root/benchmark-manifest.txt")
trace_setup_allowance_seconds=$(sed -n \
    's/^trace-setup-allowance-seconds=//p' \
    "$artifact_root/benchmark-manifest.txt")
case "$trace_setup_allowance_seconds" in
    *[!0-9]*|"") fail "trace setup allowance must be a nonnegative integer" ;;
esac
trace_time_limit=$(awk \
    -v warmup="$warmup_seconds" \
    -v measurement="$measurement_seconds" \
    -v setup="$trace_setup_allowance_seconds" \
    'BEGIN { print int(warmup + measurement + setup) }')
{
    echo "# Danmaku Lab performance sample"
    echo
    echo "- preset: $preset_id@1"
    echo "- renderer: $renderer_id"
    echo "- repetition: $repetition / 3"
    echo "- attempt: $attempt"
    echo "- template: $template"
    echo "- process: DanmakuLab ($pid)"
    echo "- process-started: $process_started"
    echo "- executable: $process_binary"
    echo "- binary-sha256: $process_sha256"
    echo "- threshold-sha256: $frozen_threshold_sha256"
    echo "- decision-mode: $decision_mode"
    echo "- sample-id: $sample_id"
    echo "- lab-result-sha256: PENDING"
    echo "- run-attempt-id-from-signpost: PENDING"
    echo "- trace-time-limit: ${trace_time_limit}s"
    echo "- decision: PENDING"
    echo "- threshold-source: $frozen_thresholds"
    echo "- lab-disposition: PENDING"
    echo "- environment-pollution: PENDING"
    echo "- unique-complete-measurement-signpost: PENDING"
    echo "- measurement-duration-seconds: PENDING"
    echo "- logical-ticks-actual-expected: PENDING"
    echo "- generated-events-actual-expected: PENDING"
    echo "- actual-display-refresh-hz: PENDING"
    echo "- process-cpu-percent: $cpu_result"
    echo "- maximum-detected-main-thread-hang-ms: $main_thread_result"
    echo "- hitch-count-and-maximum-duration-ms: $hitch_result"
    echo "- rss-and-physical-footprint-mib: PENDING"
    echo "- persistent-allocation-growth-mib: $allocation_result"
    echo "- admitted-and-dropped-events: PENDING"
    echo "- notes: PENDING"
    echo
    echo "Only the DanmakuLab Measurement signpost interval is the quantitative window."
    echo "HUD values and visual smoothness are supporting observations, not trace evidence."
} >"$summary_path"
{
    echo "recorded-at-utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "process-started=$process_started"
    echo "power-source=$(pmset -g batt | tr '\n' ' ')"
} >"$runtime_path"

echo "Start the prepared repetition in Danmaku Lab immediately after recording begins."
recording_started_epoch=$(date +%s)
if ! xcrun xctrace record \
    --template "$template" \
    --attach "$pid" \
    --time-limit "${trace_time_limit}s" \
    --output "$trace_path"
then
    rm -rf -- "$trace_path"
    rm -f -- "$summary_path"
    rm -f -- "$sample_process"
    rm -f -- "$pending_sample"
    fail "xctrace recording failed; partial artifacts were removed"
fi
recording_finished_epoch=$(date +%s)

lab_result="$artifact_root/lab-results/$sample_id.txt"
if [ ! -f "$lab_result" ]; then
    rm -rf -- "$trace_path"
    rm -f -- "$summary_path" "$sample_process" "$pending_sample"
    fail "the Lab did not produce a matching structured result; trace was discarded"
fi
result_value() {
    sed -n "s/^$1=//p" "$lab_result"
}
[ "$(result_value sample-id)" = "$sample_id" ] \
    || fail "Lab result sample identity mismatch"
[ "$(result_value preset)" = "$preset_id@1" ] \
    || fail "Lab result preset mismatch"
[ "$(result_value renderer)" = "$renderer_id" ] \
    || fail "Lab result renderer mismatch"
[ "$(result_value repetition)" = "$repetition" ] \
    || fail "Lab result repetition mismatch"
[ "$(result_value binary-sha256)" = "$process_sha256" ] \
    || fail "Lab result binary identity mismatch"
[ "$(result_value threshold-sha256)" = "$frozen_threshold_sha256" ] \
    || fail "Lab result threshold identity mismatch"
[ ! -e "$pending_sample" ] \
    || fail "the Lab did not claim the pending sample"
result_modified_epoch=$(stat -f %m "$lab_result")
[ "$result_modified_epoch" -ge "$recording_started_epoch" ] \
    || fail "Lab result predates the recording window"
[ "$result_modified_epoch" -le "$recording_finished_epoch" ] \
    || fail "Lab result was produced after the recording window"
kill -0 "$pid" 2>/dev/null || fail "target process exited before recording completed"
[ "$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//')" = "$process_started" ] \
    || fail "target PID identity changed during recording"
lab_result_sha256=$(shasum -a 256 "$lab_result" | awk '{print $1}')
result_hash_path="$artifact_root/frozen/$sample_id-lab-result-sha256.txt"
echo "$lab_result_sha256" >"$result_hash_path"
chmod 0444 "$lab_result" "$result_hash_path"
summary_temporary="$summary_path.tmp"
sed "s/^- lab-result-sha256: PENDING$/- lab-result-sha256: $lab_result_sha256/" \
    "$summary_path" >"$summary_temporary"
mv "$summary_temporary" "$summary_path"

replace_summary_field() {
    field=$1
    value=$2
    temporary="$summary_path.tmp"
    sed "s|^- $field: PENDING$|- $field: $value|" "$summary_path" >"$temporary"
    mv "$temporary" "$summary_path"
}
signpost_export="$artifact_root/summaries/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug-signposts.xml"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
    xcrun xctrace export \
    --input "$trace_path" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost" and @category="PointsOfInterest"]' \
    --output "$signpost_export" >/dev/null
measurement_count=$(xmllint --xpath \
    'count(//row[signpost-name="DanmakuLab Measurement"])' \
    "$signpost_export")
[ "$measurement_count" = 1 ] \
    || fail "trace must contain exactly one Measurement begin signpost"
measurement_identifier=$(xmllint --xpath \
    'string(//row[signpost-name="DanmakuLab Measurement"]/os-signpost-identifier/@id)' \
    "$signpost_export")
[ -n "$measurement_identifier" ] || fail "Measurement signpost identifier is missing"
measurement_end_event_type_identifier=$(xmllint --xpath \
    'string(//event-type[text()="End"][1]/@id)' \
    "$signpost_export")
[ -n "$measurement_end_event_type_identifier" ] \
    || fail "Measurement end event type identifier is missing"
measurement_end_count=$(xmllint --xpath \
    "count(//row[os-signpost-identifier/@ref='$measurement_identifier' and (event-type='End' or event-type/@ref='$measurement_end_event_type_identifier')])" \
    "$signpost_export")
[ "$measurement_end_count" = 1 ] \
    || fail "trace must contain exactly one matching Measurement end signpost"
measurement_begin_ns=$(xmllint --xpath \
    'string(//row[signpost-name="DanmakuLab Measurement"]/event-time)' \
    "$signpost_export")
measurement_end_ns=$(xmllint --xpath \
    "string(//row[os-signpost-identifier/@ref='$measurement_identifier' and (event-type='End' or event-type/@ref='$measurement_end_event_type_identifier')]/event-time)" \
    "$signpost_export")
attempt_upper=$(echo "$(result_value attempt-id)" | tr '[:lower:]' '[:upper:]')
grep -q "$attempt_upper" "$signpost_export" \
    || fail "Measurement signpost attempt UUID does not match the Lab result"
measurement_trace_seconds=$(awk -v begin="$measurement_begin_ns" -v end="$measurement_end_ns" \
    'BEGIN { duration = (end - begin) / 1000000000; if (duration <= 0) exit 1; printf "%.9f", duration }') \
    || fail "Measurement signpost duration is invalid"

trace_cpu_percent=N/A
maximum_detected_hang_ms=N/A
if [ "$template_slug" = time-profiler ]; then
    profile_export="$artifact_root/summaries/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug-profile.xml"
    hangs_export="$artifact_root/summaries/$preset_id-$renderer_id-r$repetition-a$attempt-$template_slug-hangs.xml"
    DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
        xcrun xctrace export \
        --input "$trace_path" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
        --output "$profile_export" >/dev/null
    sample_weight_ns=$(xmllint --xpath \
        'string(//row[1]/weight)' "$profile_export")
    [ -n "$sample_weight_ns" ] || fail "Time Profiler sample weight is missing"
    profile_sample_count=$(xmllint --xpath \
        "count(//row[number(sample-time) >= $measurement_begin_ns and number(sample-time) <= $measurement_end_ns])" \
        "$profile_export")
    trace_cpu_percent=$(awk \
        -v samples="$profile_sample_count" \
        -v weight="$sample_weight_ns" \
        -v duration="$measurement_trace_seconds" \
        'BEGIN { printf "%.4f", samples * weight / 1000000000 / duration * 100 }')
    rm -f -- "$profile_export"

    DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
        xcrun xctrace export \
        --input "$trace_path" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' \
        --output "$hangs_export" >/dev/null
    maximum_detected_hang_ns=$(xmllint --xpath \
        "//row[number(start-time) >= $measurement_begin_ns and number(start-time) <= $measurement_end_ns]/duration" \
        "$hangs_export" 2>/dev/null \
        | sed 's/></>\
</g' \
        | sed -n 's/.*<duration[^>]*>\([0-9][0-9]*\)<.*/\1/p' \
        | awk 'BEGIN { maximum = 0 } { if ($1 > maximum) maximum = $1 } END { print maximum }')
    maximum_detected_hang_ms=$(awk -v duration="$maximum_detected_hang_ns" \
        'BEGIN { printf "%.3f", duration / 1000000 }')
fi

case "$(result_value disposition)" in
    polluted) recorded_lab_disposition=POLLUTED ;;
    revise) recorded_lab_disposition=REVISE ;;
    eligible) recorded_lab_disposition="ELIGIBLE FOR TRACE REVIEW" ;;
    *) fail "structured Lab disposition is invalid" ;;
esac
rss_result_mib=$(awk -v bytes="$(result_value rss-peak-bytes)" \
    'BEGIN { printf "%.1f", bytes / 1048576 }')
footprint_result_mib=$(awk -v bytes="$(result_value physical-footprint-peak-bytes)" \
    'BEGIN { printf "%.1f", bytes / 1048576 }')
replace_summary_field run-attempt-id-from-signpost "$(result_value attempt-id)"
replace_summary_field lab-disposition "$recorded_lab_disposition"
replace_summary_field unique-complete-measurement-signpost YES
replace_summary_field measurement-duration-seconds "$(result_value measurement-duration-seconds)"
replace_summary_field logical-ticks-actual-expected \
    "$(result_value logical-ticks-actual) / $(result_value logical-ticks-expected)"
replace_summary_field generated-events-actual-expected \
    "$(result_value generated-events-actual) / $(result_value generated-events-expected)"
replace_summary_field rss-and-physical-footprint-mib \
    "$rss_result_mib / $footprint_result_mib"
replace_summary_field admitted-and-dropped-events \
    "$(result_value admitted-events) / $(result_value dropped-events)"
if [ "$template_slug" = time-profiler ]; then
    replace_summary_field process-cpu-percent "$trace_cpu_percent"
    replace_summary_field maximum-detected-main-thread-hang-ms \
        "$maximum_detected_hang_ms"
fi
{
    echo "measurement-begin-ns=$measurement_begin_ns"
    echo "measurement-end-ns=$measurement_end_ns"
    echo "measurement-trace-seconds=$measurement_trace_seconds"
    echo "time-profiler-process-cpu-percent=$trace_cpu_percent"
    echo "maximum-detected-main-thread-hang-ms=$maximum_detected_hang_ms"
} >>"$runtime_path"

echo "Raw trace: $trace_path"
echo "Structured Lab result: $lab_result"
echo "Complete summary: $summary_path"
echo "Then run finalize-performance-sample.sh; raw trace deletion is the default."
