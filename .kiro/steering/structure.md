# Project Structure

```
brainiac/
├── receiver.rb              # Entry point — Sinatra app with all webhook routes and API endpoints
├── lib/
│   ├── brainiac.rb          # Module loader (requires all core modules)
│   ├── user_registry.rb     # Cross-platform user identity management
│   └── brainiac/
│       ├── version.rb       # Brainiac::VERSION constant
│       ├── config.rb        # Environment, paths, constants, project/config loading
│       ├── agents.rb        # Agent registry, discovery, dispatch logic
│       ├── brain.rb         # Long-term memory: qmd queries, context building, git sync
│       ├── cron.rb          # Scheduled agent jobs
│       ├── helpers.rb       # Shared utility functions
│       ├── planning.rb      # Planning mode (Q&A → plan → Fizzy steps)
│       ├── plugins.rb       # Gem-based plugin discovery, loading, lifecycle
│       ├── prompts.rb       # Prompt construction for agent dispatch
│       ├── restart.rb       # Self-restart after brainiac repo changes
│       ├── sessions.rb      # Active session tracking, supersede, kill
│       ├── skills.rb        # Skill index and auto-injection
│       ├── users.rb         # User lookup and identity resolution
│       └── handlers/
│           ├── discord.rb   # Discord bot gateway, message handling, REST API
│           ├── discord/     # Discord sub-modules (delivery, threads, etc.)
│           ├── fizzy.rb     # Fizzy webhook event handling
│           ├── fizzy/       # Fizzy sub-modules (card_index, deployments)
│           ├── github.rb    # GitHub webhook event handling
│           ├── shared/      # Shared handler logic (git, inline_tags)
│           └── zoho.rb      # Zoho Mail webhook handling
├── bin/                     # CLI executable (brainiac command)
├── monitor/                 # Status bar integrations (waybar, xbar, menubar)
├── templates/               # Example config files for ~/.brainiac/ setup
├── test/                    # Minitest test files (test_*.rb pattern)
├── tmp/                     # Agent session logs (gitignored)
├── docs/                    # Documentation
└── certs/                   # Gem signing certificate
```

## Architecture Pattern

- **Flat module system**: All core logic lives as top-level methods in `lib/brainiac/*.rb` files (Sinatra DSL style, no classes)
- **Thin entry point**: `receiver.rb` defines routes and wires everything together
- **Handler pattern**: Each integration (Fizzy, GitHub, Discord, Zoho) has its own handler file
- **Plugin system**: External handlers distributed as gems (`brainiac-<name>`) are discovered and loaded at startup via `lib/brainiac/plugins.rb`
- **Config reloading**: JSON configs at `~/.brainiac/` are checked for mtime changes and reloaded on each webhook
- **Thread-based concurrency**: Discord bots, cron, plugins, and background tasks run as Ruby threads within the same process

## Plugin Architecture

Plugins are Ruby gems named `brainiac-<name>`. They define `Brainiac::Plugins::<Name>.register(app)` which receives the Sinatra app instance and can define routes, start threads, and access all core modules. Plugins are loaded after built-in handlers in `receiver.rb`.

Plugin state is tracked in `~/.brainiac/plugins.json` (separate from brainiac.json). The `load_plugins!` function in `plugins.rb` iterates installed plugins and calls `.register(app)` on each.

Loading order in receiver.rb:
1. Core modules (`lib/brainiac/*.rb`)
2. Shared handler utilities (`handlers/shared/`)
3. Built-in handlers (fizzy, github, discord, zoho) — conditional on `handler_enabled?`
4. Custom drop-in handlers (`~/.brainiac/handlers/*.rb`)
5. Gem-based plugins (`brainiac-*` gems via `load_plugins!(self)`)

## Runtime Config Location

All runtime configuration lives in `~/.brainiac/` (not in the repo). The repo's `templates/` directory has example configs. Brain data lives at `~/.brainiac/brain/`.
