#!/bin/bash
# Opens a URL in browser, a directory in Finder, or a file in the default viewer.
# Used by the SwiftBar menubar plugin for prompt links, worktrees, and full log views.

arg="$1"

if [[ "$arg" == https://discord.com/* ]]; then
  open "discord://${arg#https://}"
elif [[ "$arg" == http* ]]; then
  open "$arg"
elif [[ -d "$arg" ]]; then
  open -a Kiro "$arg"
elif [[ -f "$arg" ]]; then
  open -a "Console" "$arg" 2>/dev/null || open "$arg"
fi
