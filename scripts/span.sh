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

HAVE_FFPROBE=0
HAVE_FFMPEG=0
command -v ffprobe >/dev/null 2>&1 && HAVE_FFPROBE=1
command -v ffmpeg >/dev/null 2>&1 && HAVE_FFMPEG=1

is_video_ext() {
    case "${1##*.}" in
        mp4|mkv|webm|mov|m4v|avi|flv|wmv|MP4|MKV|WEBM|MOV|M4V|AVI|FLV|WMV) return 0 ;;
        *) return 1 ;;
    esac
}

probe_video() {
    local vid="$1"
    if [[ "$HAVE_FFPROBE" -eq 1 ]]; then
        local dims
        dims="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$vid" 2>/dev/null | head -n 1 || true)"
        if [[ "$dims" =~ ^([0-9]+)x([0-9]+)$ ]]; then
            printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
            return 0
        fi
    fi
    printf '0\t0\n'
}

cmd="${1:-}"
shift || true

case "$cmd" in
    caps)
        have_mpvpaper=0
        command -v mpvpaper >/dev/null 2>&1 && have_mpvpaper=1
        printf 'mpvpaper=%d\tffmpeg=%d\tffprobe=%d\n' "$have_mpvpaper" "$HAVE_FFMPEG" "$HAVE_FFPROBE"
        ;;

    scan)
        dir="${1:-}"
        recursive="${2:-1}"
        if [[ -z "$dir" || ! -d "$dir" ]]; then
            exit 0
        fi

        depth_args=()
        if [[ "$recursive" != "1" ]]; then
            depth_args+=(-maxdepth 1)
        fi

        {
            find "$dir" "${depth_args[@]}" -type f \
                \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \
                   -o -iname '*.bmp' -o -iname '*.gif' -o -iname '*.jxl' -o -iname '*.avif' -o -iname '*.heif' \) \
                -print0 2>/dev/null \
                | xargs -0 -r "${IDENTIFY_BIN[@]}" -ping -format $'image\t%w\t%h\t%d/%f\n' 2>/dev/null || true

            find "$dir" "${depth_args[@]}" -type f \
                \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.mov' \
                   -o -iname '*.m4v' -o -iname '*.avi' -o -iname '*.flv' -o -iname '*.wmv' \) \
                -print0 2>/dev/null \
                | xargs -0 -r -n 1 -P 4 bash -c '
                    vid="$1"
                    if command -v ffprobe >/dev/null 2>&1; then
                        dims="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$vid" 2>/dev/null | head -n 1 || true)"
                        if [[ "$dims" =~ ^([0-9]+)x([0-9]+)$ ]]; then
                            w="${BASH_REMATCH[1]}"
                            h="${BASH_REMATCH[2]}"
                        else
                            w=0; h=0
                        fi
                    else
                        w=0; h=0
                    fi
                    printf "video\t%s\t%s\t%s\n" "$w" "$h" "$vid"
                ' _ || true
        } | LC_ALL=C sort -t $'\t' -k4,4
        ;;

    probe)
        media="${1:-}"
        if [[ -z "$media" || ! -f "$media" ]]; then
            echo "File not found: $media" >&2
            exit 1
        fi
        if is_video_ext "$media"; then
            probe_video "$media"
        else
            "${IDENTIFY_BIN[@]}" -ping -format $'%w\t%h\n' "$media" | head -n 1
        fi
        ;;

    video-thumb)
        vid="${1:-}"
        cache_dir="${2:-}"
        if [[ -z "$vid" || ! -f "$vid" ]]; then
            echo "Video not found: $vid" >&2
            exit 1
        fi
        if [[ -z "$cache_dir" ]]; then
            echo "Cache dir required" >&2
            exit 2
        fi
        if [[ "$HAVE_FFMPEG" -ne 1 ]]; then
            echo "ffmpeg not found" >&2
            exit 127
        fi

        mkdir -p "$cache_dir"
        stat_info="$(stat -Lc '%Y|%s' "$vid" 2>/dev/null || echo '0|0')"
        cache_key="$(printf '%s|%s|vthumb' "$vid" "$stat_info" | sha256sum | cut -c1-16)"
        out_path="${cache_dir}/vthumb_${cache_key}.jpg"

        if [[ ! -s "$out_path" ]]; then
            tmp_path="${out_path}.tmp.$$.jpg"
            vf="scale=380:236:force_original_aspect_ratio=increase,crop=380:236"
            if ! ffmpeg -loglevel error -ss 00:00:01 -i "$vid" -vframes 1 -vf "$vf" -q:v 3 -y "$tmp_path" 2>/dev/null || [[ ! -s "$tmp_path" ]]; then
                rm -f "$tmp_path"
                ffmpeg -loglevel error -ss 00:00:00 -i "$vid" -vframes 1 -vf "$vf" -q:v 3 -y "$tmp_path"
            fi
            mv -f "$tmp_path" "$out_path"
        fi
        printf '%s\n' "$out_path"
        ;;

    video-still)
        vid="${1:-}"
        cache_dir="${2:-}"
        crop_geom="${3:-}"
        if [[ -z "$vid" || ! -f "$vid" ]]; then
            echo "Video not found: $vid" >&2
            exit 1
        fi
        if [[ -z "$cache_dir" ]]; then
            echo "Cache dir required" >&2
            exit 2
        fi
        if [[ "$HAVE_FFMPEG" -ne 1 ]]; then
            echo "ffmpeg not found" >&2
            exit 127
        fi

        mkdir -p "$cache_dir"
        stat_info="$(stat -Lc '%Y|%s' "$vid" 2>/dev/null || echo '0|0')"
        cache_key="$(printf '%s|%s|still|%s' "$vid" "$stat_info" "$crop_geom" | sha256sum | cut -c1-16)"
        out_path="${cache_dir}/still_${cache_key}.jpg"

        if [[ ! -s "$out_path" ]]; then
            tmp_path="${out_path}.tmp.$$.jpg"
            vf="scale=1280:-2"
            if [[ "$crop_geom" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
                cw="${BASH_REMATCH[1]}"
                ch="${BASH_REMATCH[2]}"
                cx="${BASH_REMATCH[3]}"
                cy="${BASH_REMATCH[4]}"
                vf="crop=${cw}:${ch}:${cx}:${cy},scale=1280:-2"
            fi
            if ! ffmpeg -loglevel error -ss 00:00:02 -i "$vid" -vframes 1 -vf "$vf" -q:v 2 -y "$tmp_path" 2>/dev/null || [[ ! -s "$tmp_path" ]]; then
                rm -f "$tmp_path"
                ffmpeg -loglevel error -ss 00:00:00 -i "$vid" -vframes 1 -vf "$vf" -q:v 2 -y "$tmp_path"
            fi
            mv -f "$tmp_path" "$out_path"
        fi
        printf '%s\n' "$out_path"
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
            find "$cache_dir" -maxdepth 1 -type f \( -name '*.png' -o -name 'vthumb_*.jpg' -o -name 'still_*.jpg' -o -name '*.tmp.*' \) -delete
        fi
        ;;

    *)
        echo "Usage: $0 {caps|scan|probe|video-thumb|video-still|split|clear-cache} ..." >&2
        exit 2
        ;;
esac
