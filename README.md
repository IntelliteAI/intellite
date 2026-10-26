# Intellite

Plugin for [Intellite](https://intellite.app/). Marketplace files: `.claude-plugin/marketplace.json` (Claude Code),
`.agents/plugins/marketplace.json` (Codex).

## intellite-methods

- MCP server: `https://intellite.app/apps/intellite-methods` (OAuth 2.0)
- Skill: `intellite-methods`
- SessionStart hook: Stack sync (`sync/`)

### Install

Claude Code:

```
claude plugin marketplace add IntelliteAI/intellite
claude plugin install intellite-methods@intellite
```

Codex:

```
codex plugin marketplace add IntelliteAI/intellite
codex plugin add intellite-methods@intellite
```

Codex runs plugin hooks after they are trusted: `/hooks` (CLI) or Settings > Hooks (app).

### Stack sync

```
sync/intellite-sync connect
sync/intellite-sync status
sync/intellite-sync disconnect <id>
```

Windows: `sync\intellite-sync.cmd`.

- Runs on SessionStart (startup, resume). Time limit 10 seconds.
- Connection: OAuth 2.0 authorization code with PKCE, loopback redirect, scope `methods.stack.read`. One connection per
  workspace. Expires after 30 days unused (personal workspace) or by the organization's sign-in rules.
- Writes only `intellite-*` folders in `~/.claude/skills` (`$CLAUDE_CONFIG_DIR/skills`) and `~/.agents/skills`.
- Checks the SHA-256 of every file. Leaves a folder that was changed locally.
- Removes skills taken out of the Stack, and versions listed at `/apps/intellite-methods/skills/stopped`.
- Refresh token: DPAPI (Windows), Keychain (macOS), Secret Service or a 0600 file (Linux). Records: `~/.intellite/sync/`.
- Requires PowerShell 5.1 (Windows), or Perl and curl (macOS, Linux).

### Uninstall

Run `sync/intellite-sync disconnect <id>` for each connection (removes its skills), then uninstall the plugin.

## Terms

[Terms of Service](https://intellite.app/terms), [Privacy Policy](https://intellite.app/privacy).

## License

Apache-2.0
