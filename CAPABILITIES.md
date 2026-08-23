# Capability Map: quickdraw.nvim

| Module id | Responsibility | Depends on |
|---|---|---|
| `artifact-format` | Embed and extract versioned Quickdraw snapshots in PNG metadata | — |
| `editor-session` | Run the local editor server, host the offline Quickdraw UI, and load/save drawings | `artifact-format` |
| `neovim-integration` | Provide commands, configuration, paths, Markdown insertion, and cursor-based editing | `editor-session` |

Build order: `artifact-format` → `editor-session` → `neovim-integration`
