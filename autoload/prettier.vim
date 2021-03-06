let s:root_dir = fnamemodify(resolve(expand('<sfile>:p')), ':h')
let s:prettier_job_running = 0

function! prettier#Prettier(...) abort
  let l:execCmd = s:Get_Prettier_Exec()
  let l:async = a:0 > 0 ? a:1 : 0 
  let l:config = getbufvar(bufnr('%'), 'prettier_ft_default_args', {})

  if l:execCmd != -1
    let l:cmd = l:execCmd . s:Get_Prettier_Exec_Args(l:config)

    " close quickfix
    call setqflist([])
    cclose

    if l:async && v:version >= 800 && exists('*job_start')
      call s:Prettier_Exec_Async(l:cmd)
    else
      call s:Prettier_Exec_Sync(l:cmd)
    endif
  else
    call s:Suggest_Install_Prettier()
  endif
endfunction

function! prettier#Autoformat() abort
  let l:curPos = getpos('.')
  let l:maxLineLookup = 50 
  let l:maxTimeLookupMs = 500 
  let l:pattern = '@format'

  " we need to move selection to the top before looking up to avoid 
  " scanning a very long file
  call cursor(1, 1)

  " Search starting at the start of the document
  if search(l:pattern, 'n', l:maxLineLookup, l:maxTimeLookupMs) > 0
    " autoformat async
    call prettier#Prettier(1) 
  endif

  " Restore the selection and if greater then before it defaults to end
  call cursor(curPos[1], curPos[2])
endfunction

function! s:Prettier_Exec_Sync(cmd) abort 
  let l:out = split(system(a:cmd, getbufline(bufnr('%'), 1, '$')), '\n')

  " check system exit code
  if v:shell_error
    call s:Prettier_Parse_Error(l:out)
    return
  endif

  call s:Apply_Prettier_Format(l:out)
endfunction

function! s:Prettier_Exec_Async(cmd) abort 
  if s:prettier_job_running != 1
      let s:prettier_job_running = 1
      call job_start(a:cmd, {
        \ 'in_io': 'buffer',
        \ 'in_name': bufname('%'),
        \ 'err_cb': 'Prettier_Job_Error',
        \ 'close_cb': 'Prettier_Job_Close' })
  endif
endfunction

function! Prettier_Job_Close(channel) abort 
  let l:out = []

  while ch_status(a:channel, {'part': 'out'}) == 'buffered'
    call add(l:out, ch_read(a:channel))
  endwhile

  " nothing to update
  if (getbufline(bufnr('%'), 1, '$') == l:out)
    let s:prettier_job_running = 0
    return
  endif
  
  if len(l:out) 
    call s:Apply_Prettier_Format(l:out)
    write
    let s:prettier_job_running = 0
  endif
endfunction

function! Prettier_Job_Error(channel, msg) abort 
    call s:Prettier_Parse_Error(split(a:msg, '\n'))
    let s:prettier_job_running = 0
endfunction

function! s:Handle_Parsing_Errors(out) abort
  let l:errors = []

  for line in a:out
    " matches:
    " stdin: SyntaxError: Unexpected token (2:8)
    let l:match = matchlist(line, '^stdin: \(.*\) (\(\d\{1,}\):\(\d\{1,}\)*)')
    if !empty(l:match)
      call add(l:errors, { 'bufnr': bufnr('%'),
                         \ 'text': match[1],
                         \ 'lnum': match[2],
                         \ 'col': match[3] })
    endif
  endfor

  if len(l:errors) 
    call setqflist(l:errors)
    botright copen
  endif
endfunction

function! s:Apply_Prettier_Format(lines) abort
  " store cursor position
  let l:curPos = getpos('.')

  " delete all lines on the current buffer
  silent! execute 1 . ',' . line('$') . 'delete _'

  " replace all lines from the current buffer with output from prettier
  call setline(1, a:lines)

  " restore cursor position
  call cursor(l:curPos[1], l:curPos[2])
endfunction

" By default we will default to our internal
" configuration settings for prettier
function! s:Get_Prettier_Exec_Args(config) abort
  " Allow params to be passed as json format
  " convert bellow usage of globals to a get function o the params defaulting to global
  let l:cmd = ' --print-width ' .
          \ get(a:config, 'printWidth', g:prettier#config#print_width) .
          \ ' --tab-width ' .
          \ get(a:config, 'tabWidth', g:prettier#config#tab_width) .
          \ ' --use-tabs ' .
          \ get(a:config, 'useTabs', g:prettier#config#use_tabs) .
          \ ' --semi ' .
          \ get(a:config, 'semi', g:prettier#config#semi) .
          \ ' --single-quote ' .
          \ get(a:config, 'singleQuote', g:prettier#config#single_quote) .
          \ ' --bracket-spacing ' .
          \ get(a:config, 'bracketSpacing', g:prettier#config#bracket_spacing) .
          \ ' --jsx-bracket-same-line ' .
          \ get(a:config, 'jsxBracketSameLine', g:prettier#config#jsx_bracket_same_line) .
          \ ' --trailing-comma ' .
          \ get(a:config, 'trailingComma', g:prettier#config#trailing_comma) .
          \ ' --parser ' .
          \ get(a:config, 'parser', g:prettier#config#parser) .
          \ ' --stdin '
  return cmd
endfunction

" By default we will search for the following
" => locally installed prettier inside node_modules on any parent folder
" => globally installed prettier 
" => vim-prettier prettier installation
" => if all fails suggest install
function! s:Get_Prettier_Exec() abort
  let l:local_exec = s:Get_Prettier_Local_Exec()
  if executable(l:local_exec)
    return l:local_exec
  endif 

  let l:global_exec = s:Get_Prettier_Global_Exec()
  if executable(l:global_exec)
    return l:global_exec
  endif 

  let l:plugin_exec = s:Get_Prettier_Plugin_Exec()
  if executable(l:plugin_exec)
    return l:plugin_exec
  endif 

  return -1
endfunction

function! s:Get_Prettier_Local_Exec() abort
  return s:Get_Exec(getcwd())
endfunction

function! s:Get_Prettier_Global_Exec() abort
  return s:Get_Exec()
endfunction

function! s:Get_Prettier_Plugin_Exec() abort
  return s:Get_Exec(s:root_dir)
endfunction

function! s:Get_Exec(...) abort
  let l:rootDir = a:0 > 0 ? a:1 : 0 
  let l:exec = -1

  if isdirectory(l:rootDir) 
    let l:dir = s:Tranverse_Dir_Search(l:rootDir) 
    if dir != -1
      let l:exec = s:Get_Path_To_Exec(l:dir)
    endif
  else
    let l:exec = s:Get_Path_To_Exec()
  endif

  return exec
endfunction

function! s:Get_Path_To_Exec(...) abort
  let l:rootDir = a:0 > 0 ? a:1 : -1 
  let l:dir = l:rootDir != -1 ? l:rootDir . '/.bin/' : '' 
  return dir . 'prettier'
endfunction

function! s:Tranverse_Dir_Search(rootDir) abort
  let l:root = a:rootDir
  let l:dir = 'node_modules'

  while 1
    let l:search_dir = root . '/' . dir
    if isdirectory(l:search_dir) 
      return l:search_dir
    endif

    let l:parent = fnamemodify(root, ':h')
    if l:parent == l:root 
      return -1
    endif

    let l:root = l:parent
  endwhile
endfunction

function! s:Prettier_Parse_Error(errors) abort
  echohl WarningMsg | echom 'Prettier: failed to parse buffer.' | echohl NONE
  if g:prettier#quickfix_enabled
    call s:Handle_Parsing_Errors(a:errors)
  endif
endfunction

" If we can't find any prettier installing we then suggest where to get it from
function! s:Suggest_Install_Prettier() abort
  echohl WarningMsg | echom 'Prettier: no prettier executable installation found.' | echohl NONE
endfunction
