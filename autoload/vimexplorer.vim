" autoload/vimexplorer.vim

let s:state = {}
let s:cut_paths = {}   " distinguish move from copy on paste
let s:yank_paths = {}  " only explicitly yanked paths eligible for copy
let s:pending_pastes = {} " {bufnr: [{pasted_name, src_path}]} — survives rename before :w

function! vimexplorer#Open(path) abort
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
    execute 'edit ' . escape(l:bufname, ' \%#')
  endif

  call s:SetupBuffer(l:dir)
  call s:Render(bufnr('%'))
endfunction

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

  " old_only entries not consumed by rename are true deletions
  let l:to_delete = l:old_only[l:ri :]

  if !empty(l:to_delete)
    let l:ans = input('VimExplorer: delete ' . len(l:to_delete) . ' item(s)? [y/N] ')
    if l:ans !~? '^y'
      echo "\nAborted."
      call s:Render(l:bufnr)
      return
    endif
    echo ''
  endif

  if !empty(l:to_rename)
    let l:ans = input('VimExplorer: rename ' . len(l:to_rename) . ' item(s)? [y/N] ')
    if l:ans !~? '^y'
      echo "\nAborted."
      call s:Render(l:bufnr)
      return
    endif
    echo ''
  endif

  for [l:old, l:new] in l:to_rename
    let l:new_bare = substitute(l:new, '/$', '', '')
    if l:new_bare =~# '/'
      echohl ErrorMsg
      echo 'VimExplorer: rename across directories not supported: ' . l:new
      echohl None
      continue
    endif
    let l:src = l:dir . '/' . l:old
    let l:dst = l:dir . '/' . l:new_bare
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

  if !empty(l:new_files)
    let l:ans = input('VimExplorer: create ' . len(l:new_files) . ' item(s)? [y/N] ')
    if l:ans !~? '^y'
      echo "\nAborted."
      call s:Render(l:bufnr)
      return
    endif
    echo ''
  endif

  for l:name in l:new_files
    if l:name =~# '/$'
      let l:bare  = l:name[:-2]
      let l:dname = l:dir . '/' . l:bare
      let l:src_path = s:FindInOtherBuffers(l:bare, l:dir)
      if l:src_path !=# ''
        if has_key(s:cut_paths, l:src_path)
          if rename(l:src_path, l:dname) !=# 0
            echohl ErrorMsg | echo 'VimExplorer: failed to move dir: ' . l:src_path | echohl None
          else
            unlet s:cut_paths[l:src_path]
            echo 'Moved: ' . l:src_path . ' → ' . l:dname
          endif
        else
          let l:out = system('cp -r ' . shellescape(l:src_path) . ' ' . shellescape(l:dname))
          if v:shell_error !=# 0
            echohl ErrorMsg | echo 'VimExplorer: failed to copy dir: ' . l:src_path | echohl None
          else
            if has_key(s:yank_paths, l:src_path)
              unlet s:yank_paths[l:src_path]
            endif
            echo 'Copied: ' . l:src_path . ' → ' . l:dname
          endif
        endif
      else
        if mkdir(l:dname, 'p') ==# 0
          echohl ErrorMsg | echo 'VimExplorer: failed to create dir: ' . l:dname | echohl None
        else
          echo 'Created dir: ' . l:name
        endif
      endif
    else
      let l:fpath = l:dir . '/' . l:name
      let l:src_path = s:FindInOtherBuffers(l:name, l:dir)
      if l:src_path ==# ''
        let l:src_path = s:ConsumePendingPaste(l:bufnr, l:name, l:new_names_bare, l:dir)
      endif
      if l:src_path !=# ''
        let l:fparent = fnamemodify(l:fpath, ':h')
        if !isdirectory(l:fparent)
          call mkdir(l:fparent, 'p')
        endif
        if has_key(s:cut_paths, l:src_path)
          if rename(l:src_path, l:fpath) !=# 0
            echohl ErrorMsg | echo 'VimExplorer: failed to move to: ' . l:fpath | echohl None
          else
            unlet s:cut_paths[l:src_path]
            echo 'Moved: ' . l:src_path . ' → ' . l:fpath
          endif
        else
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
              if has_key(s:yank_paths, l:src_path)
                unlet s:yank_paths[l:src_path]
              endif
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

  if has_key(s:pending_pastes, l:bufnr)
    unlet s:pending_pastes[l:bufnr]
  endif
  call s:Render(l:bufnr)
  setlocal nomodified
endfunction

function! vimexplorer#Refresh() abort
  let l:bufnr = bufnr('%')
  if has_key(s:state, l:bufnr)
    call s:SetupBuffer(s:state[l:bufnr].dir)
    call s:Render(l:bufnr)
  endif
endfunction

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

function! vimexplorer#ToggleHidden() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:st = s:state[l:bufnr]
  let l:st.show_hidden = !l:st.show_hidden
  call s:Render(l:bufnr)
endfunction

function! vimexplorer#ToggleDetail() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:st = s:state[l:bufnr]
  let l:st.detail = !l:st.detail
  call s:Render(l:bufnr)
endfunction

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
  if has_key(s:yank_paths, l:path)
    unlet s:yank_paths[l:path]
  endif
  normal! dd
endfunction

function! vimexplorer#CutVisual() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:dir = s:state[l:bufnr].dir
  let l:start = line("'<")
  let l:end   = line("'>")
  for l:lnum in range(l:start, l:end)
    let l:line = getline(l:lnum)
    if l:line =~# '^"' || l:line =~# '^\s*$'
      continue
    endif
    let l:detail = get(get(s:state, l:bufnr, {}), 'detail', 0)
    if l:detail && l:line =~# '^\S\{10\}\s'
      let l:name = l:line[20:]
    else
      let l:name = l:line
    endif
    let l:name = trim(substitute(l:name, '/$', '', ''))
    if l:name !=# ''
      let l:path = l:dir . '/' . l:name
      let s:cut_paths[l:path] = 1
    endif
  endfor
  normal! gvd
endfunction

function! vimexplorer#CopyPath() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:name = s:NameUnderCursor()
  if l:name ==# ''
    return
  endif
  let l:path = s:state[l:bufnr].dir . '/' . l:name
  call setreg('+', l:path)
  call setreg('"', l:path)
  echo 'Copied: ' . l:path
endfunction

function! vimexplorer#Yank() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:name = s:NameUnderCursor()
  if l:name ==# ''
    return
  endif
  let l:path = s:state[l:bufnr].dir . '/' . l:name
  " Remove from cut set in case a previous dd was undone
  if has_key(s:cut_paths, l:path)
    unlet s:cut_paths[l:path]
  endif
  let s:yank_paths[l:path] = 1
  normal! yy
endfunction

function! vimexplorer#YankVisual() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    return
  endif
  let l:dir = s:state[l:bufnr].dir
  let l:start = line("'<")
  let l:end   = line("'>")
  for l:lnum in range(l:start, l:end)
    let l:line = getline(l:lnum)
    if l:line =~# '^"' || l:line =~# '^\s*$'
      continue
    endif
    let l:detail = get(get(s:state, l:bufnr, {}), 'detail', 0)
    if l:detail && l:line =~# '^\S\{10\}\s'
      let l:name = l:line[20:]
    else
      let l:name = l:line
    endif
    let l:name = trim(substitute(l:name, '/$', '', ''))
    if l:name !=# ''
      let l:path = l:dir . '/' . l:name
      if has_key(s:cut_paths, l:path)
        unlet s:cut_paths[l:path]
      endif
      let s:yank_paths[l:path] = 1
    endif
  endfor
  normal! gvy
endfunction

function! vimexplorer#Paste(cmd) abort
  let l:bufnr = bufnr('%')
  if !has_key(s:state, l:bufnr)
    execute 'normal! ' . a:cmd
    return
  endif

  let l:dir = s:state[l:bufnr].dir
  let l:line = split(getreg('"'), "\n")[0]
  let l:detail = get(s:state[l:bufnr], 'detail', 0)
  if l:detail && l:line =~# '^\S\{10\}\s'
    let l:line = l:line[20:]
  endif
  let l:pasted_name = trim(substitute(l:line, '/$', '', ''))

  let l:src = s:FindInOtherBuffers(l:pasted_name, l:dir)
  if l:src ==# ''
    let l:same = l:dir . '/' . l:pasted_name
    if has_key(s:yank_paths, l:same) || has_key(s:cut_paths, l:same)
      let l:src = l:same
    endif
  endif

  execute 'normal! ' . a:cmd

  if l:src !=# ''
    if !has_key(s:pending_pastes, l:bufnr)
      let s:pending_pastes[l:bufnr] = []
    endif
    call add(s:pending_pastes[l:bufnr], {'pasted_name': l:pasted_name, 'src_path': l:src})
  endif
endfunction

" Match a pending paste to a new filename during Save().
" Tries direct name match first, then rename detection:
"   cross-dir: pasted name absent from buffer means user renamed it
"   same-dir:  original file keeps pasted name in buffer forever, so any
"              unresolved new entry is the renamed duplicate
function! s:ConsumePendingPaste(bufnr, new_name, all_new_names, current_dir) abort
  if !has_key(s:pending_pastes, a:bufnr)
    return ''
  endif
  let l:list = s:pending_pastes[a:bufnr]

  for l:i in range(len(l:list))
    if l:list[l:i].pasted_name ==# a:new_name
      let l:src = l:list[l:i].src_path
      call remove(l:list, l:i)
      return l:src
    endif
  endfor

  for l:i in range(len(l:list))
    let l:p = l:list[l:i]
    let l:same_dir_paste = (fnamemodify(l:p.src_path, ':h') ==# a:current_dir)
    if index(a:all_new_names, l:p.pasted_name) ==# -1 || l:same_dir_paste
      let l:src = l:p.src_path
      call remove(l:list, l:i)
      return l:src
    endif
  endfor

  return ''
endfunction

function! s:SetupBuffer(dir) abort
  let l:bufnr = bufnr('%')

  setlocal buftype=acwrite  " writes handled by BufWriteCmd
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal filetype=vimexplorer
  setlocal nolist
  setlocal nowrap
  setlocal nonumber
  setlocal norelativenumber
  setlocal nobuflisted
  setlocal statusline=%!vimexplorer#StatusLine()

  if !has_key(s:state, l:bufnr)
    let s:state[l:bufnr] = {}
  endif
  let s:state[l:bufnr].dir           = a:dir
  let s:state[l:bufnr].names         = []
  let s:state[l:bufnr].show_hidden   = get(s:state[l:bufnr], 'show_hidden',   g:vimexplorer_show_hidden)
  let s:state[l:bufnr].detail        = get(s:state[l:bufnr], 'detail',        g:vimexplorer_detail)
  let s:state[l:bufnr].show_header   = get(s:state[l:bufnr], 'show_header',   g:vimexplorer_show_header)

  nnoremap <buffer> <silent> <CR>   :call vimexplorer#Enter()<CR>
  nnoremap <buffer> <silent> -      :call vimexplorer#Up()<CR>
  nnoremap <buffer> <silent> <BS>   :call vimexplorer#Up()<CR>
  nnoremap <buffer> <silent> gh     :call vimexplorer#ToggleHidden()<CR>
  nnoremap <buffer> <silent> gd     :call vimexplorer#ToggleDetail()<CR>
  nnoremap <buffer> <silent> R      :call vimexplorer#Refresh()<CR>
  nnoremap <buffer> <silent> ?      :call vimexplorer#Help()<CR>
  nnoremap <buffer> <silent> dd     :call vimexplorer#Cut()<CR>
  xnoremap <buffer> <silent> d      :<C-u>call vimexplorer#CutVisual()<CR>
  nnoremap <buffer> <silent> yy     :call vimexplorer#Yank()<CR>
  xnoremap <buffer> <silent> y      :<C-u>call vimexplorer#YankVisual()<CR>
  nnoremap <buffer> <silent> fp     :call vimexplorer#CopyPath()<CR>
  nnoremap <buffer> <silent> p      :call vimexplorer#Paste('p')<CR>
  nnoremap <buffer> <silent> P      :call vimexplorer#Paste('P')<CR>
endfunction

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

function! s:ReadDir(dir, show_hidden) abort
  " Use readdir() not glob() — glob breaks on names with [ ] { } *
  let l:names = readdir(a:dir)
  if !a:show_hidden
    let l:names = filter(l:names, 'v:val[0] !=# "."')
  endif

  let l:entries = []
  for l:name in l:names
    if l:name ==# ''
      continue
    endif
    let l:path = a:dir . '/' . l:name
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

  call sort(l:entries, function('s:CompareEntries'))
  return l:entries
endfunction

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

function! s:NameUnderCursor() abort
  let l:line = getline('.')
  if l:line =~# '^"' || l:line =~# '^\s*$'
    return ''
  endif

  let l:bufnr = bufnr('%')
  let l:detail = get(get(s:state, l:bufnr, {}), 'detail', 0)

  if l:detail && l:line =~# '^\S\{10\}\s'
    " detail prefix: perms(10) + 2sp + size(6) + 2sp = 20 chars
    let l:name = l:line[20:]
  else
    let l:name = l:line
  endif

  let l:name = substitute(l:name, '/$', '', '')
  return trim(l:name)
endfunction

function! s:ParseLines(lines) abort
  let l:names = []
  for l:line in a:lines
    if l:line =~# '^"' || l:line =~# '^\s*$'
      continue
    endif

    let l:bufnr = bufnr('%')
    let l:detail = get(get(s:state, l:bufnr, {}), 'detail', 0)

    if l:detail && l:line =~# '^\S\{10\}\s'
      " detail prefix: perms(10) + 2sp + size(6) + 2sp = 20 chars
      let l:name = l:line[20:]
    else
      let l:name = l:line
    endif

    " Do NOT strip trailing slash — Save() uses it to detect directory creation
    let l:name = trim(l:name)
    if l:name !=# ''
      call add(l:names, l:name)
    endif
  endfor
  return l:names
endfunction

function! s:CompareEntries(a, b) abort
  if a:a.is_dir && !a:b.is_dir | return -1 | endif
  if !a:a.is_dir && a:b.is_dir | return  1 | endif
  let l:la = tolower(a:a.name)
  let l:lb = tolower(a:b.name)
  return l:la ==# l:lb ? 0 : l:la <# l:lb ? -1 : 1
endfunction

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

function! s:FilePerms(path) abort
  let l:perms = getfperm(a:path)
  if l:perms ==# ''
    return '----------'
  endif
  if isdirectory(a:path)
    return 'd' . l:perms
  elseif getftype(a:path) ==# 'link'
    return 'l' . l:perms
  else
    return '-' . l:perms
  endif
endfunction

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

" Only returns a path if it was explicitly cut or yanked — prevents accidental
" copy when a same-named file exists in another open explorer buffer.
function! s:FindInOtherBuffers(name, current_dir) abort
  for [l:bufnr, l:st] in items(s:state)
    if l:st.dir ==# a:current_dir
      continue
    endif
    let l:candidate = l:st.dir . '/' . a:name
    if (filereadable(l:candidate) || isdirectory(l:candidate))
          \ && (has_key(s:cut_paths, l:candidate) || has_key(s:yank_paths, l:candidate))
      return l:candidate
    endif
  endfor
  return ''
endfunction

function! vimexplorer#Help() abort
  echo ''
  echo 'VimExplorer key bindings'
  echo '────────────────────────'
  echo '<CR>    Open file / enter directory'
  echo '-       Go up one directory'
  echo '<BS>    Go up one directory'
  echo 'gh      Toggle hidden files'
  echo 'gd      Toggle detail mode (size + perms)'
  echo 'R       Refresh listing'
  echo 'fp      Copy absolute path to clipboard'
  echo ':w      Apply pending renames / deletions / creations / moves / copies'
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
