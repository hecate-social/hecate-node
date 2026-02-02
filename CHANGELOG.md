# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-02-02

### Added

- Initial release
- `install.sh` - One-command installer (`curl | bash`)
  - Installs Erlang OTP 27+ and Elixir via mise/asdf
  - Downloads hecate-daemon from GitHub releases
  - Downloads hecate-tui from GitHub releases
  - Installs Claude Code skills to `~/.claude/`
  - Sets up `~/.hecate/` data directory
- `uninstall.sh` - Clean removal script
- `SKILLS.md` - Claude Code skills for Hecate mesh operations
  - Daemon management commands
  - Capability discovery and announcement
  - RPC registration and calls
  - PubSub subscribe/publish
  - Social graph operations
  - UCAN capability management
