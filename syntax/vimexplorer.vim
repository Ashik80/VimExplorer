" syntax/vimexplorer.vim
if exists('b:current_syntax')
  finish
endif

" Header comment lines
syntax match VimExplorerHeader  /^".*$/

" Directory entries (lines ending with /)
" \S.*\/ matches from first non-space to trailing slash, handles spaces in names
syntax match VimExplorerDir     /\S.*\/$/

" Detail mode: permissions string at the start of the line
syntax match VimExplorerPerms   /^[dlrwxs\-]\{10\}/
" Detail mode: file size field (digits followed by B/K/M/G or ?)
syntax match VimExplorerSize    /\s\+\zs[0-9]\+[BKMG?]\ze\s/

" Dotfiles (hidden files — name starts with a dot, possibly after the prefix)
syntax match VimExplorerDotfile /\s\?\.\S\+/

" Highlight groups linked to standard Vim groups so they work with any
" colorscheme. Users can override these in their vimrc after the plugin loads.
highlight default link VimExplorerHeader  Comment
highlight default link VimExplorerDir     Directory
highlight default link VimExplorerPerms   NonText
highlight default link VimExplorerSize    Number
highlight default link VimExplorerDotfile Comment

let b:current_syntax = 'vimexplorer'
