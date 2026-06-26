_brainiac() {
  local cur prev words cword
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  words=("${COMP_WORDS[@]}")
  cword=$COMP_CWORD

  local brainiac_dir="${BRAINIAC_DIR:-$HOME/.brainiac}"

  # Top-level commands
  local commands="server stop restart logs status register unregister list show brain discord cron provider role agent config path version help setup projects card-map"

  # Helper: list agent keys from registry
  _brainiac_agents() {
    if [[ -f "$brainiac_dir/agents.json" ]]; then
      ruby -rjson -e 'JSON.parse(File.read(ARGV[0])).each_key { |k| puts k }' "$brainiac_dir/agents.json" 2>/dev/null
    fi
  }

  # Helper: list role names from roles directory
  _brainiac_roles() {
    if [[ -d "$brainiac_dir/roles" ]]; then
      ls "$brainiac_dir/roles/"*.md 2>/dev/null | xargs -I{} basename {} .md
    fi
  }

  # Helper: list provider names
  _brainiac_providers() {
    if [[ -d "$brainiac_dir/cli-providers" ]]; then
      ls "$brainiac_dir/cli-providers/"*.json 2>/dev/null | xargs -I{} basename {} .json
    fi
  }

  # Determine position in command
  case $cword in
    1)
      COMPREPLY=($(compgen -W "$commands" -- "$cur"))
      return
      ;;
  esac

  local cmd="${words[1]}"

  case "$cmd" in
    role)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "list show create assign unassign" -- "$cur"))
          ;;
        3)
          local subcmd="${words[2]}"
          case "$subcmd" in
            assign|unassign)
              COMPREPLY=($(compgen -W "$(_brainiac_agents)" -- "$cur"))
              ;;
            show)
              COMPREPLY=($(compgen -W "$(_brainiac_roles)" -- "$cur"))
              ;;
          esac
          ;;
        4)
          local subcmd="${words[2]}"
          case "$subcmd" in
            assign|unassign)
              COMPREPLY=($(compgen -W "$(_brainiac_roles)" -- "$cur"))
              ;;
          esac
          ;;
      esac
      ;;

    agent)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "list create remove $(_brainiac_agents)" -- "$cur"))
          ;;
        3)
          local agent_name="${words[2]}"
          case "$agent_name" in
            list|remove|delete|rm) ;;
            create|add)
              COMPREPLY=($(compgen -W "--local --role --cli --persona" -- "$cur"))
              ;;
            *)
              COMPREPLY=($(compgen -W "show env" -- "$cur"))
              ;;
          esac
          ;;
        4)
          local subcmd="${words[3]}"
          if [[ "$subcmd" == "env" ]]; then
            # Suggest --delete or existing env var names for this agent
            local agent_key="${words[2]}"
            local env_keys=""
            if [[ -f "$brainiac_dir/agents.json" ]]; then
              env_keys=$(ruby -rjson -e '
                reg = JSON.parse(File.read(ARGV[0]))
                entry = reg[ARGV[1]] || reg[ARGV[1].downcase]
                (entry&.dig("env") || {}).each_key { |k| puts k }
              ' "$brainiac_dir/agents.json" "$agent_key" 2>/dev/null)
            fi
            COMPREPLY=($(compgen -W "--delete $env_keys" -- "$cur"))
          fi
          ;;
        5)
          # After --delete, suggest env var names
          if [[ "${words[3]}" == "env" && "${words[4]}" == "--delete" ]]; then
            local agent_key="${words[2]}"
            local env_keys=""
            if [[ -f "$brainiac_dir/agents.json" ]]; then
              env_keys=$(ruby -rjson -e '
                reg = JSON.parse(File.read(ARGV[0]))
                entry = reg[ARGV[1]] || reg[ARGV[1].downcase]
                (entry&.dig("env") || {}).each_key { |k| puts k }
              ' "$brainiac_dir/agents.json" "$agent_key" 2>/dev/null)
            fi
            COMPREPLY=($(compgen -W "$env_keys" -- "$cur"))
          fi
          ;;
      esac
      ;;

    provider)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "list show add" -- "$cur"))
          ;;
        3)
          local subcmd="${words[2]}"
          if [[ "$subcmd" == "show" ]]; then
            COMPREPLY=($(compgen -W "$(_brainiac_providers)" -- "$cur"))
          fi
          ;;
      esac
      ;;

    brain)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "init status search list path" -- "$cur"))
          ;;
        3)
          local subcmd="${words[2]}"
          if [[ "$subcmd" == "init" || "$subcmd" == "status" ]]; then
            COMPREPLY=($(compgen -W "$(_brainiac_agents)" -- "$cur"))
          fi
          ;;
      esac
      ;;

    discord)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "config default map owner token agents status" -- "$cur"))
          ;;
        3)
          local subcmd="${words[2]}"
          if [[ "$subcmd" == "token" ]]; then
            COMPREPLY=($(compgen -W "$(_brainiac_agents)" -- "$cur"))
          fi
          ;;
      esac
      ;;

    cron)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "add list remove enable disable update" -- "$cur"))
          ;;
      esac
      ;;

    projects)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "list default" -- "$cur"))
          ;;
      esac
      ;;
  esac
}

complete -F _brainiac brainiac
