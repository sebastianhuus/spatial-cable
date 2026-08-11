#!/usr/bin/env bash

COMMAND=$(jq -r '.tool_input.command // ""' 2>/dev/null) || COMMAND=""

# Strip heredoc bodies so their content doesn't cause false positives.
# Heredoc body lines are not shell statements; only the opening line is.
heredoc_re="<<-?['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"
in_heredoc=0
heredoc_delim=""
STRIPPED=""
while IFS= read -r line; do
  if (( in_heredoc )); then
    candidate="${line#"${line%%[![:space:]]*}"}"  # strip leading whitespace (<<- style)
    [[ "$candidate" == "$heredoc_delim" ]] && in_heredoc=0
    continue
  fi
  if [[ "$line" =~ $heredoc_re ]]; then
    heredoc_delim="${BASH_REMATCH[1]}"
    in_heredoc=1
  fi
  STRIPPED+="$line"$'\n'
done <<< "$COMMAND"

# Strip quoted-string contents so ; or spox inside -m "..." or 'msg' don't trigger.
UNQUOTED=$(printf '%s' "$STRIPPED" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")

# Standalone spox calls (no chain operators) are fine — only inspect when chaining is present.
printf '%s' "$UNQUOTED" | grep -qE '(&&|\|\||;)' || exit 0

# Block only when spox is the actual executable — first token of any chain segment.
# Avoids false positives where "spox" appears in a commit message, quoted arg, or heredoc body.
MATCHED_SEGMENT=""
while IFS= read -r segment; do
  trimmed="${segment#"${segment%%[![:space:]]*}"}"
  first_token="${trimmed%% *}"
  if [ "$first_token" = "spox" ]; then
    MATCHED_SEGMENT="$trimmed"
    break
  fi
done < <(printf '%s' "$UNQUOTED" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g')

if [ -n "$MATCHED_SEGMENT" ]; then
  jq -n --arg reason "Chained spox command blocked (matched: \"$MATCHED_SEGMENT\"). Each spox call must be a separate tool use — do not chain with &&, ||, or ;. Run the command alone so its output can be reviewed before the next call." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi
