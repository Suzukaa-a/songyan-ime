#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="${ROOT}/.scratch"
mkdir -p "${SCRATCH}"
# Files first, then directories that are empty and equally old; never follows links.
find "${SCRATCH}" -mindepth 1 -not -type d -mtime +7 -delete
find "${SCRATCH}" -mindepth 1 -depth -type d -empty -mtime +7 -delete
