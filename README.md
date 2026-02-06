# Dev Container Features

This repository contains a collection of [Dev Container Features](https://containers.dev/implementors/features/) for use with development containers.

## Features

### Claude Code

Installs the [Claude Code CLI](https://claude.com/claude-code) tool for AI-powered development assistance.

**Options:**

- `claudeCodeVersion` (string): Version to install. Options: `latest` (default), `stable`

**Usage:**

```json
{
  "features": {
    "ghcr.io/your-username/features/claude-code:1": {
      "claudeCodeVersion": "latest"
    }
  }
}
```

### tmux

Installs [tmux](https://github.com/tmux/tmux), a terminal multiplexer.

**Usage:**

```json
{
  "features": {
    "ghcr.io/your-username/features/tmux:1": {}
  }
}
```

### Zsh

Installs [Zsh](https://www.zsh.org/) shell with optional plugins.

**Options:**

- `pluginDir` (string): Directory to install zsh plugins into. Default: `automatic`
- `pure` (string): Git ref for [pure prompt](https://github.com/sindresorhus/pure). Empty to skip.
- `zshAutosuggestions` (string): Git ref for [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions). Empty to skip.
- `zshSyntaxHighlighting` (string): Git ref for [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting). Empty to skip.

**Usage:**

```json
{
  "features": {
    "ghcr.io/your-username/features/zsh:1": {
      "pure": "main",
      "zshAutosuggestions": "main",
      "zshSyntaxHighlighting": "main"
    }
  }
}
```

## Testing

To test all features:

```bash
./test.sh
```

## Development

Each feature is located in the `src/` directory and contains:

- `devcontainer-feature.json` - Feature metadata and configuration
- `install.sh` - Installation script

## CI/CD

GitHub Actions workflows are configured for:

- `test-all.yaml` - Automated testing of all features
- `test-manual.yaml` - Manual testing workflow

## License

See LICENSE file for details.
