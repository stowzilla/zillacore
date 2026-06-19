# Agent Display Configuration (Waybar / xbar)

This file configures how agents appear in the status bar — waybar on Linux, xbar on macOS.

**Location:** `~/.brainiac/waybar.json`

## Example Configuration

```json
{
  "agents": [
    {
      "name": "GLaDOS",
      "emoji": "🤖",
      "color": "blue"
    },
    {
      "name": "Galen",
      "emoji": "🛠️",
      "color": "green"
    },
    {
      "name": "Threepio",
      "emoji": "📝",
      "color": "yellow"
    },
    {
      "name": "Sheogorath",
      "emoji": "🎭",
      "color": "purple"
    },
    {
      "name": "Kaylee",
      "emoji": "🔧",
      "color": "pink"
    },
    {
      "name": "Avon",
      "emoji": "🔐",
      "color": "red"
    },
    {
      "name": "Sleeper Service",
      "emoji": "💤",
      "color": "cyan"
    }
  ],
  "default_emoji": "❓",
  "schema_version": "1.0"
}
```

## Fields

- **name**: Agent name (must match agent registry)
- **emoji**: Display emoji for waybar
- **color**: Terminal color for logs (red, green, blue, yellow, cyan, magenta, white)
- **default_emoji**: Fallback emoji when agent is unknown
- **schema_version**: Config format version

## Usage

Monitor scripts automatically load this file:
- `monitor/waybar.rb` - Waybar status display (Linux)
- `monitor/xbar.3s.rb` - xbar menu bar plugin (macOS)
- `monitor/daemon.rb` - Background monitor daemon
- `monitor/view-logs.rb` - Log viewer
- `monitor/view-logs-rofi.rb` - Rofi log selector

### Linux (Waybar)

```bash
ruby monitor/setup-waybar-module.rb   # One-time setup
omarchy restart waybar                 # Restart waybar
```

### macOS (xbar)

Requires [xbar](https://xbarapp.com) (free, formerly BitBar).

```bash
ruby monitor/setup-xbar-plugin.rb     # One-time setup (symlinks plugin)
# Restart xbar to activate
```

The xbar plugin reads from the same daemon socket as waybar. Make sure the monitor daemon is running:

```bash
ruby monitor/daemon.rb &
```

After editing agent config, restart brainiac:
```bash
brainiac restart
```

