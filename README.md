# VimExplorer

An oil.nvim-style file explorer for Vim. Edit your filesystem like a buffer — rename, delete, create, copy, and move files by editing text and saving with `:w`.

## Installation

**Vim** — clone into `~/.vim/pack/plugins/start/`:

```sh
git clone https://github.com/YOUR_USERNAME/vimexplorer ~/.vim/pack/plugins/start/vimexplorer
```

**Neovim** — clone into `~/.local/share/nvim/site/pack/plugins/start/`:

```sh
git clone https://github.com/YOUR_USERNAME/vimexplorer ~/.local/share/nvim/site/pack/plugins/start/vimexplorer
```

Both use Vim's built-in package loader (`:h packages`), no plugin manager needed. After cloning, generate the help tags:

```vim
:helptags ALL
```

## Usage

```vim
:VimExplorer          " open explorer for current file's directory
:VimExplorer /path    " open explorer for a specific directory
:VimExplorerCwd       " open explorer for Vim's cwd
```

Recommended mapping:

```vim
nnoremap <silent> - :VimExplorer<CR>
```

## Key Bindings

| Key       | Action                              |
|-----------|-------------------------------------|
| `<CR>`    | Open file / enter directory         |
| `-`       | Go up one directory                 |
| `<BS>`    | Go up one directory                 |
| `gh`      | Toggle hidden files                 |
| `gd`      | Toggle detail mode (perms + size)   |
| `yy`      | Yank entry (copy intent)            |
| `dd`      | Cut entry (move intent)             |
| `p` / `P` | Paste yanked/cut entry              |
| `<C-v>`   | Open file in vertical split         |
| `<C-s>`   | Open file in horizontal split       |
| `R`       | Refresh listing                     |
| `:w`      | Apply all pending edits             |
| `q`       | Close explorer                      |
| `?`       | Show key binding summary            |

## Editing

**Rename** — edit the filename on its line, then `:w`. Confirmation required.

**Delete** — `dd` to remove the line, then `:w`. Confirmation required.

**Create file** — add a new line with the filename, then `:w`. Nested paths are supported; parent dirs are created automatically.
```
notes.txt
docs/notes.txt
```

**Create directory** — add a line ending with `/`, then `:w`. Nested dirs supported.
```
logs/
logs/archive/
```

**Copy** — `yy` on an entry in one explorer buffer, `p` in another, then `:w` in the destination. Works for files and directories (recursive).

**Move** — same as copy but use `dd` instead of `yy`. The file/directory is moved atomically.

## Configuration

```vim
let g:vimexplorer_show_hidden = 0   " show dotfiles by default (default: 0)
let g:vimexplorer_detail      = 1   " show perms + size prefix (default: 1)
let g:vimexplorer_show_header = 1   " show path/hint header lines (default: 1)
```

## Detail Mode

When enabled (`gd` to toggle), each line is prefixed with permissions and size:

```
drwxr-xr-x          src/
-rw-r--r--    42B   README.md
```

Only the filename at the end of the line is used when saving.

## Syntax Highlighting

| Group                | Default link | What it highlights          |
|----------------------|--------------|-----------------------------|
| `VimExplorerHeader`  | `Comment`    | Path and hint lines         |
| `VimExplorerDir`     | `Directory`  | Directory entries           |
| `VimExplorerPerms`   | `NonText`    | Permissions string          |
| `VimExplorerSize`    | `Number`     | File size field             |
| `VimExplorerDotfile` | `Comment`    | Hidden files/directories    |

Override any group after your colorscheme is set:

```vim
highlight VimExplorerDir    ctermfg=cyan   guifg=#89dceb
highlight VimExplorerPerms  ctermfg=240    guifg=#585858
highlight VimExplorerSize   ctermfg=yellow guifg=#f9e2af
highlight VimExplorerDotfile ctermfg=238   guifg=#45475a
```
