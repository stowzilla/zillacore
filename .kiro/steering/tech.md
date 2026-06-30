# Tech Stack

## Language & Runtime

- Ruby 3.4+ (see `.ruby-version`)
- Packaged as a gem (`brainiac.gemspec`)
- Extensible via plugin gems (`brainiac-<name>`)

## Dependencies

| Gem | Purpose |
|-----|---------|
| sinatra ~> 4.1 | HTTP webhook receiver |
| puma ~> 7.2 | Web server |
| rackup ~> 2.3 | Rack integration |
| websocket-client-simple ~> 0.8 | Discord gateway connections |

## Dev Dependencies

| Gem | Purpose |
|-----|---------|
| minitest ~> 5.25 | Test framework |
| rake ~> 13.0 | Task runner |
| rubocop ~> 1.75 | Linter |
| rubocop-performance ~> 1.25 | Performance cops |

## Plugin Gems

Plugins are separate gems that extend Brainiac:

| Gem | Purpose |
|-----|---------|
| brainiac-whatsapp | WhatsApp Business API handler |

Plugins follow the naming convention `brainiac-<name>` and are installed via `brainiac install <name>`.

## External Tools

| Tool | Purpose |
|------|---------|
| kiro-cli | Agent dispatch (spawned as subprocess) |
| fizzy-cli | Fizzy card management |
| gh (GitHub CLI) | PR/issue operations |
| qmd | Brain semantic search and indexing |
| ngrok | Webhook tunneling |

## Common Commands

```bash
# Run tests
rake test

# Run linter
rake rubocop

# Run both (default task)
rake

# Start the server (foreground with log tailing)
brainiac server

# Start as daemon
brainiac server --daemon

# Register current directory as a project
brainiac register

# List registered projects
brainiac list

# Install a plugin
brainiac install whatsapp

# List plugins
brainiac plugins
```

## Code Style

- RuboCop enforced (see `.rubocop.yml`)
- Double quotes for strings
- No frozen string literal comments required
- Max line length: 150
- Top-level method definitions allowed (Sinatra DSL style)

## Plugin Development

Plugins are standard Ruby gems with this contract:

1. Gem named `brainiac-<name>`
2. Entry file at `lib/brainiac-<name>.rb`
3. Module at `Brainiac::Plugins::<Name>` (namespace defined in `lib/brainiac.rb`)
4. `.register(app)` method receives Sinatra app instance
5. Plugin state tracked in `~/.brainiac/plugins.json`

See `~/Code/brainiac-whatsapp` as a reference implementation.
