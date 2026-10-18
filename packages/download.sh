#!/bin/bash
set -euo pipefail

fail() {
    echo "$@" >&2
    exit 1
}

PACKAGE_FILE="$1"
TARGET_FILE="${2:-${PACKAGE_FILE%.package}}"

if test ! -f "$PACKAGE_FILE"
then
    fail "Error: package file '$PACKAGE_FILE' not found"
fi

IFS=$'\n' read -d '' -r MD5 URL < "$PACKAGE_FILE" || true

if test -z "$MD5"
then
    fail "Error: $PACKAGE_FILE: missing md5sum"
fi

if test -z "$URL"
then
    fail "Error: $PACKAGE_FILE: missing url"
fi

TMP=$(mktemp "${TARGET_FILE}.tmp.XXXXXX")
trap 'rm -f "$TMP"' EXIT INT TERM HUP

echo "Downloading $TARGET_FILE from $URL..."
curl -fsSL "$URL" -o "$TMP"

ACTUAL_MD5=$(md5sum "$TMP" | awk '{print $1}')

if test "${ACTUAL_MD5,,}" != "${MD5,,}"
then
    echo "  Expected: $MD5" >&2
    echo "  Actual:   $ACTUAL_MD5" >&2
    fail "Error: MD5 mismatch for $TARGET_FILE"
fi

mv "$TMP" "$TARGET_FILE"
chmod a+r "$TARGET_FILE"
trap - EXIT INT TERM HUP
echo "Successfully downloaded and verified $TARGET_FILE."
