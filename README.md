# Brainiac

A webhook receiver that listens for [Fizzy](https://fizzy.do), GitHub, Discord, and Zoho Mail events, then dispatches work to AI agent CLIs. Each agent has its own persona, brain, and voice — they collaborate on the same projects through @mentions.

## How It Works

Webhook events trigger the receiver to spawn an AI agent CLI with a natural language prompt. The receiver can dispatch multiple agents — each with a unique personality and kiro-cli config. Agents are discovered from `~/.kiro/agents/`, and projects registered in `~/.brainiac/projects.json`. Config reloads dynamically, no restart needed.

### Events

| Source    | Event               | What Happens                                                                                      |
| --------- | ------------------- | ------------------------------------------------------------------------------------------------- |
| Fizzy     | Card assigned       | Creates worktree, maps card to branch, spawns assigned agent                                      |
| Fizzy     | Card published      | Duplicate detection via trigram similarity + semantic search                                       |
| Fizzy     | @mention in comment | Routes to the mentioned agent (even on another agent's card)                                      |
| Fizzy     | Follow-up comment   | Runs card's assigned agent in existing worktree                                                   |
| GitHub    | PR review submitted | Agent addresses review feedback                                                                   |
| GitHub    | PR comment          | Agent responds to PR feedback                                                                     |
| GitHub    | PR merged to main   | Comments PR link on Fizzy card, closes card, cleans up worktree                                   |
| GitHub    | Issue opened        | Logged for tracking (no agent dispatch)                                                           |
| GitHub    | Workflow run        | Notifies on CI failures via Discord                                                               |
| Discord   | @bot mention        | Each agent has its own bot — @mention routes directly to that agent, no worktree — conversational |
| Zoho Mail | Incoming email      | Rule-based matching, notifies via Discord                                                         |

### Inline Tags

All four channels support inline tags in message/comment text. Tags are stripped before reaching the agent prompt.

| Tag                                                                           | Fizzy | Discord | GitHub | Description                                                                                           |
| ----------------------------------------------------------------------------- | ----- | ------- | ------ | ----------------------------------------------------------------------------------------------------- |
| `[project:XYZ]`                                                               | —     | ✓       | —      | Override which project the agent works in (Discord only — Fizzy uses card tags, GitHub uses the repo) |
| `[opus]` `[sonnet]` `[haiku]` `[deepseek]` `[minimax]` `[minimax21]` `[qwen]` | ✓     | ✓       | ✓      | Override the model for this dispatch                                                                  |
| `[worktree:branch-name]`                                                      | ✓     | —       | —      | Direct the agent to a specific worktree instead of the card's default                                 |
| `[plan]`                                                                      | ✓     | ✓       | —      | Activate planning mode — agent gathers requirements before coding                                     |

Model keys come from the project's `allowed_models` config. Fizzy also supports model selection via card tags (e.g. adding an `opus` tag to the card).

### Planning Mode

Add a `[plan]` tag to a Discord message or a `plan` tag to a Fizzy card to activate planning mode. Instead of jumping straight into implementation, the agent:

1. Asks clarifying questions to understand the problem, constraints, and desired outcome
2. Logs Q&A to its memory file for continuity across sessions
3. Generates a plan markdown file at `~/.brainiac/plans/card-<id>-plan.md`
4. Automatically creates Fizzy steps from the task breakdown

The agent stays read-only during planning — no code changes, no commits. Once the plan is finalized, the system creates Fizzy steps from each `### Task N: Title` heading in the plan file.

### Cross-Agent Mentions

Any agent can be tagged on any card. If Kaylee is working card #42 and someone comments "@Galen what do you think?", Galen reviews the card and PR without touching Kaylee's worktree. This enables patterns like:

- Engineer agent does the work, security agent reviews it
- One agent asks another for a second opinion
- A read-only agent (e.g. GLaDOS) that reviews and comments but doesn't take over the card

#### Display Name Accuracy

Agents need to spell @mentions exactly as they appear in Fizzy (e.g. `@GLaDOS` not `@glados`). The agent registry's `fizzy_name` field handles this — every prompt includes an agent roster with the correct spelling:

```
## Agent Roster
When @mentioning other agents in Fizzy comments, use the EXACT spelling below.
  - @Galen
  - @GLaDOS
  - @Kaylee
```

Detection is case-insensitive (inbound `@glados` still matches GLaDOS), but outbound mentions use the exact `fizzy_name` from the registry.

#### Agent-to-Agent Loop Prevention

When agents can tag each other, infinite loops become possible (Galen tags GLaDOS, GLaDOS tags Galen back, forever). Brainiac prevents this with layered defenses:

1. **Dispatch depth limit** — a per-card counter tracks agent-to-agent hops since the last human comment. Default max depth is 10: Human → Agent A → Agent B → ... is allowed up to the limit. The counter resets when a human comments on the card, and expires after 1 hour of no human activity.

2. **Prompt instruction** — cross-agent review prompts explicitly tell the dispatched agent not to @mention other agents. It can suggest involving someone in plain text, but not with `@Agent` syntax.

3. **Existing defenses** — `session_active?` prevents concurrent runs on the same card, `COMMENT_COOLDOWN` (60s) suppresses rapid-fire triggers, and self-comment filtering prevents an agent from triggering itself.

Tuning knobs in `lib/brainiac/sessions.rb`:

- `AGENT_DISPATCH_MAX_DEPTH` — max agent-to-agent hops (default: 10)
- `AGENT_DISPATCH_WINDOW` — seconds before depth resets without human activity (default: 3600)
- `GET /api/dispatch-depth` — debug endpoint showing current depth state per card

### Card Context Pre-Fetching

Before dispatching an agent, Brainiac pre-fetches the Fizzy card body and last 5 comments, injecting them directly into the prompt. This means agents don't need to make separate API calls to read the card — the context is already there. Results are cached for 60 seconds to avoid redundant fetches on rapid-fire triggers.

### Card Duplicate Detection

When a card is published or triaged, Brainiac checks for potential duplicates using two methods:

1. **Trigram similarity** — compares the new card's title against all indexed card titles using character trigram overlap
2. **Semantic search** — uses qmd to find cards with similar meaning, even if the wording differs

If matches are found above the similarity threshold, Brainiac posts a comment on the card listing the potential duplicates. The card index is stored at `~/.brainiac/card_index.json` and reindexed periodically via qmd.

### Pre-Post Comment Check

Before posting a response, agents re-fetch the source (Fizzy card comments or GitHub PR comments) to catch any new messages that arrived while they were working. If a human added context, changed requirements, or asked for adjustments mid-session, the agent incorporates that before posting — avoiding stale or outdated responses.

This applies to Fizzy and GitHub channels. Discord uses a different mechanism (session supersede) where follow-up messages within 60 seconds kill the previous run and restart with updated context.

### Pre-Comment Reflection

Before writing any comment, agents go through a mandatory reflection ritual:

1. React with 🧠 to signal reflection
2. Query their persona collection for communication style and the triggering user
3. Decide whether persona or knowledge needs updating
4. Update brain files (or consciously skip) and run `qmd update`
5. React with a situational emoji (🎉, 💪, 🤔, 😅, 🔥, etc.)
6. Write the comment in their unique voice

This compounds over dozens of sessions into a rich understanding of each person and codebase.

## Setup

### Installation

```bash
gem install brainiac
```

This installs the `brainiac` binary to your gem bin path (just like `rails`, `rspec`, etc.). Ensure your gem bin directory is on your `PATH` — it typically is if you're using a Ruby version manager.

### Quick Start (New Machine)

After installing the gem:

```bash
brainiac setup
```

This creates the `~/.brainiac/` directory structure and copies example config files. Then edit the configs with your actual secrets and IDs (see below).

### Prerequisites

| Dependency | Required | Install |
|------------|----------|---------|
| Ruby 3.4+ | Yes | [mise](https://mise.jdx.dev), rbenv, or system |
| [Kiro CLI](https://kiro.dev) | Yes | Agent dispatch |
| [Fizzy CLI](https://github.com/robzolkos/fizzy-cli) | For Fizzy | Card management |
| [GitHub CLI](https://cli.github.com) (`gh`) | For GitHub | PR/issue operations |
| [ngrok](https://ngrok.com) | Yes | Webhook tunneling |
| [qmd](https://github.com/tobi/qmd) | For brain | `npm install -g @tobilu/qmd` (Node.js >= 22) |
| [gum](https://github.com/charmbracelet/gum) | Optional | Manual worktree cleanup |

### Directory Structure

After setup, `~/.brainiac/` looks like:

```
~/.brainiac/
├── agents.json          # Agent registry (tokens, display names, local flag)
├── projects.json        # Registered projects
├── github.json          # GitHub webhook secret
├── fizzy.json           # Fizzy board config, authorized users
├── discord.json         # Discord channel mappings, auth
├── users.json           # Cross-platform user identity registry
├── zoho.json            # Zoho Mail rules (optional)
├── brain/
│   ├── knowledge/       # Shared technical knowledge (all agents)
│   ├── persona/         # Per-agent personality files
│   └── memory/          # Per-agent session memory
├── handlers/            # Custom webhook handlers (plugin system)
├── plans/               # Planning mode output
└── tmp/                 # Temp files, drafts, posted responses
```

### Step-by-Step Configuration

#### 1. Agent Registry (`~/.brainiac/agents.json`)

Maps agents to their identity and environment. Every agent that should dispatch on this machine needs an entry here with `"local": true`:

```json
{
  "galen": {
    "fizzy_name": "Galen",
    "local": true,
    "env": {
      "FIZZY_TOKEN": "fizzy_abc...",
      "DISCORD_BOT_TOKEN": "Bot_abc..."
    }
  }
}
```

See [Multi-Agent Setup](#multi-agent-setup) for full details.

#### 2. Kiro Agent Configs (`~/.kiro/agents/<name>.json`)

Each agent also needs a kiro-cli config. The filename becomes the agent name:

```bash
kiro-cli agent create    # Interactive
# Or manually create ~/.kiro/agents/galen.json
```

#### 3. GitHub (`~/.brainiac/github.json`)

```json
{
  "webhook_secret": "your-github-webhook-secret",
  "repos": {}
}
```

The `webhook_secret` verifies incoming GitHub webhook requests. Generate one with `ruby -rsecurerandom -e 'puts SecureRandom.hex(20)'`.

**Legacy:** `GITHUB_WEBHOOK_SECRET` env var works as fallback.

#### 4. Fizzy (`~/.brainiac/fizzy.json`)

Defines authorized users, flags humans, and configures boards:

```json
{
  "authorized_users": [
    { "id": "user-id-1", "name": "Andy", "human": true },
    { "id": "user-id-2", "name": "Adam", "human": true },
    { "id": "agent-id-1", "name": "Galen", "human": false }
  ],
  "boards": {
    "development": {
      "board_id": "your-board-id",
      "webhook_secret": "secret-for-this-board",
      "columns": {
        "right_now": "column-id",
        "needs_review": "column-id",
        "uat": "column-id"
      }
    }
  }
}
```

Each board gets its own webhook secret and column IDs. The board key (e.g., `development`) is used in the webhook URL.

When a human is @mentioned on a card assigned to an agent, the agent will skip that comment — allowing human-to-human conversation without agent interference.

**Legacy:** `FIZZY_WEBHOOK_SECRET` and `AUTHORIZED_USER_IDS` env vars work as fallbacks.

#### 5. Environment Variables

Most config lives in JSON files now. The only env var you might want:

```bash
export AI_AGENT_NAME="Galen"  # Defaults to Galen (Linux) or Kaylee (macOS)
```

#### 6. Register Projects

```bash
cd ~/Code/marketplace && brainiac register
cd ~/Code/brainiac && brainiac register
brainiac list
```

The CLI prompts for project key, Fizzy tags, GitHub repo, and agent CLI settings.

Set a default project (used as fallback when no tags match):

```bash
brainiac projects default myproject
```

#### 7. Initialize Brain

```bash
brainiac brain init Galen
```

This creates the directory structure, sets up qmd collections, and indexes everything.

#### 8. Configure Webhooks

**Fizzy:** Board settings → Webhooks → URL: `https://your-ngrok.ngrok-free.app/fizzy/development` (where `development` is the board key from `fizzy.json`), Secret: the board's `webhook_secret`

**GitHub:** Repo settings → Webhooks → URL: `https://your-ngrok.ngrok-free.app/github`, Content type: `application/json`, Secret: from `github.json`, Events: Pull requests, Pull request reviews, Issue comments, Issues

#### 9. Start

```bash
brainiac server    # Start and tail logs (Ctrl+C to detach, server keeps running)
ngrok http 4567     # Terminal 2
```

## Multi-Agent Setup

This is the core of Brainiac. Each machine runs one receiver that can dispatch multiple agents.

### Architecture

```
Andy's Linux box                    Adam's macOS
┌─────────────────────┐            ┌─────────────────────┐
│ brainiac server     │            │ brainiac server     │
│                      │            │                      │
│ ~/.kiro/agents/:     │            │ ~/.kiro/agents/:     │
│   galen.json         │            │   kaylee.json        │
│   glados.json        │            │   jane.json          │
│                      │            │                      │
│ ~/.brainiac/        │            │ ~/.brainiac/        │
│   agents.json        │            │   agents.json        │
└─────────────────────┘            └─────────────────────┘
         │                                   │
         └──── same Fizzy board + GitHub ────┘
```

Both machines receive the same webhooks. The receiver discovers available agents by scanning `~/.kiro/agents/*.json` — only agents with a config on that machine will be dispatched, preventing duplicates.

### Step 1: Create Kiro CLI Agent Configs

Each agent needs a kiro-cli config at `~/.kiro/agents/<name>.json`. This is the only registry — no separate config file needed.

```bash
kiro-cli agent create    # Interactive
# Or manually create ~/.kiro/agents/galen.json, ~/.kiro/agents/glados.json
```

The receiver scans this directory to discover which agents it can dispatch. The filename becomes the agent name (e.g. `galen.json` → Galen). Tool permissions, model, and resources are all defined in the kiro-cli config.

### Step 2: Agent Registry

The agent registry at `~/.brainiac/agents.json` maps each agent to its identity and environment. This serves four purposes:

1. **Per-agent environment variables** — any env var can be set per-agent via the `env` hash (e.g. `FIZZY_TOKEN`, `DISCORD_BOT_TOKEN`, custom vars)
2. **Display name mapping** — agents know the exact spelling for @mentions (e.g. `GLaDOS` not `glados`)
3. **Discord bot tokens** — agents with `DISCORD_BOT_TOKEN` in their env get their own Discord bot
4. **Local flag** — agents marked `"local": true` pick up card assignments on this machine

```json
{
  "galen": {
    "fizzy_name": "Galen",
    "local": true,
    "env": {
      "FIZZY_TOKEN": "fizzy_abc...",
      "DISCORD_BOT_TOKEN": "Bot_abc..."
    }
  },
  "glados": {
    "fizzy_name": "GLaDOS",
    "env": {
      "FIZZY_TOKEN": "fizzy_xyz...",
      "DISCORD_BOT_TOKEN": "Bot_xyz..."
    }
  },
  "kaylee": {
    "fizzy_name": "Kaylee"
  }
}
```

Keys are lowercase lookup keys (normalized: non-alphanumeric chars become hyphens). `fizzy_name` is the exact Fizzy account display name. The `env` hash is injected into the spawned agent process — every key/value pair becomes an environment variable.

The `local` flag controls which agents pick up card assignments on this machine. Agents without `"local": true` are still known for mention detection, display names, tokens, and cross-agent interactions — they just won't pick up card assignments. Agents discovered from `~/.kiro/agents/` configs and the default `AI_AGENT_NAME` are always considered local.

Agents without an `env` block (like Kaylee above on a Linux box) still appear in the agent roster so local agents spell @mentions correctly.

A legacy format with top-level `fizzy_token` / `discord_bot_token` keys is auto-migrated into the `env` hash at load time. A legacy `~/.brainiac/agent_tokens.json` format (flat `{ "galen": "token" }`) is supported as a fallback and auto-migrated.

The registry reloads on every webhook and via `POST /api/reload`.

### Step 3: Seed Agent Persona and Knowledge

Agents get their personality from persona files and their technical context from knowledge files. These live in the brain directory and are indexed by qmd for semantic search.

#### Persona

Each agent needs at least one persona file. Create it directly in the brain:

```bash
# Create persona file for your agent
mkdir -p ~/.brainiac/brain/persona/galen
cat > ~/.brainiac/brain/persona/galen/style.md << 'EOF'
---
name: galen-persona
description: Persona voice for Galen.
---
# Galen — Persona
Gruff, no-nonsense, direct, practical, a little cynical. Zero corporate fluff.
Keep responses tight and technical.
EOF

# Index it
qmd update
```

The persona only affects comments — agents do their actual work (coding, debugging, etc.) without any persona influence.

#### Knowledge

Shared knowledge goes in `~/.brainiac/brain/knowledge/`. This is where you put project conventions, tool docs, coding patterns — anything all agents should know:

```bash
mkdir -p ~/.brainiac/brain/knowledge/tools
cat > ~/.brainiac/brain/knowledge/tools/fizzy.md << 'EOF'
# Fizzy CLI Reference
fizzy card list — list cards
fizzy comment create --card 123 --body "<p>Hello</p>" — post a comment
EOF

qmd update
```

Agents also update knowledge themselves during sessions (when they learn something significant), but seeding it with your project's conventions and tool docs gives them a head start.

### Step 4: Initialize Each Agent's Brain

```bash
brainiac brain init              # Default agent (Galen on Linux, Kaylee on macOS)
brainiac brain init SecurityBot  # Additional agent
brainiac brain list              # Verify all agents
```

This creates the directory structure, sets up qmd collections, and indexes everything. Run this after you've placed your persona and knowledge files.

### How Dispatch Works

When a webhook arrives:

1. **Card assigned** — the receiver checks if any assignee matches a local agent name. Only agents marked `local` (or discovered from `~/.kiro/agents/`) pick up assignments — this prevents multiple machines from dispatching the same card.
2. **@mention in comment** — the receiver detects which agent is mentioned (e.g. `@Galen`, `@SecurityBot`). If the mentioned agent differs from the card's assigned agent, it's a cross-agent review — the mentioned agent reviews without a worktree. Non-local agent mentions are ignored.
3. **Follow-up comment (no mention)** — the card's assigned agent handles it.

The command dispatched looks like:

```bash
kiro-cli --agent galen chat --trust-all-tools --no-interactive
```

The `--agent` flag goes before the `chat` subcommand, pointing kiro-cli to the agent's config.

## Brain (Long-Term Memory)

Agents have persistent memory powered by [qmd](https://github.com/tobi/qmd):

| Part      | Location                              | Scope                     | Purpose                                                     |
| --------- | ------------------------------------- | ------------------------- | ----------------------------------------------------------- |
| Knowledge | `~/.brainiac/brain/knowledge/`       | Shared across all agents  | Project conventions, patterns, architecture decisions       |
| Memory    | `~/.brainiac/brain/memory/<agent>/`  | Per-agent, per-card files | Session history — decisions, questions, work status         |
| Persona   | `~/.brainiac/brain/persona/<agent>/` | Per-agent                 | Communication style, tone — only used when writing comments |

Each part gets its own qmd collection:

- `brainiac-knowledge` — shared knowledge
- `galen-memory`, `kaylee-memory` — per-agent card memory
- `galen-persona`, `kaylee-persona` — per-agent persona

Knowledge is automatically queried and injected into every prompt. Memory is read/written at the start/end of each session. Persona stays out of work context — agents only query it during pre-comment reflection.

After every agent session completes, `qmd update` runs automatically as a safety net (agents are told to do this themselves, but don't always remember).

To seed the brain, create markdown files directly in the appropriate directories and run `qmd update`. See the [Multi-Agent Setup](#multi-agent-setup) section for examples.

### Git Sync

The brain directory (`~/.brainiac/brain/`) can be backed up as a git repo. If a `.git` directory is detected inside the brain, Brainiac automatically syncs:

- **Pull** at the start of every session (before building brain context), with a 30-second debounce to avoid hammering on rapid-fire triggers
- **Push** after every agent session completes (Fizzy, GitHub, and Discord)

This keeps brains in sync across machines. If your co-founder runs their own brainiac with different agents, both machines share the same knowledge and memory through the repo.

```bash
cd ~/.brainiac/brain
git init
git remote add origin git@github.com:yourorg/brainiac-brain.git
git add -A && git commit -m "initial brain" && git push -u origin main
```

Conflicts are handled with `git pull --rebase --autostash`. If a rebase fails (rare — the files are markdown), it aborts cleanly and logs a warning. The push retries up to 3 times with exponential backoff.

## Discord Bot

Each agent gets its own Discord bot. Users @mention @Galen or @GLaDOS directly in Discord — no shared bot, no agent name detection needed. No Fizzy card or worktree is created; the agent runs in the project's repo for read-only exploration, brain queries, and knowledge/persona updates.

All Discord bots run inside `brainiac server` as background threads — no separate processes to manage.

### Session Supersede

When a human sends a follow-up message within 60 seconds of triggering an agent, Brainiac kills the previous agent run and starts a new one with the updated context. This lets you correct typos or add context without waiting for the first run to finish. Draft files from the superseded session are cleaned up so stale responses are never delivered.

### Cancelling Agent Sessions

React with ❌ to any message that triggered an agent to immediately terminate that session:

1. User @mentions an agent → agent reacts with 👀 and starts working
2. User reacts with ❌ on that same message
3. Agent process is killed (SIGKILL)
4. Session removed from active sessions
5. Reactions update: 👀 → 🛑

### Setup

#### Step 1: Create Discord Applications

Create one Discord application per agent at https://discord.com/developers/applications:

1. Click "New Application", name it after the agent (e.g. "Galen", "GLaDOS")
2. Go to the "Bot" tab in the left sidebar
3. Under "Privileged Gateway Intents", enable **Message Content Intent** — this is required for the bot to read message text. Without it, all message content arrives as empty strings.
4. Optionally uncheck "Public Bot" if you don't want others to invite your bots

Repeat for each agent that needs a Discord bot.

#### Step 2: Generate Bot Tokens

Still on the "Bot" tab for each application:

1. Click "Reset Token" (or "Copy" if the token is still visible)
2. Copy the token immediately — Discord only shows it once
3. Store it somewhere safe temporarily

Register each token with Brainiac:

```bash
brainiac discord token galen "BOT_TOKEN_FOR_GALEN"
brainiac discord token glados "BOT_TOKEN_FOR_GLADOS"
```

This adds `DISCORD_BOT_TOKEN` to the agent's `env` hash in `~/.brainiac/agents.json`. You can verify with:

```bash
brainiac discord agents
```

#### Step 3: Invite Bots to Your Server

Go to the "OAuth2" tab for each application:

1. Under "OAuth2 URL Generator", check the **bot** scope
2. Under "Bot Permissions", select:
   - Send Messages
   - Create Public Threads
   - Send Messages in Threads
   - Add Reactions
   - Read Message History
3. Copy the generated URL and open it in your browser
4. Select your server and authorize

The permission integer for these permissions is `326417591296`. You can also construct the invite URL manually:

```
https://discord.com/oauth2/authorize?client_id=YOUR_APP_ID&scope=bot&permissions=326417591296
```

Replace `YOUR_APP_ID` with the Application ID from the "General Information" tab. Repeat for each agent bot.

#### Step 4: Configure Project Mapping

Set a default project so bots know which repo to work in:

```bash
brainiac discord default marketplace
```

Optionally map specific channels to different projects:

```bash
brainiac discord map 1234567890 brainiac
```

To get a channel ID, enable Developer Mode in Discord (User Settings → Advanced → Developer Mode), then right-click a channel and "Copy Channel ID".

#### Step 5: Start the Server

```bash
brainiac server
```

All bots connect automatically as background threads. Check they're online:

```bash
brainiac discord status
```

You should see each bot listed as `connected` with a `user_id`. If a bot shows `error` or `disconnected`, double-check the token and that the Message Content intent is enabled.

### How It Works

When someone @mentions an agent's bot in Discord:

1. The bot reacts with 👀 — the agent identity comes from the bot itself, no detection needed
2. Dispatches the agent with a conversational prompt — no card, no worktree
3. The agent can read project files, search the brain, and update knowledge/persona
4. The agent writes its response to a temp file
5. The bot creates a thread off your message (named after the agent and your question) and posts the response there
6. Follow-up @mentions inside the thread continue the conversation in-thread

Use `[project:XYZ]` to target a specific project and `[opus]`/`[sonnet]`/`[haiku]` to override the model:

```
@Galen [project:brainiac] [opus] how does the webhook signature verification work?
```

Tags are stripped from the prompt — the agent only sees the question.

### Response Delivery

Agents write responses to draft files in `~/.brainiac/tmp/discord/draft/`. A background poller thread checks for completed drafts every 10 seconds and delivers them to Discord. Each draft has a `.meta.json` sidecar with delivery metadata (channel ID, agent, thread info). After successful posting, both files move to `~/.brainiac/tmp/discord/posted/`. This file-based approach survives server restarts — orphaned drafts are recovered by the poller.

### Forum Channel Support

Cron jobs targeting a Discord forum channel automatically create new forum posts instead of regular messages. The forum post title defaults to `<Agent> — <Date>` but can be customized with the `-t` flag on `brainiac cron add`.

### Configuration

Channel mappings and authorization are stored in `~/.brainiac/discord.json`:

```json
{
  "default_project": "marketplace",
  "owner_discord_id": "YOUR_DISCORD_USER_ID",
  "dashboard_token": "optional-token-for-web-dashboard",
  "channel_mappings": {
    "0987654321": { "project": "brainiac" }
  },
  "user_mappings": {
    "Andy": "123456789012345678",
    "Adam": "234567890123456789",
    "Kaylee": "345678901234567890"
  },
  "authorized_role_ids": ["role-id"],
  "authorized_user_ids": ["user-id"],
  "giphy_api_key": "your-giphy-api-key"
}
```

`default_project` applies to any channel without a specific mapping. Channel mappings are optional overrides for when you want a specific channel tied to a specific project.

`owner_discord_id` identifies the server owner for admin-level notifications.

`dashboard_token` protects the web dashboard at `/dashboard`. If set, requests must include this token to access the dashboard.

`user_mappings` maps display names to Discord user IDs. This serves two purposes: agents use it to format proper `<@ID>` mentions (plain text `@Name` doesn't work in Discord), and the bot recognition system uses it to identify remote agent bots running on other machines. Add humans, remote agents, and anyone else the agents might need to mention. Get IDs by enabling Developer Mode in Discord and right-clicking a user.

Leave `authorized_role_ids` and `authorized_user_ids` empty to allow everyone in the server. Add IDs to restrict who can trigger agents.

`giphy_api_key` enables GIF support — agents can optionally include GIFs in conversational Discord responses. Get a free API key from [GIPHY Developers](https://developers.giphy.com/). Agents search via `GET /api/gif?q=search+terms` and paste the returned URL into their response; Discord auto-embeds it.

### CLI Commands

```bash
brainiac discord token <agent> <token>        # Set Discord bot token for an agent
brainiac discord agents                       # List agents with Discord bot tokens
brainiac discord default <project>            # Set default project for all channels
brainiac discord map <channel-id> <project>   # Override for a specific channel
brainiac discord config                       # Show current Discord config
brainiac discord status                       # Check bot status via server API
```

## Cron (Scheduled Tasks)

Agents can be dispatched on a schedule — daily standups, weekly summaries, periodic code reviews, whatever you want. Jobs are stored in `~/.brainiac/cron.json` and run in a background thread inside `brainiac server`.

Supports both recurring schedules (standard cron) and one-time scheduled tasks (natural language or ISO8601 timestamps).

Cron jobs can run in two modes:

1. **Agent mode** (default) — dispatches an agent with a prompt
2. **Script mode** — runs a script directly without an agent, output goes to Discord

### Adding a Job

```bash
# Agent mode (recurring schedules)
brainiac cron add -s "0 9 * * 1-5" -p marketplace "Summarize open cards and post a standup update"
brainiac cron add -s "@daily" -p brainiac -a Galen "Review recent commits and flag anything that needs attention"
brainiac cron add -s "0 17 * * 5" -p marketplace -d 1234567890 "Post a weekly summary to Discord"

# Script mode (no agent, direct execution)
brainiac cron add -s "0 8 * * 1-5" -p brainiac --script ~/.brainiac/scripts/daily-report.sh -d 1234567890

# One-time schedules (natural language)
brainiac cron add -s "tomorrow at 9am" -p marketplace "Reminder about priorities"
brainiac cron add -s "in 2 hours" -p brainiac "Follow up on PR review"
brainiac cron add -s "next monday at 3pm" -p marketplace "Weekly planning session"

# One-time schedules (ISO8601)
brainiac cron add -s "2026-02-27T09:00:00-05:00" -p marketplace "Specific deadline reminder"

# Recurring with repeat limit
brainiac cron add -s "0 9 * * *" -r 7 -p marketplace "Daily reminder for 7 days"

# Discord forum channel posting
brainiac cron add -s "@daily" -p marketplace -d 1234567890 -t "Daily Standup" "Post standup"
```

Flags:

- `-s` / `--schedule` — cron expression, shorthand, natural language, or ISO8601 timestamp
- `-p` / `--project` — project key (required)
- `-a` / `--agent` — agent name (defaults to `$AI_AGENT_NAME`, ignored in script mode)
- `-m` / `--model` — model override (`opus`, `sonnet`, `haiku`, `auto`, ignored in script mode)
- `-d` / `--discord` — Discord channel ID to post the response to
- `-t` / `--title` — forum post title (for forum channels)
- `-r` / `--repeat` — number of times to repeat (auto-disables after limit)
- `--script` — path to script (enables script mode, mutually exclusive with prompt)

### Script Mode

Script mode runs a script directly without dispatching an agent. This is useful for:

- Token savings (no LLM calls)
- Simple data aggregation and reporting
- Running existing shell scripts on a schedule

Requirements:

- Script must be executable (`chmod +x script.sh`)
- Script output (stdout) is captured and posted to Discord if `-d` is set
- Script runs in the project's repo directory
- No agent prompt or model selection needed

Example script (`~/.brainiac/scripts/daily-report.sh`):

```bash
#!/bin/bash
echo "=== Daily Report ==="
fizzy card list --column done --all --pretty | jq -r '.data[] | "[#\(.number)] \(.title)"'
```

### Managing Jobs

```bash
brainiac cron list             # List all jobs with status and last run time
brainiac cron remove <id>      # Remove a job
brainiac cron enable <id>      # Enable a paused job
brainiac cron disable <id>     # Pause a job without removing it
brainiac cron update <id> -s "42 13 * * 1-5"           # Update schedule
brainiac cron update <id> -c "1234567890"               # Update Discord channel
brainiac cron update <id> -t "New Title"                # Update forum title
```

### Schedule Format

**Recurring (standard cron):**

```
0 9 * * 1-5    # 9am weekdays
0 */4 * * *    # Every 4 hours
0 0 1 * *      # First of every month
@daily         # Midnight every day
@weekly        # Midnight every Sunday
```

**One-time (natural language):**

```
tomorrow at 9am
in 30 minutes
in 2 hours
next monday at 3pm
```

**One-time (ISO8601):**

```
2026-02-27T09:00:00-05:00
```

One-time jobs are automatically disabled after execution. They remain in the job list with a `[COMPLETED]` marker and can be removed manually. Repeat-limited jobs auto-disable after reaching their execution count.

### Discord Output

If `-d <channel-id>` is set, the output is posted to that Discord channel:

- **Agent mode**: Agent writes response to temp file, posted using agent's bot identity
- **Script mode**: Script stdout is captured and posted directly

If the target channel is a forum channel, a new forum post is created with a customizable title.

## Web Dashboard

Brainiac includes a web dashboard at `http://localhost:4567/dashboard` that shows active agent sessions, project status, and system health. Protected by a `dashboard_token` configured in `~/.brainiac/discord.json`.

## Monitoring

Brainiac includes a monitoring system that shows active agent sessions in your desktop status bar. A background daemon polls the server API and exposes state via a Unix socket that status bar plugins read from.

### How It Works

```
brainiac server → /api/status → monitor/daemon.rb → /tmp/brainiac-monitor.sock → xbar/waybar plugin
```

The monitor daemon starts automatically with `brainiac server`. It polls `/api/status` every 2 seconds and serves the current state to any client connecting to the Unix socket.

### Agent Display Config

Configure how agents appear in the status bar via `~/.brainiac/waybar.json`:

```json
{
  "agents": [
    { "name": "Galen", "emoji": "🛠️", "color": "green" },
    { "name": "GLaDOS", "emoji": "🤖", "color": "blue" },
    { "name": "Kaylee", "emoji": "🔧", "color": "pink" }
  ],
  "default_emoji": "❓",
  "schema_version": "1.0"
}
```

### macOS (xbar)

Requires [xbar](https://xbarapp.com) (free, formerly BitBar).

```bash
ruby monitor/setup-xbar-plugin.rb     # One-time setup (symlinks plugin)
# Restart xbar to activate
```

When agents are active, their emojis appear in the menu bar. Click to see details (agent name, card/Discord context, elapsed time) and open log files.

### Linux (Waybar)

```bash
ruby monitor/setup-waybar-module.rb   # One-time setup
omarchy restart waybar                 # Restart waybar
```

See `docs/waybar-config.md` for detailed configuration.

## User Identity Registry

Brainiac maintains a centralized user identity registry at `~/.brainiac/users.json` that resolves identities across platforms (Discord, GitHub, Fizzy). This ensures agents know who they're talking to regardless of where the interaction happens.

### Structure

```json
{
  "users": [
    {
      "canonical_name": "Adam Dalton",
      "identities": {
        "discord": { "username": "fladamd", "user_id": "832331260088287242" },
        "github": { "username": "dalton" },
        "fizzy": { "username": "adam-dalton" }
      },
      "aliases": ["Andy"],
      "notes": "Primary user"
    }
  ],
  "schema_version": "1.0"
}
```

### Usage

```ruby
# Find by any identifier
user = find_user('fladamd')
name = canonical_name_for('fladamd')  # => "Adam Dalton"

# Filter by type
humans = human_users
agents = ai_agents
```

**API:**

```bash
curl http://localhost:4567/api/users                    # All users
curl http://localhost:4567/api/users?filter=humans      # Humans only
curl http://localhost:4567/api/users?filter=agents      # AI agents only
curl http://localhost:4567/api/users/fladamd            # Find by identifier
```

The registry reloads automatically on every webhook and via `POST /api/reload`.

## Worktree Management

When a card is assigned, Brainiac creates a git worktree for the agent to work in. Two config files in the project root control how gitignored files are handled:

- **`.worktreeinclude`** — glob patterns for gitignored files to copy into the worktree (e.g. `.env`, config files)
- **`.worktreelink`** — glob patterns for gitignored directories to symlink instead of copy (e.g. `node_modules`, `vendor/bundle`)

After copying and symlinking, Brainiac runs the project hook `.brainiac/worktree-setup` if it exists (see below).

### Project Hooks

Projects can define lifecycle hooks as executable scripts in `.brainiac/` at the project root:

| Hook              | When It Runs                                | Environment                          |
| ----------------- | ------------------------------------------- | ------------------------------------ |
| `worktree-setup`  | After worktree creation + file sync         | `WORKTREE_PATH` set to worktree dir  |

Add hooks by creating executable scripts:

```bash
# .brainiac/worktree-setup
#!/bin/bash
cd "$WORKTREE_PATH"
bundle install --quiet
```

## Zoho Mail

Brainiac can receive Zoho Mail webhooks and route email notifications to Discord channels based on configurable rules.

### Setup

Create `~/.brainiac/zoho.json`:

```json
{
  "hook_secret": null,
  "default_discord_channel_id": "YOUR_DISCORD_CHANNEL_ID",
  "notify_as": "threepio",
  "rules": [
    {
      "label": "Item Sold",
      "enabled": true,
      "from_contains": "",
      "subject_contains": "sold",
      "body_contains": "",
      "exclude_words": [],
      "emoji": "💰",
      "discord_channel_id": null,
      "notify_as": null
    }
  ],
  "fallback": {
    "enabled": true,
    "label": "Unmatched Email",
    "emoji": "📬",
    "exclude_words": [],
    "discord_channel_id": null,
    "notify_as": null
  }
}
```

Rules are matched in order against incoming emails (from address, subject, body). Each rule can override the Discord channel and which agent bot posts the notification. The fallback rule catches anything that doesn't match a specific rule.

The `hook_secret` is auto-captured from Zoho's initial handshake request — no manual configuration needed.

**Webhook URL:** `https://your-ngrok.ngrok-free.app/zoho`

**Requires:** Discord integration must be enabled (at least one agent with a `DISCORD_BOT_TOKEN`).

## Version Check

On startup, Brainiac checks if the local repo is behind `origin/master`. If it detects the local version is outdated, it logs a warning. This helps ensure agents are always running the latest code.

## Self-Restart

When an agent works on the brainiac project itself, the server automatically queues a restart. A background monitor thread checks every 30 seconds — once all active agent sessions finish, it stops the current server and spawns a new one. This ensures code changes agents make to brainiac take effect without manual intervention, and no running sessions are interrupted.

## CLI Reference

### Server

```bash
brainiac server                # Start and tail logs (Ctrl+C to detach, server keeps running)
brainiac server --daemon       # Background mode
brainiac stop                  # Stop
brainiac restart               # Restart
brainiac status                # Check if running
```

To inspect logs, read the log file directly — don't use `brainiac logs` (it streams indefinitely):

```bash
cat tmp/brainiac-server.log
tail -100 tmp/brainiac-server.log
```

### Projects

```bash
brainiac register              # Register current directory (interactive)
brainiac list                  # List all projects
brainiac projects default <key> # Set default project (fallback when no tags match)
brainiac show <key>            # Show project config
brainiac unregister <key>      # Remove a project
```

### Brain

```bash
brainiac brain init [agent]              # Initialize brain
brainiac brain status [agent]            # Show brain status
brainiac brain search <query>            # Search shared knowledge
brainiac brain search --persona <query>  # Search agent persona
brainiac brain list                      # List everything
```

## Project Configuration

Projects are stored in `~/.brainiac/projects.json`:

```json
{
  "marketplace": {
    "repo_path": "/home/you/Code/marketplace",
    "fizzy_tags": ["marketplace", "mp"],
    "github_repo": "yourorg/marketplace",
    "agent_cli": "kiro-cli",
    "agent_cli_args": "chat --trust-all-tools --no-interactive",
    "agent_model_flag": "--model",
    "agent_model": "auto",
    "allowed_models": {
      "opus": "claude-opus-4.6",
      "sonnet": "claude-sonnet-4.6",
      "haiku": "claude-haiku-4.5",
      "deepseek": "deepseek-3.2",
      "minimax": "minimax-m2.5",
      "minimax25": "minimax-m2.5",
      "minimax21": "minimax-m2.1",
      "qwen": "qwen3-coder-next",
      "auto": "auto"
    }
  }
}
```

### Model Selection

Override the default model per-dispatch:

- **Fizzy card tags:** Add `opus`, `sonnet`, `haiku`, `deepseek`, `minimax`, `minimax21`, or `qwen` as a tag on the card
- **Inline syntax (Fizzy, Discord, GitHub):** Include `[opus]`, `[sonnet]`, `[haiku]`, `[deepseek]`, `[minimax]`, `[minimax21]`, or `[qwen]` in your comment/message
- **Priority:** inline comment/message > card tags > project config > CLI default

Model keys are defined in the project's `allowed_models` config — you can add custom keys beyond the defaults.

## Prompt Customization

Prompts are layered in `lib/brainiac/prompts.rb`:

| Layer     | Constant                     | Included When                                                           |
| --------- | ---------------------------- | ----------------------------------------------------------------------- |
| Core      | `PROMPT_CORE`                | Every session — memory, brain, persona, reflection, communication rules |
| Channel   | `PROMPT_FIZZY_CHANNEL`       | Fizzy sessions — HTML formatting, fizzy reactions, screenshots          |
| Channel   | `PROMPT_DISCORD_CHANNEL`     | Discord sessions — Discord markdown, response file, mention syntax      |
| Channel   | `PROMPT_GITHUB_CHANNEL`      | GitHub sessions — GFM formatting, `gh api` reactions                    |
| Situation | `PROMPT_CARD_ASSIGNED`, etc. | Specific trigger type                                                   |

`render_prompt` composes: core + channel + situation. The `channel:` keyword defaults to `:fizzy`:

```ruby
render_prompt(PROMPT_CARD_ASSIGNED, vars, brain_context: ctx, agent_name: name)                  # Fizzy (default)
render_prompt(PROMPT_DISCORD, vars, brain_context: ctx, agent_name: name, channel: :discord)      # Discord
render_prompt(PROMPT_GITHUB_PR_REVIEW, vars, brain_context: ctx, agent_name: name, channel: :github)  # GitHub
```

| Placeholder                  | Description                                               |
| ---------------------------- | --------------------------------------------------------- |
| `{{CARD_NUMBER}}`            | Fizzy card number                                         |
| `{{CARD_TITLE}}`             | Card title                                                |
| `{{BRANCH}}`                 | Git branch name                                           |
| `{{CARD_INTERNAL_ID}}`       | Fizzy internal UUID                                       |
| `{{CARD_ID}}`                | Card number or internal ID                                |
| `{{CARD_AGENT}}`             | Agent assigned to the card (cross-agent reviews)          |
| `{{COMMENT_CREATOR}}`        | Comment author name                                       |
| `{{COMMENT_ID}}`             | Comment ID                                                |
| `{{COMMENT_BODY}}`           | Comment text                                              |
| `{{KNOWLEDGE_DIR}}`          | Path to shared knowledge                                  |
| `{{MEMORY_DIR}}`             | Path to agent's card memory (per-agent)                   |
| `{{PERSONA_DIR}}`            | Path to agent persona                                     |
| `{{PERSONA_COLLECTION}}`     | qmd collection name for persona                           |
| `{{AGENT_NAME}}`             | Agent name                                                |
| `{{AGENT_ROSTER}}`           | Formatted list of all agents with exact @mention spelling |
| `{{DISCORD_USER}}`           | Discord username (Discord only)                           |
| `{{CHANNEL_NAME}}`           | Discord channel name (Discord only)                       |
| `{{MESSAGE_BODY}}`           | Discord message content (Discord only)                    |
| `{{PROJECT_CONTEXT}}`        | Project info block (Discord only)                         |
| `{{RESPONSE_FILE}}`          | Path to write Discord response (Discord only)             |
| `{{DISCORD_MENTION_ROSTER}}` | Discord `<@ID>` mention mapping (Discord only)            |
| `{{PR_NUMBER}}`              | GitHub PR number (GitHub only)                            |
| `{{REVIEW_CONTEXT}}`         | Formatted review comments (GitHub only)                   |
| `{{WORKTREE_PATH}}`          | Worktree directory path (GitHub only)                     |

## API

```bash
curl http://localhost:4567/api/projects/marketplace         # Show specific project
curl http://localhost:4567/api/agents                       # List agents, roster with display names
curl http://localhost:4567/api/users                        # List all users
curl http://localhost:4567/api/users?filter=humans          # List only human users
curl http://localhost:4567/api/users?filter=agents          # List only AI agents
curl http://localhost:4567/api/users/fladamd                # Find user by any identifier
curl -X POST http://localhost:4567/api/reload               # Reload projects + agent registry + user registry
curl http://localhost:4567/api/brain                        # Brain status (default agent)
curl http://localhost:4567/api/brain?agent=GLaDOS           # Brain status for specific agent
curl "http://localhost:4567/api/brain/search?q=ruby+style"  # Search knowledge
curl "http://localhost:4567/api/brain/search?q=tone&scope=persona&agent=Galen"  # Search persona
curl http://localhost:4567/api/card-index                   # Card duplicate detection index
curl http://localhost:4567/api/dispatch-depth               # Agent-to-agent loop prevention state
curl http://localhost:4567/api/discord                      # Discord bot status and config
curl "http://localhost:4567/api/gif?q=excited"              # Search for GIFs (requires giphy_api_key)
curl http://localhost:4567/api/cron                         # Cron jobs and thread status
curl http://localhost:4567/api/logs                         # Read log files
curl http://localhost:4567/api/status                       # Active agent sessions (used by monitor)
```

## Development

Auto-restart on file changes:

```bash
ls brainiac receiver.rb lib/brainiac/*.rb lib/brainiac/handlers/*.rb | entr -r brainiac server
```

## Troubleshooting

**No projects found:** `brainiac list` to check, `brainiac path` to find config directory.

**Card not matching a project:** Verify the Fizzy card has a tag matching `fizzy_tags` in the project config. If no tags match, the default project is used (set with `brainiac projects default`).

**Agent not dispatching:** Check that `~/.kiro/agents/<name>.json` exists for the agent. The receiver discovers agents by scanning that directory. For registry-only agents, ensure `"local": true` is set.

**Cross-agent mention ignored:** Both machines receive webhooks. Only the machine with the agent's kiro-cli config in `~/.kiro/agents/` (or `"local": true` in the registry) will dispatch it.

**Agent commenting as wrong user:** Check `~/.brainiac/agents.json` has the correct `FIZZY_TOKEN` in the agent's `env` hash. The env is injected into the spawned agent process — verify with `curl http://localhost:4567/api/agents` to see the roster.

**Agent @mention not linking in Fizzy:** The `fizzy_name` in `agents.json` must match the exact Fizzy account name (case-sensitive). Check `curl http://localhost:4567/api/agents` to see what the roster looks like.

**Agent-to-agent loop:** Shouldn't happen — dispatch depth is capped at 10 hops by default. Check `curl http://localhost:4567/api/dispatch-depth` to see current state. Adjust `AGENT_DISPATCH_MAX_DEPTH` in `lib/brainiac/sessions.rb` if needed.

**Brain not working:** `brainiac brain status` to check. Make sure qmd is installed (`npm install -g @tobilu/qmd`) and `brainiac brain init` has been run for each agent.

**Brain sync not pushing:** Check that `~/.brainiac/brain/` is a git repo with a remote configured. Look for `[Brain] Push failed` in the server logs. The most common cause is an SSH key issue — make sure the machine can `git push` from that directory.

**Discord bot not connecting:** Check `brainiac discord status`. Common causes: invalid token (reset it in the Discord Developer Portal and re-register with `brainiac discord token`), Message Content intent not enabled, or the `websocket-client-simple` gem not installed.

**Discord bot connects but ignores messages:** The Message Content intent must be enabled in the Discord Developer Portal (Bot tab → Privileged Gateway Intents). Without it, the bot receives empty message content and silently drops every message.

**Discord bot responds but in the wrong project:** Check your channel mapping with `brainiac discord config`. Messages use the channel-specific mapping first, then fall back to `default_project`. Override per-message with `[project:name]` in your Discord message. Set the default with `brainiac discord default <project>`.

**Discord model override not working:** Make sure the project has `allowed_models` configured (check with `brainiac show <project>`). The tag must match a key in `allowed_models` — e.g. `[opus]` matches `"opus": "claude-opus-4.6"`. If no project is mapped to the channel, model overrides have nothing to look up against.

**Discord "unauthorized" reaction (🚫):** The user isn't in `authorized_user_ids` or doesn't have a role in `authorized_role_ids` in `~/.brainiac/discord.json`. Leave both arrays empty to allow everyone.

**Duplicate Discord dispatches:** Check `~/.brainiac/agents.json` for duplicate entries with the same bot token under different key formats (e.g. `sleeper-service` and `sleeper_service`). Keys are normalized to lowercase with hyphens — duplicates after normalization cause multiple gateway connections.

**Worktree cleanup:** Automatic on PR merge. Manual: `cd /path/to/worktree && gd` (see shell helpers below).

**Zoho emails not arriving in Discord:** Zoho integration requires Discord to be enabled (at least one agent with a `DISCORD_BOT_TOKEN`). Check `~/.brainiac/zoho.json` exists and rules are configured. The `hook_secret` is auto-captured from Zoho's initial handshake — if it's `null`, the webhook hasn't been triggered yet.

### Shell Helpers (Optional)

```bash
# Add to ~/.bashrc or ~/.zshrc
ga() {
  [[ -z "$1" ]] && { echo "Usage: ga [branch]"; return 1; }
  local branch="$1" base="$(basename "$PWD")" path="../${base}--${branch}"
  git worktree add -b "$branch" "$path"
  mise trust "$path" 2>/dev/null || asdf reshim 2>/dev/null || true
  cd "$path"
}

gd() {
  gum confirm "Remove worktree and branch?" || return
  local worktree="$(basename "$PWD")" root="${worktree%%--*}" branch="${worktree#*--}"
  [[ "$root" != "$worktree" ]] && cd "../$root" && git worktree remove "$worktree" --force && git branch -D "$branch"
}
```
