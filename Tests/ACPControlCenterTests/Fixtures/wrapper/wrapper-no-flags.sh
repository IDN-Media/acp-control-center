#!/bin/zsh
# Wrapper for running Kiro CLI as an ACP agent from Xcode.
# Purpose: give Xcode an executable path without spaces and with explicit GUI-safe env.

export HOME="/Users/exampleuser"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Users/exampleuser/.local/bin:/Users/exampleuser/bin"

exec "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli" acp
