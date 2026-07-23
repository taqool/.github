#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build.sh [options] [source.tex ...]

Build LaTeX files from docs/src with XeLaTeX.

Options:
  --output-dir DIR  Output directory relative to docs (default: build)
  --passes N        Number of XeLaTeX passes, from 1 to 10 (default: 3)
  -h, --help        Show this help message

Sources may be absolute, relative to docs/src, or relative to docs.
When no source is supplied, every top-level docs/src/*.tex file is built.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
source_root="$project_root/src"
output_dir="build"
passes=3
requested_sources=()

while (($# > 0)); do
  case "$1" in
    --output-dir)
      (($# >= 2)) || fail "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --passes)
      (($# >= 2)) || fail "--passes requires a value"
      passes="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      requested_sources+=("$@")
      break
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      requested_sources+=("$1")
      shift
      ;;
  esac
done

[[ -d "$source_root" ]] || fail "source directory not found: $source_root"
[[ "$passes" =~ ^[0-9]+$ ]] || fail "--passes must be an integer from 1 to 10"
((passes >= 1 && passes <= 10)) || fail "--passes must be from 1 to 10"
command -v xelatex >/dev/null 2>&1 || fail "xelatex was not found in PATH. Install TeX Live with XeLaTeX support."

if [[ "$output_dir" = /* ]]; then
  output_path="$output_dir"
else
  output_path="$project_root/$output_dir"
fi

mkdir -p -- "$output_path"
output_path="$(cd -- "$output_path" && pwd -P)"
temp_root="$output_path/.latex"

[[ "$temp_root" == "$output_path/.latex" && "$temp_root" != "/.latex" ]] ||
  fail "refusing to use unsafe temporary path: $temp_root"

resolve_source() {
  local requested="$1"
  local candidate
  local candidates=()

  if [[ "$requested" = /* ]]; then
    candidates+=("$requested")
  else
    candidates+=("$source_root/$requested" "$project_root/$requested")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      [[ "$candidate" == *.tex ]] || fail "source must be a .tex file: $candidate"
      printf '%s/%s\n' "$(cd -- "$(dirname -- "$candidate")" && pwd -P)" "$(basename -- "$candidate")"
      return 0
    fi
  done

  fail "source file not found: $requested"
}

source_paths=()

if ((${#requested_sources[@]} > 0)); then
  for requested_source in "${requested_sources[@]}"; do
    source_paths+=("$(resolve_source "$requested_source")")
  done
else
  shopt -s nullglob
  source_paths=("$source_root"/*.tex)
  shopt -u nullglob
fi

((${#source_paths[@]} > 0)) || fail "no .tex files found in $source_root"

declare -A seen_sources=()
unique_source_paths=()
for source_path in "${source_paths[@]}"; do
  if [[ -z "${seen_sources[$source_path]+present}" ]]; then
    seen_sources["$source_path"]=1
    unique_source_paths+=("$source_path")
  fi
done
source_paths=("${unique_source_paths[@]}")

rm -rf -- "$temp_root"
mkdir -p -- "$temp_root"

build_succeeded=0
cleanup() {
  if ((build_succeeded == 1)); then
    rm -rf -- "$temp_root"
  fi
}
trap cleanup EXIT

cd -- "$project_root"

for source_path in "${source_paths[@]}"; do
  source_name="$(basename -- "$source_path")"
  job_name="${source_name%.tex}"
  job_temp_path="$temp_root/$job_name"
  log_path="$job_temp_path/$job_name.log"

  mkdir -p -- "$job_temp_path"

  for ((pass = 1; pass <= passes; pass++)); do
    printf '[%s] XeLaTeX pass %d of %d\n' "$job_name" "$pass" "$passes"

    if ! xelatex \
      -interaction=nonstopmode \
      -halt-on-error \
      -file-line-error \
      -synctex=0 \
      "-output-directory=$job_temp_path" \
      "$source_path"; then
      fail "XeLaTeX failed on pass $pass for $source_path. See $log_path"
    fi
  done

  built_pdf="$job_temp_path/$job_name.pdf"
  [[ -f "$built_pdf" ]] || fail "expected PDF was not produced: $built_pdf"

  destination_pdf="$output_path/$job_name.pdf"
  cp -f -- "$built_pdf" "$destination_pdf"
  printf 'Built %s\n' "$destination_pdf"
done

build_succeeded=1
printf 'Completed %d PDF build(s) with XeLaTeX.\n' "${#source_paths[@]}"
