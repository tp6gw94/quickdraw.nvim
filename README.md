# quickdraw.nvim

Create and edit Quickdraw drawings from Markdown in Neovim.

- Neovim >= 0.8
- Native HTML/JavaScript editor bundled with the plugin
- Offline at runtime: no npm, build step, CDN, or external network access
- PNGs keep their normal image data and store an editable Quickdraw snapshot

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "tp6gw94/quickdraw.nvim",
  ft = "markdown",
}
```

The plugin loads its `:Quickdraw` command automatically for Markdown buffers.

## Configuration

Configuration is optional. The default drawing directory is `./assets`:

```lua
require("quickdraw").setup({
  path = "./assets",
})
```

`path` can be relative or absolute:

- A relative path is resolved from the current saved Markdown document's directory, not from Neovim's working directory.
- An absolute path stays absolute. Markdown links use `/` separators on every platform.
- `~`, environment variables, and globs are treated literally.
- The configured path must fit the supported inline-link form: no whitespace, `()<>?#`, or URI scheme.

Only a basename is accepted when creating a drawing. Names cannot contain a path separator, whitespace, control byte, or Markdown delimiter. `diagram` and `diagram.png` both produce `diagram.png`; a final `.PNG` suffix is normalized to `.png`.

## Create or edit

Run the single argument-free command:

```vim
:Quickdraw
```

The command chooses its action from the cursor position:

1. On a supported inline Quickdraw image link, it opens that PNG for editing.
2. Elsewhere in a Markdown buffer, it prompts for a drawing basename, creates the configured directory if needed, and starts a new drawing.
3. After the session starts successfully, it inserts an empty-alt link at the original cursor position:

   ```markdown
   ![](./assets/diagram.png)
   ```

The Markdown buffer is not written automatically. Save it with Neovim when you are ready. Starting another drawing replaces the one active in the current Neovim process; only one editor session is active at a time.

## Supported edit links

Cursor-based editing intentionally supports this constrained inline form:

```markdown
![](./assets/diagram.png)
```

The image must be on one line, the cursor must be between `!` and `)`, and the destination must be a local path ending in `.png` (case-insensitive). Relative destinations use the Markdown document directory; absolute POSIX, Windows drive, and UNC paths remain absolute.

Reference-style images, titles, multiline images, angle-bracket destinations, remote URLs, URI schemes, query strings, fragments, whitespace, and nested parentheses are not parsed. Unsupported image syntax follows the create flow instead of being treated as an edit link.

A linked missing PNG can be created. An existing Quickdraw PNG opens for editing. An existing ordinary or invalid PNG is rejected and is never overwritten.

## Browser fallback

The editor is normally opened in the default browser. If that launch fails, the session remains active and Quickdraw shows a notification containing the local URL. Open that URL manually; it is valid only while that session is running.

## Troubleshooting

- **"Quickdraw requires a Markdown buffer"** — set the buffer filetype to `markdown`.
- **Relative path error** — save the Markdown document before creating a drawing; relative paths need its directory.
- **Invalid drawing name** — enter a basename such as `diagram` or `diagram.png`, not a path.
- **PNG is not editable** — the file is not a valid Quickdraw PNG; it will not be overwritten.
- **Browser did not open** — use the URL in the warning notification.
- **No link was inserted** — canceling, an invalid input, a failed session, or a changed/non-modifiable buffer leaves the Markdown text unchanged.

## License

MIT. The bundled Quickdraw core is also MIT-licensed; see `web/quickdraw/vendor/@quickdrawjs/core/LICENSE`.
