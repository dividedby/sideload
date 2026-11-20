@AGENTS.md

## Commands

Full list in `AGENTS.md` (Commands). Summary:

- Test: `swift test` (CLI) and `pnpm test` (secrets scanner); `scripts/check.sh` is the local gate that runs both plus the release build.
- Lint: none beyond `pnpm check-secrets:all` and `pnpm format:check` (Prettier; CI also runs `shfmt` and `swift-format`).
