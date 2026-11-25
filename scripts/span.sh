#!/usr/bin/env bash
set -euo pipefail

if command -v magick >/dev/null 2>&1; then
    MAGICK_BIN=(magick)
    IDENTIFY_BIN=(magick identify)
elif command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
    MAGICK_BIN=(convert)
    IDENTIFY_BIN=(identify)
else
    echo "ImageMagick (magick or convert/identify) not found" >&2
    exit 127
fi

cmd="${1:-}"
shift || true

case "$cmd" in
    scan)
        dir="${1:-}"
        recursive="${2:-1}"
        if [[ -z "$dir" || ! -d "$dir" ]]; then
            exit 0
        fi
        find_args=("$dir")
        if [[ "$recursive" != "1" ]]; then
            find_args+=(-maxdepth 1)
        fi
        find_args+=(
            -type f
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp'
               -o -iname '*.bmp' -o -iname '*.gif' -o -iname '*.jxl' -o -iname '*.avif' -o -iname '*.heif' \)
            -print0
        )
        find "${find_args[@]}" 2>/dev/null \
            | xargs -0 -r "${IDENTIFY_BIN[@]}" -ping -format $'%w\t%h\t%d/%f\n' 2>/dev/null \
            | LC_ALL=C sort -t $'\t' -k3,3
        ;;

    probe)
        img="${1:-}"
        if [[ -z "$img" || ! -f "$img" ]]; then
            echo "File not found: $img" >&2
            exit 1
        fi
        "${IDENTIFY_BIN[@]}" -ping -format $'%w\t%h\n' "$img" | head -n 1
        ;;

    split)
        img="${1:-}"
        cache_dir="${2:-}"
        layout_sig="${3:-cover}"
        shift 3 || { echo "Missing split arguments" >&2; exit 2; }

        if [[ -z "$img" || ! -f "$img" ]]; then
            echo "Input image not found: $img" >&2
            exit 1
        fi
        if [[ -z "$cache_dir" || $# -eq 0 ]]; then
            echo "Cache dir and monitor crop specs required" >&2
            exit 2
        fi

        mkdir -p "$cache_dir"

        stat_info="$(stat -Lc '%Y|%s' "$img" 2>/dev/null || echo '0|0')"
        cache_key="$(printf '%s|%s|%s' "$img" "$stat_info" "$layout_sig" | sha256sum | cut -c1-16)"

        names=()
        geoms=()
        outs=()
        all_cached=1

        for spec in "$@"; do
            name="${spec%%:*}"
            geom="${spec#*:}"
            if [[ -z "$name" || -z "$geom" || "$name" == "$spec" ]]; then
                echo "Invalid crop spec: $spec" >&2
                exit 2
            fi
            safe_name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
            out_path="${cache_dir}/${cache_key}_${safe_name}.png"
            names+=("$name")
            geoms+=("$geom")
            outs+=("$out_path")
            if [[ ! -s "$out_path" ]]; then
                all_cached=0
            fi
        done

        if [[ "$all_cached" -eq 0 ]]; then
            tmp_outs=()
            magick_args=("$img" -auto-orient)
            for i in "${!outs[@]}"; do
                tmp_path="${outs[$i]}.tmp.$$"
                tmp_outs+=("$tmp_path")
                magick_args+=( "(" +clone -crop "${geoms[$i]}" +repage +write "png:${tmp_path}" ")" +delete )
            done
            magick_args+=("null:")

            "${MAGICK_BIN[@]}" "${magick_args[@]}"

            for i in "${!outs[@]}"; do
                mv -f "${tmp_outs[$i]}" "${outs[$i]}"
            done
        fi

        for i in "${!names[@]}"; do
            printf '%s\t%s\n' "${names[$i]}" "${outs[$i]}"
        done
        ;;

    clear-cache)
        cache_dir="${1:-}"
        if [[ -z "$cache_dir" ]]; then
            echo "Cache dir required" >&2
            exit 2
        fi
        if [[ -d "$cache_dir" ]]; then
            find "$cache_dir" -maxdepth 1 -type f \( -name '*.png' -o -name '*.tmp.*' \) -delete
        fi
        ;;

    *)
        echo "Usage: $0 {scan|probe|split|clear-cache} ..." >&2
        exit 2
        ;;
esac
