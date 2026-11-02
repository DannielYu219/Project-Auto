#!/bin/bash
# Only a clean CPython base is copied into the App. Engine packages stay outside.
set -euo pipefail
: "${SRCROOT:?}"
: "${TARGET_BUILD_DIR:?}"
: "${CONTENTS_FOLDER_PATH:?}"
SOURCE="${SRCROOT}/../Runtime/split-ai/python-base"
DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Resources/python-base"
test -f "${SOURCE}/runtime.json"
test -x "${SOURCE}/python/bin/python3.12"
mkdir -p "${DEST}"
/usr/bin/ditto "${SOURCE}" "${DEST}"
if [ -d "${DEST}/python/lib/python3.12/site-packages/mlx" ]; then
    echo 'Python base unexpectedly contains MLX' >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "${DEST}/python/bin/python3.12"
