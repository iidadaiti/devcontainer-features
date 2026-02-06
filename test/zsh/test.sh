#!/bin/sh
set -eu

if command -v zsh >/dev/null 2>&1; then
    echo "Zsh is installed."
    exit 0
fi

echo "Zsh is not installed."
exit 1
