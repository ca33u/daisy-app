#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
export UV_CACHE_DIR="${PROJECT_DIR}/build/uv-cache"
exec uv run --locked --script "${SCRIPT_DIR}/models_sync.py" "$@"
