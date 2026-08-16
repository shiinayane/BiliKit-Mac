#!/bin/sh

set -eu
umask 077

fail() {
    echo "Danmaku Lab matrix finalization failed: $1" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail "usage: $0 ARTIFACT_ROOT RENDERER_ID"
artifact_root=$1
renderer_id=$2
case "$artifact_root" in
    /private/tmp/*) ;;
    *) fail "artifact root must be under /private/tmp" ;;
esac
artifact_name=${artifact_root#/private/tmp/}
case "$artifact_name" in
    ""|.|..|*/*) fail "artifact root must be one task-specific directory" ;;
esac
case "$renderer_id" in
    ""|*[!A-Za-z0-9._-]*) fail "renderer ID must be a static safe identifier" ;;
esac
[ "$(sed -n 's/^decision-mode=//p' "$artifact_root/benchmark-manifest.txt")" = adjudication ] \
    || fail "a calibration run cannot produce an adjudication matrix"

matrix_summary="$artifact_root/summaries/$renderer_id-matrix.md"
[ ! -e "$matrix_summary" ] || fail "matrix summary already exists"
matrix_decision=ACCEPTED
binary_hash=$(sed -n '1p' "$artifact_root/binary-sha256.txt")
threshold_hash=$(shasum -a 256 "$artifact_root/frozen/thresholds.md" | awk '{print $1}')
entries=
for preset in steady-80 burst-320 capacity-640
do
    for template in time-profiler animation-hitches allocations
    do
        series="$artifact_root/summaries/$preset-$renderer_id-$template-series.md"
        [ -f "$series" ] || fail "missing series $preset/$template"
        series_hash_path="$artifact_root/frozen/$preset-$renderer_id-$template-series-sha256.txt"
        [ -f "$series_hash_path" ] || fail "missing frozen series hash for $preset/$template"
        series_hash=$(shasum -a 256 "$series" | awk '{print $1}')
        [ "$series_hash" = "$(sed -n '1p' "$series_hash_path")" ] \
            || fail "series changed after finalization for $preset/$template"
        [ "$(sed -n 's/^- preset: //p' "$series")" = "$preset@1" ] \
            || fail "series preset identity mismatch for $preset/$template"
        [ "$(sed -n 's/^- renderer: //p' "$series")" = "$renderer_id" ] \
            || fail "series renderer identity mismatch for $preset/$template"
        [ "$(sed -n 's/^- template: //p' "$series")" = "$template" ] \
            || fail "series template identity mismatch for $preset/$template"
        decision=$(sed -n 's/^- decision: //p' "$series")
        case "$decision" in
            ACCEPTED) ;;
            REVISE) matrix_decision=REVISE ;;
            *) fail "invalid series decision for $preset/$template" ;;
        esac
        current_binary=$(sed -n 's/^- binary-sha256: //p' "$series")
        current_threshold=$(sed -n 's/^- threshold-sha256: //p' "$series")
        [ "$current_binary" = "$binary_hash" ] \
            || fail "binary identity changed across the matrix"
        [ "$current_threshold" = "$threshold_hash" ] \
            || fail "threshold identity changed across the matrix"
        entries="$entries- $preset/$template: $decision ($series_hash)
"
    done
done

{
    echo "# Danmaku Lab performance matrix"
    echo
    echo "- renderer: $renderer_id"
    echo "- binary-sha256: $binary_hash"
    echo "- threshold-sha256: $threshold_hash"
    echo "- decision: $matrix_decision"
    echo
    printf "%s" "$entries"
} >"$matrix_summary"
matrix_hash_path="$artifact_root/frozen/$renderer_id-matrix-sha256.txt"
[ ! -e "$matrix_hash_path" ] || fail "matrix hash already exists"
shasum -a 256 "$matrix_summary" | awk '{print $1}' >"$matrix_hash_path"
chmod 0444 "$matrix_summary" "$matrix_hash_path"

echo "Retained matrix summary:"
echo "$matrix_summary"
