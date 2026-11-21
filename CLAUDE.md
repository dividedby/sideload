@AGENTS.md

## Commands

Full list in `AGENTS.md` (Commands). Summary:

- Test: `swift test` (CLI) and `pnpm test` (secrets scanner); `scripts/check.sh` is the local gate that runs both plus the release build.
- Lint: `pnpm lint` (oxlint), `shellcheck $(git ls-files '*.sh' '*.bash') .githooks/pre-commit`, `swift format lint --strict --recursive .` (honours `.swift-format`; `OnlyOneTrailingClosureArgument` is off), `pnpm check-secrets:all` and `pnpm format:check` (Prettier; CI also runs `shfmt`).
