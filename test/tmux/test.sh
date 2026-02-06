#!/bin/sh
set -eu

if command -v tmux >/dev/null 2>&1; then
    echo "Tmux is installed."
    exit 0
fi

echo "Tmux is not installed."
exit 1
