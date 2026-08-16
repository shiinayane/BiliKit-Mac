#!/bin/sh

set -eu
umask 077

fail() {
    echo "Danmaku Lab series finalization failed: $1" >&2
    exit 1
}

[ "$#" -eq 4 ] \
    || fail "usage: $0 ARTIFACT_ROOT PRESET_ID RENDERER_ID TEMPLATE_SLUG"
artifact_root=$1
preset_id=$2
renderer_id=$3
template_slug=$4

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
case "$template_slug" in
    time-profiler) expected_template="Time Profiler" ;;
    animation-hitches) expected_template="Animation Hitches" ;;
    allocations) expected_template="Allocations" ;;
    *) fail "unknown template slug" ;;
esac

thresholds="$artifact_root/frozen/thresholds.md"
[ -f "$thresholds" ] || fail "frozen thresholds are missing"
[ "$(sed -n 's/^protocol-version=//p' "$artifact_root/benchmark-manifest.txt" 2>/dev/null || true)" = 4 ] \
    || fail "benchmark manifest protocol version is unsupported"
benchmark_manifest_hash=$(shasum -a 256 "$artifact_root/benchmark-manifest.txt" | awk '{print $1}')
[ "$benchmark_manifest_hash" = "$(sed -n '1p' "$artifact_root/benchmark-manifest-sha256.txt" 2>/dev/null || true)" ] \
    || fail "benchmark manifest changed after preparation"
decision_mode=$(sed -n 's/^decision-mode=//p' "$artifact_root/benchmark-manifest.txt")
threshold_value() {
    sed -n "s/^- $1: //p" "$thresholds"
}
registered_spread_limit() {
    value=$(threshold_value "$1")
    case "$value" in
        ""|*[!0-9.]*) fail "spread threshold $1 is invalid" ;;
    esac
    echo "$value"
}
case "$decision_mode" in
    calibration)
        sample_decision=CALIBRATION
        rss_spread_limit=N/A
        footprint_spread_limit=N/A
        duration_spread_limit=N/A
        drop_spread_limit=N/A
        peak_active_spread_limit=N/A
        process_cpu_spread_limit=N/A
        main_thread_cpu_spread_limit=N/A
        detected_hang_spread_limit=N/A
        hitch_count_spread_limit=N/A
        hitch_duration_spread_limit=N/A
        allocation_growth_spread_limit=N/A
        ;;
    adjudication)
        sample_decision=ACCEPTED
        rss_spread_limit=$(registered_spread_limit maximum-rss-relative-spread-percent)
        footprint_spread_limit=$(registered_spread_limit maximum-physical-footprint-relative-spread-percent)
        duration_spread_limit=$(registered_spread_limit maximum-measurement-duration-relative-spread-percent)
        drop_spread_limit=$(registered_spread_limit maximum-drop-fraction-relative-spread-percent)
        peak_active_spread_limit=$(registered_spread_limit maximum-peak-active-relative-spread-percent)
        process_cpu_spread_limit=$(registered_spread_limit maximum-process-cpu-relative-spread-percent)
        main_thread_cpu_spread_limit=$(registered_spread_limit maximum-main-thread-cpu-relative-spread-percent)
        detected_hang_spread_limit=$(registered_spread_limit maximum-detected-main-thread-hang-relative-spread-percent)
        hitch_count_spread_limit=$(registered_spread_limit maximum-hitch-count-relative-spread-percent)
        hitch_duration_spread_limit=$(registered_spread_limit maximum-hitch-duration-relative-spread-percent)
        allocation_growth_spread_limit=$(registered_spread_limit maximum-allocation-growth-relative-spread-percent)
        ;;
    *) fail "benchmark decision mode is invalid" ;;
esac

summary_path() {
    found=
    for candidate in \
        "$artifact_root"/summaries/"$preset_id-$renderer_id-r$1"-a*-"$template_slug.md"
    do
        [ -f "$candidate" ] || continue
        [ "$(sed -n 's/^- decision: //p' "$candidate")" = "$sample_decision" ] \
            || continue
        [ -z "$found" ] || fail "repetition $1 has multiple accepted attempts"
        found=$candidate
    done
    [ -n "$found" ] || fail "repetition $1 has no accepted finalized attempt"
    echo "$found"
}
summary_value() {
    sed -n "s/^- $2: //p" "$(summary_path "$1")"
}
spread_percent() {
    awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN {
        minimum = a; if (b < minimum) minimum = b; if (c < minimum) minimum = c
        maximum = a; if (b > maximum) maximum = b; if (c > maximum) maximum = c
        median = a + b + c - minimum - maximum
        if (median == 0) {
            if (maximum == minimum) printf "%.4f", 0
            else printf "%.4f", 999999
        } else {
            printf "%.4f", (maximum - minimum) / median * 100
        }
    }'
}
median_value() {
    awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN {
        minimum = a; if (b < minimum) minimum = b; if (c < minimum) minimum = c
        maximum = a; if (b > maximum) maximum = b; if (c > maximum) maximum = c
        printf "%.4f", a + b + c - minimum - maximum
    }'
}
maximum_value() {
    awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN {
        maximum = a; if (b > maximum) maximum = b; if (c > maximum) maximum = c
        printf "%.4f", maximum
    }'
}
exceeds() {
    awk -v actual="$1" -v limit="$2" 'BEGIN { exit !(actual > limit) }'
}
validate_finalized_sample() {
    candidate=$1
    sample_id=$(sed -n 's/^- sample-id: //p' "$candidate")
    case "$sample_id" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*) ;;
        *) fail "sample ID is invalid in $candidate" ;;
    esac
    finalized="$artifact_root/frozen/$sample_id-finalized-sample.txt"
    [ -f "$finalized" ] || fail "sample $sample_id has no finalization manifest"
    [ "$(sed -n 's/^protocol-version=//p' "$finalized")" = 4 ] \
        || fail "sample $sample_id finalization protocol version is unsupported"
    [ "$(sed -n 's/^summary-path=//p' "$finalized")" = "$candidate" ] \
        || fail "sample finalization path mismatch"
    [ "$(sed -n 's/^summary-sha256=//p' "$finalized")" = \
        "$(shasum -a 256 "$candidate" | awk '{print $1}')" ] \
        || fail "sample summary changed after finalization"
    grep -Eq '^raw-trace-tree-sha256=[0-9a-f]{64}$' "$finalized" \
        || fail "sample raw trace hash is missing"
    [ "$(sed -n 's/^raw-trace-tree-sha256=//p' "$finalized")" = \
        "$(sed -n 's/^- raw-trace-tree-sha256: //p' "$candidate")" ] \
        || fail "sample raw trace hash does not match its summary"
    [ "$(sed -n 's/^lab-result-sha256=//p' "$finalized")" = \
        "$(sed -n 's/^- lab-result-sha256: //p' "$candidate")" ] \
        || fail "sample Lab result hash does not match its summary"
    [ "$(sed -n 's/^benchmark-manifest-sha256=//p' "$finalized")" = \
        "$(sed -n 's/^- benchmark-manifest-sha256: //p' "$candidate")" ] \
        || fail "sample benchmark manifest hash does not match its summary"
    [ "$(sed -n 's/^- benchmark-manifest-sha256: //p' "$candidate")" = \
        "$benchmark_manifest_hash" ] \
        || fail "sample benchmark manifest does not match the prepared root"
    trace_name=$(basename "$candidate" .md).trace
    [ ! -e "$artifact_root/raw/$trace_name" ] \
        || fail "sample raw trace still exists after claimed finalization"
}
validate_summary_identity() {
    candidate=$1
    [ "$(sed -n 's/^- protocol-version: //p' "$candidate")" = 4 ] \
        || fail "sample protocol version changed"
    [ "$(sed -n 's/^- preset: //p' "$candidate")" = "$preset_id@1" ] \
        || fail "sample preset identity changed"
    [ "$(sed -n 's/^- renderer: //p' "$candidate")" = "$renderer_id" ] \
        || fail "sample renderer identity changed"
    [ "$(sed -n 's/^- template: //p' "$candidate")" = "$expected_template" ] \
        || fail "sample template identity changed"
}

series_summary="$artifact_root/summaries/$preset_id-$renderer_id-$template_slug-series.md"
[ ! -e "$series_summary" ] || fail "series summary already exists"
for candidate in \
    "$artifact_root"/summaries/"$preset_id-$renderer_id"-r*-a*-"$template_slug.md"
do
    [ -f "$candidate" ] || continue
    if [ "$(sed -n 's/^- decision: //p' "$candidate")" = REVISE ]; then
        validate_finalized_sample "$candidate"
        validate_summary_identity "$candidate"
        stopped_binary_hash=$(sed -n 's/^- binary-sha256: //p' "$candidate")
        stopped_threshold_hash=$(sed -n 's/^- threshold-sha256: //p' "$candidate")
        [ "$stopped_binary_hash" = "$(sed -n '1p' "$artifact_root/binary-sha256.txt")" ] \
            || fail "REVISE sample binary does not match preparation"
        [ "$stopped_threshold_hash" = "$(shasum -a 256 "$thresholds" | awk '{print $1}')" ] \
            || fail "REVISE sample thresholds do not match the frozen root"
        {
            echo "# Danmaku Lab performance series"
            echo
            echo "- protocol-version: 4"
            echo "- preset: $preset_id@1"
            echo "- renderer: $renderer_id"
            echo "- template: $template_slug"
            echo "- binary-sha256: $stopped_binary_hash"
            echo "- benchmark-manifest-sha256: $benchmark_manifest_hash"
            echo "- threshold-sha256: $stopped_threshold_hash"
            echo "- decision-mode: $decision_mode"
            echo "- stopped-by-sample: $candidate"
            echo "- stopped-sample-summary-sha256: $(shasum -a 256 "$candidate" | awk '{print $1}')"
            echo "- decision: REVISE"
        } >"$series_summary"
        series_hash_path="$artifact_root/frozen/$preset_id-$renderer_id-$template_slug-series-sha256.txt"
        [ ! -e "$series_hash_path" ] || fail "series hash already exists"
        shasum -a 256 "$series_summary" | awk '{print $1}' >"$series_hash_path"
        chmod 0444 "$series_summary" "$series_hash_path"
        echo "Retained REVISE series summary:"
        echo "$series_summary"
        exit 0
    fi
done

series_decision=$sample_decision
binary_hash=
threshold_hash=
for repetition in 1 2 3
do
    summary=$(summary_path "$repetition")
    validate_finalized_sample "$summary"
    validate_summary_identity "$summary"
    [ -f "$summary" ] || fail "repetition $repetition summary is missing"
    trace_name=$(basename "$summary" .md).trace
    [ ! -e "$artifact_root/raw/$trace_name" ] \
        || fail "repetition $repetition accepted attempt has not been finalized"
    [ "$(summary_value "$repetition" renderer)" = "$renderer_id" ] \
        || fail "repetition $repetition renderer identity changed"
    [ "$(summary_value "$repetition" decision)" = "$sample_decision" ] \
        || fail "repetition $repetition does not match decision mode"
    current_binary_hash=$(summary_value "$repetition" binary-sha256)
    current_threshold_hash=$(summary_value "$repetition" threshold-sha256)
    if [ -z "$binary_hash" ]; then
        binary_hash=$current_binary_hash
        threshold_hash=$current_threshold_hash
    else
        [ "$current_binary_hash" = "$binary_hash" ] \
            || fail "binary hash changed within the series"
        [ "$current_threshold_hash" = "$threshold_hash" ] \
            || fail "threshold hash changed within the series"
    fi
done
[ "$binary_hash" = "$(sed -n '1p' "$artifact_root/binary-sha256.txt")" ] \
    || fail "series binary does not match the prepared artifact root"
[ "$threshold_hash" = "$(shasum -a 256 "$thresholds" | awk '{print $1}')" ] \
    || fail "series thresholds do not match the frozen artifact root"

sample1_hash=$(shasum -a 256 "$(summary_path 1)" | awk '{print $1}')
sample2_hash=$(shasum -a 256 "$(summary_path 2)" | awk '{print $1}')
sample3_hash=$(shasum -a 256 "$(summary_path 3)" | awk '{print $1}')

rss1=$(summary_value 1 rss-and-physical-footprint-mib | awk '{print $1}')
rss2=$(summary_value 2 rss-and-physical-footprint-mib | awk '{print $1}')
rss3=$(summary_value 3 rss-and-physical-footprint-mib | awk '{print $1}')
footprint1=$(summary_value 1 rss-and-physical-footprint-mib | awk '{print $3}')
footprint2=$(summary_value 2 rss-and-physical-footprint-mib | awk '{print $3}')
footprint3=$(summary_value 3 rss-and-physical-footprint-mib | awk '{print $3}')
rss_spread=$(spread_percent "$rss1" "$rss2" "$rss3")
footprint_spread=$(spread_percent "$footprint1" "$footprint2" "$footprint3")
rss_median=$(median_value "$rss1" "$rss2" "$rss3")
rss_worst=$(maximum_value "$rss1" "$rss2" "$rss3")
footprint_median=$(median_value "$footprint1" "$footprint2" "$footprint3")
footprint_worst=$(maximum_value "$footprint1" "$footprint2" "$footprint3")
if [ "$decision_mode" = adjudication ]; then
    exceeds "$rss_spread" "$rss_spread_limit" && series_decision=REVISE
    exceeds "$footprint_spread" "$footprint_spread_limit" && series_decision=REVISE
fi
peak_active1=$(summary_value 1 peak-active-presentations)
peak_active2=$(summary_value 2 peak-active-presentations)
peak_active3=$(summary_value 3 peak-active-presentations)
peak_active_spread=$(spread_percent "$peak_active1" "$peak_active2" "$peak_active3")
peak_active_median=$(median_value "$peak_active1" "$peak_active2" "$peak_active3")
peak_active_worst=$(maximum_value "$peak_active1" "$peak_active2" "$peak_active3")
if [ "$decision_mode" = adjudication ]; then
    exceeds "$peak_active_spread" "$peak_active_spread_limit" && series_decision=REVISE
fi
duration1=$(summary_value 1 measurement-duration-seconds)
duration2=$(summary_value 2 measurement-duration-seconds)
duration3=$(summary_value 3 measurement-duration-seconds)
duration_spread=$(spread_percent "$duration1" "$duration2" "$duration3")
duration_median=$(median_value "$duration1" "$duration2" "$duration3")
duration_worst=$(maximum_value "$duration1" "$duration2" "$duration3")
if [ "$decision_mode" = adjudication ]; then
    exceeds "$duration_spread" "$duration_spread_limit" && series_decision=REVISE
fi
drop_fraction() {
    pair=$(summary_value "$1" admitted-and-dropped-events)
    admitted=$(echo "$pair" | awk '{print $1}')
    dropped=$(echo "$pair" | awk '{print $3}')
    awk -v admitted="$admitted" -v dropped="$dropped" \
        'BEGIN {
            total = admitted + dropped
            if (total == 0) print 0
            else print dropped / total
        }'
}
drop1=$(drop_fraction 1)
drop2=$(drop_fraction 2)
drop3=$(drop_fraction 3)
drop_spread=$(spread_percent "$drop1" "$drop2" "$drop3")
drop_median=$(median_value "$drop1" "$drop2" "$drop3")
drop_worst=$(maximum_value "$drop1" "$drop2" "$drop3")
if [ "$decision_mode" = adjudication ]; then
    exceeds "$drop_spread" "$drop_spread_limit" && series_decision=REVISE
fi

case "$template_slug" in
    time-profiler)
        primary_name=process-cpu-percent
        primary_spread_limit=$process_cpu_spread_limit
        secondary_name=main-thread-cpu-percent
        secondary_spread_limit=$main_thread_cpu_spread_limit
        tertiary_name=maximum-detected-main-thread-hang-ms
        tertiary_spread_limit=$detected_hang_spread_limit
        ;;
    animation-hitches)
        primary_name=hitch-maximum-duration-ms
        primary_spread_limit=$hitch_duration_spread_limit
        secondary_name=
        secondary_spread_limit=N/A
        tertiary_name=
        tertiary_spread_limit=N/A
        ;;
    allocations)
        primary_name=persistent-allocation-growth-mib
        primary_spread_limit=$allocation_growth_spread_limit
        secondary_name=
        secondary_spread_limit=N/A
        tertiary_name=
        tertiary_spread_limit=N/A
        ;;
esac
if [ "$template_slug" = animation-hitches ]; then
    primary1=$(summary_value 1 hitch-count-and-maximum-duration-ms | awk '{print $3}')
    primary2=$(summary_value 2 hitch-count-and-maximum-duration-ms | awk '{print $3}')
    primary3=$(summary_value 3 hitch-count-and-maximum-duration-ms | awk '{print $3}')
else
    primary1=$(summary_value 1 "$primary_name")
    primary2=$(summary_value 2 "$primary_name")
    primary3=$(summary_value 3 "$primary_name")
fi
primary_spread=$(spread_percent "$primary1" "$primary2" "$primary3")
primary_median=$(median_value "$primary1" "$primary2" "$primary3")
primary_worst=$(maximum_value "$primary1" "$primary2" "$primary3")
if [ "$decision_mode" = adjudication ]; then
    exceeds "$primary_spread" "$primary_spread_limit" && series_decision=REVISE
fi

secondary_spread=N/A
secondary_median=N/A
secondary_worst=N/A
if [ -n "$secondary_name" ]; then
    secondary1=$(summary_value 1 "$secondary_name")
    secondary2=$(summary_value 2 "$secondary_name")
    secondary3=$(summary_value 3 "$secondary_name")
    secondary_spread=$(spread_percent "$secondary1" "$secondary2" "$secondary3")
    secondary_median=$(median_value "$secondary1" "$secondary2" "$secondary3")
    secondary_worst=$(maximum_value "$secondary1" "$secondary2" "$secondary3")
    if [ "$decision_mode" = adjudication ]; then
        exceeds "$secondary_spread" "$secondary_spread_limit" && series_decision=REVISE
    fi
fi

tertiary_spread=N/A
tertiary_median=N/A
tertiary_worst=N/A
if [ -n "$tertiary_name" ]; then
    tertiary1=$(summary_value 1 "$tertiary_name")
    tertiary2=$(summary_value 2 "$tertiary_name")
    tertiary3=$(summary_value 3 "$tertiary_name")
    tertiary_spread=$(spread_percent "$tertiary1" "$tertiary2" "$tertiary3")
    tertiary_median=$(median_value "$tertiary1" "$tertiary2" "$tertiary3")
    tertiary_worst=$(maximum_value "$tertiary1" "$tertiary2" "$tertiary3")
    if [ "$decision_mode" = adjudication ]; then
        exceeds "$tertiary_spread" "$tertiary_spread_limit" && series_decision=REVISE
    fi
fi

hitch_count_spread=N/A
hitch_count_median=N/A
hitch_count_worst=N/A
if [ "$template_slug" = animation-hitches ]; then
    hitch_count1=$(summary_value 1 hitch-count-and-maximum-duration-ms | awk '{print $1}')
    hitch_count2=$(summary_value 2 hitch-count-and-maximum-duration-ms | awk '{print $1}')
    hitch_count3=$(summary_value 3 hitch-count-and-maximum-duration-ms | awk '{print $1}')
    hitch_count_spread=$(spread_percent "$hitch_count1" "$hitch_count2" "$hitch_count3")
    hitch_count_median=$(median_value "$hitch_count1" "$hitch_count2" "$hitch_count3")
    hitch_count_worst=$(maximum_value "$hitch_count1" "$hitch_count2" "$hitch_count3")
    if [ "$decision_mode" = adjudication ]; then
        exceeds "$hitch_count_spread" "$hitch_count_spread_limit" && series_decision=REVISE
    fi
fi

{
    echo "# Danmaku Lab performance series"
    echo
    echo "- protocol-version: 4"
    echo "- preset: $preset_id@1"
    echo "- renderer: $renderer_id"
    echo "- template: $template_slug"
    echo "- repetitions: 3"
    echo "- binary-sha256: $binary_hash"
    echo "- benchmark-manifest-sha256: $benchmark_manifest_hash"
    echo "- threshold-sha256: $threshold_hash"
    echo "- decision-mode: $decision_mode"
    echo "- repetition-1-summary-sha256: $sample1_hash"
    echo "- repetition-2-summary-sha256: $sample2_hash"
    echo "- repetition-3-summary-sha256: $sample3_hash"
    echo "- rss-median-worst-mib: $rss_median / $rss_worst"
    echo "- rss-spread-percent: $rss_spread"
    echo "- rss-spread-limit-percent: $rss_spread_limit"
    echo "- physical-footprint-median-worst-mib: $footprint_median / $footprint_worst"
    echo "- physical-footprint-spread-percent: $footprint_spread"
    echo "- physical-footprint-spread-limit-percent: $footprint_spread_limit"
    echo "- peak-active-presentations-median-worst: $peak_active_median / $peak_active_worst"
    echo "- peak-active-presentations-spread-percent: $peak_active_spread"
    echo "- peak-active-presentations-spread-limit-percent: $peak_active_spread_limit"
    echo "- measurement-duration-median-worst-seconds: $duration_median / $duration_worst"
    echo "- measurement-duration-spread-percent: $duration_spread"
    echo "- measurement-duration-spread-limit-percent: $duration_spread_limit"
    echo "- drop-fraction-median-worst: $drop_median / $drop_worst"
    echo "- drop-fraction-spread-percent: $drop_spread"
    echo "- drop-fraction-spread-limit-percent: $drop_spread_limit"
    echo "- $primary_name-median-worst: $primary_median / $primary_worst"
    echo "- $primary_name-spread-percent: $primary_spread"
    echo "- $primary_name-spread-limit-percent: $primary_spread_limit"
    if [ -n "$secondary_name" ]; then
        echo "- $secondary_name-median-worst: $secondary_median / $secondary_worst"
        echo "- $secondary_name-spread-percent: $secondary_spread"
        echo "- $secondary_name-spread-limit-percent: $secondary_spread_limit"
    fi
    if [ -n "$tertiary_name" ]; then
        echo "- $tertiary_name-median-worst: $tertiary_median / $tertiary_worst"
        echo "- $tertiary_name-spread-percent: $tertiary_spread"
        echo "- $tertiary_name-spread-limit-percent: $tertiary_spread_limit"
    fi
    if [ "$template_slug" = animation-hitches ]; then
        echo "- hitch-count-median-worst: $hitch_count_median / $hitch_count_worst"
        echo "- hitch-count-spread-percent: $hitch_count_spread"
        echo "- hitch-count-spread-limit-percent: $hitch_count_spread_limit"
    fi
    echo "- decision: $series_decision"
} >"$series_summary"
series_hash_path="$artifact_root/frozen/$preset_id-$renderer_id-$template_slug-series-sha256.txt"
[ ! -e "$series_hash_path" ] || fail "series hash already exists"
shasum -a 256 "$series_summary" | awk '{print $1}' >"$series_hash_path"
chmod 0444 "$series_summary" "$series_hash_path"

echo "Retained series summary:"
echo "$series_summary"
