#!/bin/sh

set -eu

mode="static"
saw_path=0

while IFS= read -r path; do
    [ -n "$path" ] || continue
    saw_path=1
    case "$path" in
        *.md) ;;
        *)
            mode="app"
            break
            ;;
    esac
done

if [ "$saw_path" -eq 0 ]; then
    mode="app"
fi

printf '%s\n' "$mode"
