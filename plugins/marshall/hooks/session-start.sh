#!/usr/bin/env bash
# Surface Marshall release configuration at Codex session start — but ONLY for
# repos that explicitly opt in through state.backend = "srm" or "marshall".
# For every other repo this stays completely silent, so it never nags unrelated
# projects.
#
# Registered as a Codex PLUGIN hook (plugin.json "hooks" → hooks/hooks.json, which
# runs this via ${PLUGIN_ROOT}), so it fires from wherever Codex placed the plugin.
# The hook proves only that the repo opted in; MCP connectivity is established by
# Codex itself and cannot be inferred from a local script.
set -uo pipefail

LC_ALL=C

readonly MAX_CONFIG_BYTES=16384
readonly MAX_JSON_DEPTH=64

JSON_TEXT=''
JSON_INDEX=0
JSON_LENGTH=0
JSON_DEPTH=0
JSON_STRING=''
MARSHALL_BACKEND=''
MARSHALL_BACKEND_PRESENT=0

skip_json_whitespace() {
  local character

  while (( JSON_INDEX < JSON_LENGTH )); do
    character=${JSON_TEXT:JSON_INDEX:1}

    case "$character" in
      ' '|$'\t'|$'\n'|$'\r') ((JSON_INDEX += 1)) ;;
      *) return 0 ;;
    esac
  done
}

parse_json_string() {
  local character escape hex codepoint decoded first second third fourth

  [[ ${JSON_TEXT:JSON_INDEX:1} == '"' ]] || return 1
  ((JSON_INDEX += 1))
  JSON_STRING=''

  while (( JSON_INDEX < JSON_LENGTH )); do
    character=${JSON_TEXT:JSON_INDEX:1}
    ((JSON_INDEX += 1))

    case "$character" in
      '"') return 0 ;;
      $'\\')
        (( JSON_INDEX < JSON_LENGTH )) || return 1
        escape=${JSON_TEXT:JSON_INDEX:1}
        ((JSON_INDEX += 1))

        case "$escape" in
          '"'|$'\\'|'/') JSON_STRING+=$escape ;;
          'b'|'f'|'n'|'r'|'t') JSON_STRING+='?' ;;
          'u')
            (( JSON_INDEX + 4 <= JSON_LENGTH )) || return 1
            hex=${JSON_TEXT:JSON_INDEX:4}
            [[ $hex =~ ^[[:xdigit:]]{4}$ ]] || return 1
            ((JSON_INDEX += 4))
            codepoint=$((16#$hex))

            if (( codepoint >= 55296 && codepoint <= 56319 )); then
              (( JSON_INDEX + 6 <= JSON_LENGTH )) || return 1
              [[ ${JSON_TEXT:JSON_INDEX:2} == $'\\u' ]] || return 1
              hex=${JSON_TEXT:JSON_INDEX+2:4}
              [[ $hex =~ ^[[:xdigit:]]{4}$ ]] || return 1
              codepoint=$((16#$hex))
              (( codepoint >= 56320 && codepoint <= 57343 )) || return 1
              ((JSON_INDEX += 6))
              JSON_STRING+='?'
            elif (( codepoint >= 56320 && codepoint <= 57343 )); then
              return 1
            elif (( codepoint > 0 && codepoint < 128 )); then
              printf -v decoded "\\$(printf '%03o' "$codepoint")"
              JSON_STRING+=$decoded
            else
              JSON_STRING+='?'
            fi
            ;;
          *) return 1 ;;
        esac
        ;;
      *)
        printf -v first '%d' "'$character"
        (( first < 0 )) && ((first += 256))
        (( first >= 32 )) || return 1

        if (( first < 128 )); then
          JSON_STRING+=$character
          continue
        fi

        if (( first >= 194 && first <= 223 )); then
          (( JSON_INDEX + 1 <= JSON_LENGTH )) || return 1
          printf -v second '%d' "'${JSON_TEXT:JSON_INDEX:1}"
          (( second < 0 )) && ((second += 256))
          (( second >= 128 && second <= 191 )) || return 1
          ((JSON_INDEX += 1))
        elif (( first >= 224 && first <= 239 )); then
          (( JSON_INDEX + 2 <= JSON_LENGTH )) || return 1
          printf -v second '%d' "'${JSON_TEXT:JSON_INDEX:1}"
          printf -v third '%d' "'${JSON_TEXT:JSON_INDEX+1:1}"
          (( second < 0 )) && ((second += 256))
          (( third < 0 )) && ((third += 256))
          (( third >= 128 && third <= 191 )) || return 1

          if (( first == 224 )); then
            (( second >= 160 && second <= 191 )) || return 1
          elif (( first == 237 )); then
            (( second >= 128 && second <= 159 )) || return 1
          else
            (( second >= 128 && second <= 191 )) || return 1
          fi

          ((JSON_INDEX += 2))
        elif (( first >= 240 && first <= 244 )); then
          (( JSON_INDEX + 3 <= JSON_LENGTH )) || return 1
          printf -v second '%d' "'${JSON_TEXT:JSON_INDEX:1}"
          printf -v third '%d' "'${JSON_TEXT:JSON_INDEX+1:1}"
          printf -v fourth '%d' "'${JSON_TEXT:JSON_INDEX+2:1}"
          (( second < 0 )) && ((second += 256))
          (( third < 0 )) && ((third += 256))
          (( fourth < 0 )) && ((fourth += 256))
          (( third >= 128 && third <= 191 )) || return 1
          (( fourth >= 128 && fourth <= 191 )) || return 1

          if (( first == 240 )); then
            (( second >= 144 && second <= 191 )) || return 1
          elif (( first == 244 )); then
            (( second >= 128 && second <= 143 )) || return 1
          else
            (( second >= 128 && second <= 191 )) || return 1
          fi

          ((JSON_INDEX += 3))
        else
          return 1
        fi

        JSON_STRING+='?'
        ;;
    esac
  done

  return 1
}

parse_json_number() {
  local character

  if [[ ${JSON_TEXT:JSON_INDEX:1} == '-' ]]; then
    ((JSON_INDEX += 1))
  fi

  character=${JSON_TEXT:JSON_INDEX:1}
  if [[ $character == '0' ]]; then
    ((JSON_INDEX += 1))
    [[ ${JSON_TEXT:JSON_INDEX:1} =~ [0-9] ]] && return 1
  elif [[ $character =~ [1-9] ]]; then
    while [[ ${JSON_TEXT:JSON_INDEX:1} =~ [0-9] ]]; do
      ((JSON_INDEX += 1))
    done
  else
    return 1
  fi

  if [[ ${JSON_TEXT:JSON_INDEX:1} == '.' ]]; then
    ((JSON_INDEX += 1))
    [[ ${JSON_TEXT:JSON_INDEX:1} =~ [0-9] ]] || return 1
    while [[ ${JSON_TEXT:JSON_INDEX:1} =~ [0-9] ]]; do
      ((JSON_INDEX += 1))
    done
  fi

  character=${JSON_TEXT:JSON_INDEX:1}
  if [[ $character == 'e' || $character == 'E' ]]; then
    ((JSON_INDEX += 1))
    character=${JSON_TEXT:JSON_INDEX:1}
    if [[ $character == '+' || $character == '-' ]]; then
      ((JSON_INDEX += 1))
    fi
    [[ ${JSON_TEXT:JSON_INDEX:1} =~ [0-9] ]] || return 1
    while [[ ${JSON_TEXT:JSON_INDEX:1} =~ [0-9] ]]; do
      ((JSON_INDEX += 1))
    done
  fi
}

parse_json_array() {
  ((JSON_DEPTH += 1))
  (( JSON_DEPTH <= MAX_JSON_DEPTH )) || return 1
  ((JSON_INDEX += 1))
  skip_json_whitespace

  if [[ ${JSON_TEXT:JSON_INDEX:1} == ']' ]]; then
    ((JSON_INDEX += 1))
    ((JSON_DEPTH -= 1))
    return 0
  fi

  while true; do
    parse_json_value other || return 1
    skip_json_whitespace

    case ${JSON_TEXT:JSON_INDEX:1} in
      ',') ((JSON_INDEX += 1)); skip_json_whitespace ;;
      ']') ((JSON_INDEX += 1)); ((JSON_DEPTH -= 1)); return 0 ;;
      *) return 1 ;;
    esac
  done
}

parse_json_object() {
  local context=$1 key target

  ((JSON_DEPTH += 1))
  (( JSON_DEPTH <= MAX_JSON_DEPTH )) || return 1
  ((JSON_INDEX += 1))
  skip_json_whitespace

  if [[ ${JSON_TEXT:JSON_INDEX:1} == '}' ]]; then
    ((JSON_INDEX += 1))
    ((JSON_DEPTH -= 1))
    return 0
  fi

  while true; do
    parse_json_string || return 1
    key=$JSON_STRING
    skip_json_whitespace
    [[ ${JSON_TEXT:JSON_INDEX:1} == ':' ]] || return 1
    ((JSON_INDEX += 1))
    skip_json_whitespace
    target=other

    if [[ $context == root && $key == state ]]; then
      MARSHALL_BACKEND=''
      MARSHALL_BACKEND_PRESENT=0
      target=state
    elif [[ $context == state && $key == backend ]]; then
      MARSHALL_BACKEND=''
      MARSHALL_BACKEND_PRESENT=0
      target=backend
    fi

    parse_json_value "$target" || return 1
    skip_json_whitespace

    case ${JSON_TEXT:JSON_INDEX:1} in
      ',') ((JSON_INDEX += 1)); skip_json_whitespace ;;
      '}') ((JSON_INDEX += 1)); ((JSON_DEPTH -= 1)); return 0 ;;
      *) return 1 ;;
    esac
  done
}

parse_json_value() {
  local target=$1 character object_context=other

  skip_json_whitespace
  character=${JSON_TEXT:JSON_INDEX:1}

  case "$character" in
    '{')
      [[ $target == root ]] && object_context=root
      [[ $target == state ]] && object_context=state
      parse_json_object "$object_context"
      ;;
    '[') parse_json_array ;;
    '"')
      parse_json_string || return 1
      if [[ $target == backend ]]; then
        MARSHALL_BACKEND=$JSON_STRING
        MARSHALL_BACKEND_PRESENT=1
      fi
      ;;
    't')
      [[ ${JSON_TEXT:JSON_INDEX:4} == true ]] || return 1
      ((JSON_INDEX += 4))
      ;;
    'f')
      [[ ${JSON_TEXT:JSON_INDEX:5} == false ]] || return 1
      ((JSON_INDEX += 5))
      ;;
    'n')
      [[ ${JSON_TEXT:JSON_INDEX:4} == null ]] || return 1
      ((JSON_INDEX += 4))
      ;;
    '-'|[0-9]) parse_json_number ;;
    *) return 1 ;;
  esac
}

repo_uses_marshall() {
  local config_path=$1

  JSON_TEXT=''

  # Bash variables cannot contain NUL bytes. `read -d ''` returns success only
  # when it encounters one, letting us reject it rather than silently discard it.
  if IFS= read -r -d '' -n "$((MAX_CONFIG_BYTES + 1))" JSON_TEXT < "$config_path" 2>/dev/null; then
    return 1
  fi

  JSON_LENGTH=${#JSON_TEXT}
  (( JSON_LENGTH <= MAX_CONFIG_BYTES )) || return 1
  JSON_INDEX=0
  JSON_DEPTH=0
  JSON_STRING=''
  MARSHALL_BACKEND=''
  MARSHALL_BACKEND_PRESENT=0

  parse_json_value root || return 1
  skip_json_whitespace
  (( JSON_INDEX == JSON_LENGTH )) || return 1
  (( MARSHALL_BACKEND_PRESENT == 1 )) || return 1
  [[ $MARSHALL_BACKEND == srm || $MARSHALL_BACKEND == marshall ]]
}

config_path=''
directory=$PWD

while true; do
  if [[ -f $directory/.claude/release-config.json ]]; then
    config_path=$directory/.claude/release-config.json
    break
  fi

  if [[ -f $directory/.agents/release-config.json ]]; then
    config_path=$directory/.agents/release-config.json
    break
  fi

  [[ $directory == / ]] && break
  directory=${directory%/*}
  [[ -n $directory ]] || directory=/
done

[[ -n $config_path ]] || exit 0
repo_uses_marshall "$config_path" || exit 0

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Marshall release configuration detected for this repo; this hook does not verify MCP connectivity. Use $release-next to inspect startable work and verify the connection."}}'

exit 0
