#!/bin/zsh
# Intentionally malformed wrapper for testing invalid-syntax detection.

export HOME="/Users/exampleuser"
if [ "$HOME" = "" ]
  echo "missing then"
exec "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli" acp
