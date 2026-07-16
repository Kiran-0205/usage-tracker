# Usage Tracker

A native macOS menu bar app that mirrors the **usage screens** of Claude Code (`/usage`)
and Codex — just the rate-limit percentages, nothing else.

## Menu bar

```
✳ 60%  ⌁ 0%
```

- `✳` — Claude Code current session (5h window) % used
- `⌁` — Codex current session (5h window) % used

Click for the full usage screen:

```
Claude Code
  Current session: 60% used · resets 8:39 PM
  Current week (all models): 6% used · resets Mon 7:29 AM
  Current week (Fable): 11% used · resets Mon 7:29 AM
Codex
  Current session (5h): 0% used
  Current week: 14% used · resets Sat 11:25 PM
```

## Data sources

| Tool | Source |
|---|---|
| Claude Code | The same API endpoint the `/usage` screen calls (`api.anthropic.com/api/oauth/usage`), authenticated with your existing Claude Code login from the macOS Keychain. Live and exact. |
| Codex | The `rate_limits` snapshot Codex writes into `~/.codex/sessions/**.jsonl` with every turn. Reflects your last Codex session; windows whose reset time has passed show 0%. |

Refreshes every 60 seconds and whenever the menu is opened.

## Build & run

```sh
./build.sh          # compiles Sources/main.swift into UsageTracker.app
open UsageTracker.app
```

Use the **Launch at Login** menu item to install/remove a LaunchAgent
(`~/Library/LaunchAgents/com.usagetracker.claude-codex.plist`).

## Debugging

```sh
./UsageTracker.app/Contents/MacOS/UsageTracker --dump
```

Prints the same data to stdout without starting the UI.
