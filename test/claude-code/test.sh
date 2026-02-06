#!/bin/sh
set -eu

if [ -z "${HOME}" ] || [ "${HOME}" = "/" ] || [ "${HOME}" = "/nonexistent" ] || ! [ -d "${HOME}" ] || ! [ -w "${HOME}" ]; then
    echo "Skipping Claude Code installation test (HOME directory not writable)"
    exit 0
fi

if command -v claude >/dev/null 2>&1; then
    echo "Claude Code is installed."
    exit 0
fi

echo "Claude Code is not installed."
exit 1
