# Website Engineer

> Agent role for the marketing site under `website/`.

This role is intentionally a **pointer** to the scoped guide that already lives in the
website directory:

- [`website/AGENTS.md`](../website/AGENTS.md)
- [`website/PRODUCT.md`](../website/PRODUCT.md)
- [`website/DESIGN.md`](../website/DESIGN.md)

## When to use this role

Use `.agents/website-engineer.md` (or directly `website/AGENTS.md`) when the task only touches
`website/` — React components, Vite config, CSS tokens, copy, assets, or Vercel deployment.

## Quick commands

```sh
npm --prefix website run dev      # localhost:5173
npm --prefix website run build    # production build → website/dist/
npm --prefix website run preview  # serve the production build
```

## Tools (Cursor)

- **`chrome-devtools`** skill — follow its `SKILL.md` (Read tool) for browser automation and
  verification; the chrome-devtools MCP is available via `CallMcpTool` (`navigate_page`,
  `take_screenshot`, `take_snapshot`, `list_console_messages`) for verifying the running site.
- **React / Vite / library API questions** → the **`context7`** MCP (via `CallMcpTool`:
  `resolve-library-id` → `query-docs`) for current library docs; web search/fetch as fallback.
- **Bash** for `npm`/`node` commands via the Shell tool.

## Boundaries

- This is a **non-app, non-native zone** — do not run Swift/iOS/macOS auditors here.
- Product claims must be cross-referenced with `Sources/Resources/qwenvoice_contract.json`,
  root `AGENTS.md`, and `docs/ARCHITECTURE.md`.
- Follow the brand/copy rules in `website/PRODUCT.md` and the design bans in `website/DESIGN.md`.
