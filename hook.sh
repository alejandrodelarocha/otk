#!/bin/bash
# OTK Hook — same pattern as RTK's hook
# Place in ~/.claude/hooks/ or your OpenAI tool's hooks directory
# Rewrites CLI commands to go through otk

CMD="$1"
shift

# Commands to filter through OTK
FILTER_CMDS="git npm pnpm yarn docker pip cargo make kubectl helm"

for fc in $FILTER_CMDS; do
    if [ "$CMD" = "$fc" ]; then
        exec python3 "$HOME/otk/otk.py" "$CMD" "$@"
    fi
done

# Pass through everything else unchanged
exec "$CMD" "$@"
