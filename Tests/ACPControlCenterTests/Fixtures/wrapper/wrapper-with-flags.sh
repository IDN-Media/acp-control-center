#!/bin/zsh
# Wrapper for running Kiro CLI as an ACP agent from Xcode, with explicit model/effort.

export HOME="/Users/exampleuser"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Users/exampleuser/.local/bin:/Users/exampleuser/bin"

exec "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli" acp --model claude-opus-4.6 --effort high
