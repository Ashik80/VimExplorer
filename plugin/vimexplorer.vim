" plugin/vimexplorer.vim
" VimExplorer - An oil.nvim-style file explorer for Vim

" Prevent loading twice
if exists('g:loaded_vimexplorer')
  finish
endif
let g:loaded_vimexplorer = 1

" Default configuration
if !exists('g:vimexplorer_show_hidden')
  let g:vimexplorer_show_hidden = 0
endif

if !exists('g:vimexplorer_win_height')
  let g:vimexplorer_win_height = 20
endif

if !exists('g:vimexplorer_detail')
  let g:vimexplorer_detail = 1
endif

if !exists('g:vimexplorer_show_header')
  let g:vimexplorer_show_header = 1
endif

" Commands
" :VimExplorer [dir]   open explorer for [dir]
command! -nargs=? -complete=dir VimExplorer call vimexplorer#Open(<q-args>)

" :VimExplorerCwd      open explorer for Vim's cwd
command! VimExplorerCwd call vimexplorer#Open(getcwd())

augroup VimExplorer
  autocmd!
  autocmd BufWriteCmd vimexplorer://* call vimexplorer#Save()
  autocmd BufEnter    vimexplorer://* call vimexplorer#Refresh()
  autocmd BufEnter * if isdirectory(expand('<afile>')) && expand('<afile>') !~# '^vimexplorer://' | call vimexplorer#Open(expand('<afile>')) | endif
augroup END
