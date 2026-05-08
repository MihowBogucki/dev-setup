# dev-setup

> **Stop spending your first day reading setup docs. One script. Every machine.**

---

## The problem

Setting up a developer machine is repetitive, error-prone, and surprisingly slow. You install things in a different order each time, forget something critical, and end up with machines that behave differently from each other.

For teams it's even worse. A new joiner spends their first day (or two) chasing wiki pages, Slack threads, and tribal knowledge just to get a working environment. None of that is a good use of anyone's time.

---

## What dev-setup does

**For individuals** — define your tools once, run one script on any new machine. Done in minutes, not hours. Works whether you switch laptops often or just want to stop starting from scratch.

**For teams** — maintain a shared `base.json` with the tools every developer needs. New joiners clone the repo, run the script, and have a working environment before lunch. No docs to read, no steps to miss.

The TUI guides you through everything — no flags to memorise.

---

## How it works

```
1. Run the script            →  .\setup-cli.ps1
2. Scan your machine         →  find tools you have that aren't in your config yet
3. Build your base           →  edit base.json with your team's standard tools
4. Build your personal setup →  edit personal.json with your own extras
5. Commit & share            →  anyone on your team can clone and run
```

Already-installed tools are detected and skipped. The script tries **Chocolatey first, winget second** — it will offer to install Chocolatey for you if it isn't present, or skip it entirely and use winget if you prefer.

---

## Quick start

```powershell
# From an elevated (Admin) PowerShell terminal:
git clone https://github.com/you/dev-setup C:\Source\dev-setup
cd C:\Source\dev-setup
.\setup-cli.ps1
```

The interactive menu handles the rest — including a **Snapshot** option that scans your machine and tells you what's installed but not yet in your config.

---

## Files

```
dev-setup/
├── setup-cli.ps1    ← Interactive TUI (arrow keys, checkboxes, spinners)
├── base.json        ← Team tools — shared, everyone gets these
└── personal.json    ← Your tools — extends base.json, adds your extras
```

---

## The base / personal split

`personal.json` extends `base.json`:

```json
{
  "extends": "./base.json",
  "tools": [
    { "name": "Rider",   ... },
    { "name": "Postman", ... }
  ]
}
```

- `base.json` — commit this to a shared team repo. Keep it to tools everyone actually needs.
- `personal.json` — lives in your personal repo. Add whatever you want here.
- If a personal entry has the same `name` as a base entry, yours wins (useful for pinning a version).

**Pointing at a team base from a shared repo:**

```json
{
  "extends": "C:\\Source\\team-dotfiles\\base.json"
}
```

---

## Adding a tool

Open `base.json` or `personal.json` and add an entry to the `tools` array:

```json
{
  "name": "Postman",
  "description": "API testing client",
  "checkCommand": "postman --version",
  "choco": "postman",
  "winget": "Postman.Postman",
  "fallbackUrl": "https://www.postman.com/downloads/"
}
```

| Field | Purpose |
|-------|---------|
| `name` | Display name — must be unique |
| `description` | Shown in the tool picker |
| `checkCommand` | Run to detect if already installed |
| `choco` | Chocolatey package name (`choco search <name>`) |
| `winget` | winget package ID (`winget search <name>`) |
| `fallbackUrl` | Shown if both package managers fail |

Only `name` and `checkCommand` are required. Omit the rest if a package manager doesn't have the tool.

The **Help** option in the TUI menu walks through this interactively.

---

## CLI flags

| Flag | What it does |
|------|-------------|
| `-DryRun` | Preview what would be installed — nothing actually runs |
| `-SkipChoco` | Skip Chocolatey, use winget only |
| `-Config <path>` | Use a different config file |

```powershell
.\setup-cli.ps1 -DryRun
.\setup-cli.ps1 -SkipChoco
.\setup-cli.ps1 -Config base.json
```

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or PowerShell 7+
- Run as Administrator

**winget** ships with Windows 11 and recent Windows 10 builds. If it's missing, install [App Installer](https://aka.ms/getwinget) from the Microsoft Store.

**Chocolatey** is optional — the script will offer to install it, or you can skip it with `-SkipChoco` and use winget only.

