" autoload/vimexplorer.vim

" Script-local state
let s:state = {}

" Paths explicitly cut (dd) — used to distinguish move from copy
let s:cut_paths = {}

" Open the explorer buffer
function! vimexplorer#Open(path) abort
  " If path is not provided should open in cwd
  if a:path ==# ''
    let l:dir = expand('%:p:h')
    if l:dir ==# '' || !isdirectory(l:dir)
      let l:dir = getcwd()
    endif
  else
    let l:dir = fnamemodify(a:path, ':p')
    " Strip trailing slash (except root)
    if l:dir[-1:] ==# '/' && l:dir !=# '/'
      let l:dir = l:dir[:-2]
    endif
  endif

  if !isdirectory(l:dir)
    echohl ErrorMsg | echo 'VimExplorer: not a directory: ' . l:dir | echohl None
    return
  endif

  let l:bufname = 'vimexplorer://' . l:dir
  let l:existing = bufnr(l:bufname)

  if l:existing != -1
    execute 'buffer ' . l:existing
  else
    execute 'edit ' . fnameescape(l:bufname)
  endif

  call s:SetupBuffer(l:dir)
  call s:Render(bufnr('%'))
endfunction

" Save to apply edits to filesystem
function! vimexplorer#Save() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    echoerr 'VimExplorer: no state for buffer ' . l:bufnr
    return
  endif

  let l:st = s:state[l:bufnr]
  let l:dir = l:st.dir

  let l:new_names = s:ParseLines(getline(1, '$'))

  let l:old_names = l:st.names

  let l:new_names_bare = map(copy(l:new_names), 'substitute(v:val, "/$", "", "")')

  let l:old_only = []
  for l:name in l:old_names
    if index(l:new_names_bare, l:name) ==# -1
      call add(l:old_only, l:name)
    endif
  endfor

  let l:new_only = []
  for l:name in l:new_names
    let l:bare = substitute(l:name, '/$', '', '')
    if l:bare !=# '' && index(l:old_names, l:bare) ==# -1
      call add(l:new_only, l:name)
    endif
  endfor

  let l:to_rename = []
  let l:new_files = []
  let l:ri = 0
  for l:i in range(len(l:new_only))
    if l:ri < len(l:old_only)
      call add(l:to_rename, [l:old_only[l:ri], l:new_only[l:i]])
      let l:ri += 1
    else
      call add(l:new_files, l:new_only[l:i])
    endif
  endfor

  " Entries in old_only not consumed by a rename are true deletions
  let l:to_delete = l:old_only[l:ri :]

  " Confirm deletions
  if !empty(l:to_delete)
    let l:msg = 'VimExplorer: delete ' . len(l:to_delete) . ' item(s)? [y/N] '
    let l:ans = input(l:msg)
    if l:ans !~? '^y'
      echo "\nAborted."
      call s:Render(l:bufnr)
      return
    endif
    echo ''
  endif

  " Confirm renames
  if !empty(l:to_rename)
    let l:msg = 'VimExplorer: rename ' . len(l:to_rename) . ' item(s)? [y/N] '
    let l:ans = input(l:msg)
    if l:ans !~? '^y'
      echo "\nAborted."
      call s:Render(l:bufnr)
      return
    endif
    echo ''
  endif

  " Apply renames
  for [l:old, l:new] in l:to_rename
    if l:new =~# '/'
      echohl ErrorMsg
      echo 'VimExplorer: rename across directories not supported: ' . l:new
      echohl None
      continue
    endif
    let l:src = l:dir . '/' . l:old
    let l:dst = l:dir . '/' . l:new
    if filereadable(l:dst) || isdirectory(l:dst)
      echohl ErrorMsg
      echo 'VimExplorer: target already exists: ' . l:dst
      echohl None
      continue
    endif
    if rename(l:src, l:dst) !=# 0
      echohl ErrorMsg
      echo 'VimExplorer: rename failed: ' . l:src . ' -> ' . l:dst
      echohl None
    else
      echo 'Renamed: ' . l:old . ' → ' . l:new
    endif
  endfor

  " Apply deletions
  for l:name in l:to_delete
    let l:target = l:dir . '/' . l:name
    if isdirectory(l:target)
      let l:out = system('rm -rf ' . shellescape(l:target))
      if v:shell_error !=# 0
        echohl ErrorMsg | echo 'VimExplorer: failed to remove dir: ' . l:target | echohl None
      else
        echo 'Deleted dir: ' . l:name
      endif
    else
      if !filereadable(l:target)
        " Already gone (e.g. moved away by another buffer's save)
      elseif delete(l:target) !=# 0
        echohl ErrorMsg | echo 'VimExplorer: failed to delete: ' . l:target | echohl None
      else
        echo 'Deleted: ' . l:name
      endif
    endif
  endfor

  " Confirm creations
  if !empty(l:new_files)
    let l:msg = 'VimExplorer: create ' . len(l:new_files) . ' item(s)? [y/N] '
    let l:ans = input(l:msg)
    if l:ans !~? '^y'
      echo "\nAborted."
      call s:Render(l:bufnr)
      return
    endif
    echo ''
  endif

  " Create new files
  for l:name in l:new_files
    if l:name =~# '/$'
      let l:bare  = l:name[:-2]
      let l:dname = l:dir . '/' . l:bare
      let l:src_path = s:FindInOtherBuffers(l:bare, l:dir)
      if l:src_path !=# ''
        " Directory came from another explorer buffer — move or copy it
        if has_key(s:cut_paths, l:src_path)
          " Cut (dd) → move
          if rename(l:src_path, l:dname) !=# 0
            echohl ErrorMsg | echo 'VimExplorer: failed to move dir: ' . l:src_path | echohl None
          else
            unlet s:cut_paths[l:src_path]
            echo 'Moved: ' . l:src_path . ' → ' . l:dname
          endif
        else
          " Yank (yy) → recursive copy
          let l:out = system('cp -r ' . shellescape(l:src_path) . ' ' . shellescape(l:dname))
          if v:shell_error !=# 0
            echohl ErrorMsg | echo 'VimExplorer: failed to copy dir: ' . l:src_path | echohl None
          else
            echo 'Copied: ' . l:src_path . ' → ' . l:dname
          endif
        endif
      else
        " No source found → create empty directory
        if mkdir(l:dname, 'p') ==# 0
          echohl ErrorMsg | echo 'VimExplorer: failed to create dir: ' . l:dname | echohl None
        else
          echo 'Created dir: ' . l:name
        endif
      endif
    else
      let l:fpath = l:dir . '/' . l:name
      " Check if a file with this name exists somewhere in the original
      " listing's parent directories — i.e. the user copied it from
      " another open explorer buffer. We do this by searching all known
      " explorer buffers for a directory containing this filename.
      let l:src_path = s:FindInOtherBuffers(l:name, l:dir)
      if l:src_path !=# ''
        let l:fparent = fnamemodify(l:fpath, ':h')
        if !isdirectory(l:fparent)
          call mkdir(l:fparent, 'p')
        endif
        if has_key(s:cut_paths, l:src_path)
          " Cut (dd)
          if rename(l:src_path, l:fpath) !=# 0
            echohl ErrorMsg | echo 'VimExplorer: failed to move to: ' . l:fpath | echohl None
          else
            unlet s:cut_paths[l:src_path]
            echo 'Moved: ' . l:src_path . ' → ' . l:fpath
          endif
        else
          " Yank (yy) → copy (recursive for directories)
          if isdirectory(l:src_path)
            let l:out = system('cp -r ' . shellescape(l:src_path) . ' ' . shellescape(l:fpath))
            if v:shell_error !=# 0
              echohl ErrorMsg | echo 'VimExplorer: failed to copy dir: ' . l:src_path | echohl None
            else
              echo 'Copied: ' . l:src_path . ' → ' . l:fpath
            endif
          else
            let l:content = readfile(l:src_path, 'b')
            if writefile(l:content, l:fpath, 'b') !=# 0
              echohl ErrorMsg | echo 'VimExplorer: failed to copy to: ' . l:fpath | echohl None
            else
              echo 'Copied: ' . l:src_path . ' → ' . l:fpath
            endif
          endif
        endif
      else
        let l:fparent = fnamemodify(l:fpath, ':h')
        if !isdirectory(l:fparent)
          call mkdir(l:fparent, 'p')
        endif
        if writefile([], l:fpath) !=# 0
          echohl ErrorMsg | echo 'VimExplorer: failed to create file: ' . l:fpath | echohl None
        else
          echo 'Created: ' . l:name
        endif
      endif
    endif
  endfor

  call s:Render(l:bufnr)
  setlocal nomodified
endfunction

" Refresh the explorer
function! vimexplorer#Refresh() abort
  let l:bufnr = bufnr('%')
  if has_key(s:state, l:bufnr)
    call s:SetupBuffer(s:state[l:bufnr].dir)
    call s:Render(l:bufnr)
  endif
endfunction

" Enter file or directory under cursor
function! vimexplorer#Enter() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:dir = s:state[l:bufnr].dir
  let l:name = s:NameUnderCursor()
  if l:name ==# ''
    return
  endif

  let l:target = l:dir . '/' . l:name

  if isdirectory(l:target)
    call vimexplorer#Open(l:target)
  elseif filereadable(l:target)
    execute 'edit ' . fnameescape(l:target)
  else
    echohl WarningMsg
    echo 'VimExplorer: not found: ' . l:target
    echohl None
  endif
endfunction

" Go up one directory
function! vimexplorer#Up() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:dir = s:state[l:bufnr].dir
  let l:parent = fnamemodify(l:dir, ':h')
  if l:parent ==# l:dir
    echo 'VimExplorer: already at root'
    return
  endif
  call vimexplorer#Open(l:parent)
endfunction

" Toggle hidden files
function! vimexplorer#ToggleHidden() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:st = s:state[l:bufnr]
  let l:st.show_hidden = !l:st.show_hidden
  call s:Render(l:bufnr)
endfunction

" Toggle detail (size/perms prefix)
function! vimexplorer#ToggleDetail() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:st = s:state[l:bufnr]
  let l:st.detail = !l:st.detail
  call s:Render(l:bufnr)
endfunction

" Open file in a vertical split
function! vimexplorer#OpenSplit(vertical) abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:dir = s:state[l:bufnr].dir
  let l:name = s:NameUnderCursor()
  if l:name ==# '' || isdirectory(l:dir . '/' . l:name)
    return
  endif
  let l:target = l:dir . '/' . l:name
  if a:vertical
    execute 'vsplit ' . fnameescape(l:target)
  else
    execute 'split ' . fnameescape(l:target)
  endif
endfunction

" Mark as cut
function! vimexplorer#Cut() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:name = s:NameUnderCursor()
  if l:name ==# ''
    return
  endif
  let l:path = s:state[l:bufnr].dir . '/' . l:name
  let s:cut_paths[l:path] = 1
  normal! dd
endfunction

" Don't mark as cut
function! vimexplorer#Yank() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:name = s:NameUnderCursor()
  if l:name ==# ''
    return
  endif
  " Remove from cut set in case a previous dd was undone
  let l:path = s:state[l:bufnr].dir . '/' . l:name
  if has_key(s:cut_paths, l:path)
    unlet s:cut_paths[l:path]
  endif
  normal! yy
endfunction

" Set up the explorer buffer
function! s:SetupBuffer(dir) abort
  let l:bufnr = bufnr('%')

  " Buffer-local settings
  setlocal buftype=acwrite      " We handle writes ourselves via BufWriteCmd
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal filetype=vimexplorer
  setlocal nolist
  setlocal nowrap
  setlocal nonumber
  setlocal norelativenumber
  setlocal nobuflisted
  setlocal statusline=%!vimexplorer#StatusLine()

  " Initialise or update state for this buffer
  if !has_key(s:state, l:bufnr)
    let s:state[l:bufnr] = {}
  endif
  let s:state[l:bufnr].dir         = a:dir
  let s:state[l:bufnr].names       = []
  let s:state[l:bufnr].show_hidden   = get(s:state[l:bufnr], 'show_hidden',   g:vimexplorer_show_hidden)
  let s:state[l:bufnr].detail        = get(s:state[l:bufnr], 'detail',        g:vimexplorer_detail)
  let s:state[l:bufnr].show_header   = get(s:state[l:bufnr], 'show_header',   g:vimexplorer_show_header)

  " Key mappings (buffer-local)
  nnoremap <buffer> <silent> <CR>   :call vimexplorer#Enter()<CR>
  nnoremap <buffer> <silent> -      :call vimexplorer#Up()<CR>
  nnoremap <buffer> <silent> <BS>   :call vimexplorer#Up()<CR>
  nnoremap <buffer> <silent> gh     :call vimexplorer#ToggleHidden()<CR>
  nnoremap <buffer> <silent> gd     :call vimexplorer#ToggleDetail()<CR>
  nnoremap <buffer> <silent> <C-v>  :call vimexplorer#OpenSplit(1)<CR>
  nnoremap <buffer> <silent> <C-s>  :call vimexplorer#OpenSplit(0)<CR>
  nnoremap <buffer> <silent> R      :call vimexplorer#Refresh()<CR>
  nnoremap <buffer> <silent> q      :bdelete<CR>
  nnoremap <buffer> <silent> ?      :call vimexplorer#Help()<CR>
  nnoremap <buffer> <silent> dd     :call vimexplorer#Cut()<CR>
  nnoremap <buffer> <silent> yy     :call vimexplorer#Yank()<CR>
endfunction

" Render the buffer contents
function! s:Render(bufnr) abort
  if !has_key(s:state, a:bufnr)
    return
  endif

  let l:st      = s:state[a:bufnr]
  let l:dir     = l:st.dir
  let l:detail  = l:st.detail
  let l:show_h  = l:st.show_hidden

  let l:entries = s:ReadDir(l:dir, l:show_h)

  let l:lines = []
  let l:names = []

  " Header comment (not editable — users should not modify it, but it is
  " just a comment and will be ignored during save parsing)
  if l:st.show_header
    call add(l:lines, '" ' . l:dir)
    call add(l:lines, '" [<CR>] open  [-] up  [gh] hidden  [gd] detail  [?] help')
    call add(l:lines, '')
  endif

  for l:e in l:entries
    let l:display = s:FormatEntry(l:e, l:detail)
    call add(l:lines, l:display)
    call add(l:names, l:e.name)
  endfor

  " Write into buffer without triggering autocommands
  let l:ma = &l:modifiable
  setlocal modifiable
  silent call deletebufline(a:bufnr, 1, '$')
  silent call setbufline(a:bufnr, 1, l:lines)
  setlocal nomodified
  if !l:ma
    setlocal nomodifiable
  endif

  let l:st.names = l:names
endfunction

" Read and sort directory entries
function! s:ReadDir(dir, show_hidden) abort
  let l:all = glob(a:dir . '/*', 0, 1)
  if a:show_hidden
    let l:hidden = glob(a:dir . '/.*', 0, 1)
    " Remove . and ..
    let l:hidden = filter(l:hidden, 'v:val !~# "/\\.\\.$" && v:val !~# "/\\.$"')
    let l:all = l:hidden + l:all
  endif

  let l:entries = []
  for l:path in l:all
    let l:name = fnamemodify(l:path, ':t')
    if l:name ==# ''
      continue
    endif
    let l:is_dir = isdirectory(l:path)
    let l:entry  = {
          \ 'name':   l:name,
          \ 'path':   l:path,
          \ 'is_dir': l:is_dir,
          \ 'size':   l:is_dir ? '' : s:HumanSize(getfsize(l:path)),
          \ 'perms':  s:FilePerms(l:path),
          \ }
    call add(l:entries, l:entry)
  endfor

  " Sort dirs first, then alphabetical (case-insensitive)
  call sort(l:entries, function('s:CompareEntries'))
  return l:entries
endfunction

" Format a single entry for display
function! s:FormatEntry(entry, detail) abort
  let l:suffix = a:entry.is_dir ? '/' : ''
  let l:name   = a:entry.name . l:suffix

  if a:detail
    let l:size  = printf('%6s', a:entry.size)
    let l:perms = a:entry.perms
    return l:perms . '  ' . l:size . '  ' . l:name
  else
    return l:name
  endif
endfunction

" Get name under cursor (strips detail prefix)
function! s:NameUnderCursor() abort
  let l:line = getline('.')
  if l:line =~# '^"' || l:line =~# '^\s*$'
    return ''
  endif

  let l:bufnr = bufnr('%')
  let l:detail = get(get(s:state, l:bufnr, {}), 'detail', 0)

  if l:detail
    " Format: "rwxr-xr-x   1.2K  filename"
    " Strip leading perms (10 chars) + 2 spaces + size (6 chars) + 2 spaces
    let l:name = substitute(l:line, '^\S\{10\}\s\+\S*\s\+', '', '')
  else
    let l:name = l:line
  endif

  let l:name = substitute(l:name, '/$', '', '')
  return trim(l:name)
endfunction

" Parse buffer lines into name list (for Save)
function! s:ParseLines(lines) abort
  let l:names = []
  for l:line in a:lines
    if l:line =~# '^"' || l:line =~# '^\s*$'
      continue
    endif

    let l:bufnr = bufnr('%')
    let l:detail = get(get(s:state, l:bufnr, {}), 'detail', 0)

    if l:detail
      let l:name = substitute(l:line, '^\S\{10\}\s\+\S*\s\+', '', '')
    else
      let l:name = l:line
    endif

    " Do NOT strip the trailing slash here — Save() uses it to detect
    " that the user wants a directory created, not a file.
    let l:name = trim(l:name)
    if l:name !=# ''
      call add(l:names, l:name)
    endif
  endfor
  return l:names
endfunction

" Sort comparator: dirs first, then alphabetical
function! s:CompareEntries(a, b) abort
  if a:a.is_dir && !a:b.is_dir | return -1 | endif
  if !a:a.is_dir && a:b.is_dir | return  1 | endif
  let l:la = tolower(a:a.name)
  let l:lb = tolower(a:b.name)
  return l:la ==# l:lb ? 0 : l:la <# l:lb ? -1 : 1
endfunction

" Human-readable file size
function! s:HumanSize(bytes) abort
  if a:bytes < 0
    return '?'
  elseif a:bytes < 1024
    return a:bytes . 'B'
  elseif a:bytes < 1024 * 1024
    return (a:bytes / 1024) . 'K'
  elseif a:bytes < 1024 * 1024 * 1024
    return (a:bytes / 1024 / 1024) . 'M'
  else
    return (a:bytes / 1024 / 1024 / 1024) . 'G'
  endif
endfunction

" File permissions string
function! s:FilePerms(path) abort
  " Use getfperm() — returns e.g. "rwxr-xr-x"
  let l:perms = getfperm(a:path)
  if l:perms ==# ''
    return '----------'
  endif
  " Prefix with d for directories, - for files, l for links
  if isdirectory(a:path)
    return 'd' . l:perms
  elseif getftype(a:path) ==# 'link'
    return 'l' . l:perms
  else
    return '-' . l:perms
  endif
endfunction

" Status line helper
function! vimexplorer#StatusLine() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return ''
  endif
  let l:st  = s:state[l:bufnr]
  let l:h   = l:st.show_hidden ? '[H]' : ''
  let l:d   = l:st.detail      ? '[D]' : ''
  return ' VimExplorer  ' . l:st.dir . '  ' . l:h . l:d
endfunction

" Find a file by name in any other open explorer buffer
" Returns the full path if found, or '' if not found or same directory.
function! s:FindInOtherBuffers(name, current_dir) abort
  for [l:bufnr, l:st] in items(s:state)
    if l:st.dir ==# a:current_dir
      continue
    endif
    let l:candidate = l:st.dir . '/' . a:name
    if filereadable(l:candidate) || isdirectory(l:candidate)
      return l:candidate
    endif
  endfor
  return ''
endfunction

" Show help
function! vimexplorer#Help() abort
  echo ''
  echo 'VimExplorer key bindings'
  echo '────────────────────────'
  echo '<CR>    Open file / enter directory'
  echo '-       Go up one directory'
  echo '<BS>    Go up one directory'
  echo 'gh      Toggle hidden files'
  echo 'gd      Toggle detail mode (size + perms)'
  echo '<C-v>   Open file in vertical split'
  echo '<C-s>   Open file in horizontal split'
  echo 'R       Refresh listing'
  echo ':w      Apply pending renames / deletions / creations / moves / copies'
  echo 'q       Close explorer'
  echo '?       Show this help'
  echo ''
  echo 'Editing:'
  echo '  Rename  - change the filename on its line, then :w'
  echo '  Delete  - dd to delete the line, then :w (confirmation prompt)'
  echo '  Create  - add a new line with the name, then :w (confirmation prompt)'
  echo '            end name with / to create a directory'
  echo '            nested paths are supported: new_dir/file.txt'
  echo '  Yank    - yy to copy a file name, paste in another explorer buffer'
  echo '            then :w in the destination to copy the file'
  echo '  Move    - dd to cut a file name, paste in another explorer buffer'
  echo '            then :w in the destination to move the file'
endfunction
