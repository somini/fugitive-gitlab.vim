if exists('g:autoloaded_fugitive_gitlab')
    finish
endif
let g:autoloaded_fugitive_gitlab = 1

function! gitlab#fugitive_handler(opts, ...)
    let path   = substitute(get(a:opts, 'path', ''), '^/', '', '')
    let line1  = get(a:opts, 'line1')
    let line2  = get(a:opts, 'line2')
    let remote = get(a:opts, 'remote')

    let root = gitlab#homepage_for_remote(remote)
    if empty(root)
        return ''
    endif

    " work out what branch/commit/tag/etc we're on
    " if file is a git/ref, we can go to a /commits gitlab url
    " If the branch/tag doesn't exist upstream, the URL won't be valid
    " Could check upstream refs?
    if path =~# '^\.git/refs/heads/'
        return root . '/commits/' . path[16:-1]
    elseif path =~# '^\.git/refs/tags/'
        return root . '/tags/' . path[15:-1]
    elseif path =~# '^\.git/refs/.'
        return root . '/commits/' . path[10:-1]
    elseif path =~# '^\.git\>'
        return root
    endif

    " Work out the commit
    if a:opts.commit =~# '^\d\=$'
        let commit = a:opts.repo.rev_parse('HEAD')
    else
        let commit = a:opts.commit
    endif

    " If buffer contains directory not file, return a /tree url
    let path = get(a:opts, 'path', '')
    if get(a:opts, 'type', '') ==# 'tree' || path =~# '/$'
        let url = substitute(root . '/tree/' . commit . '/' . path,'/$','', '')
    elseif get(a:opts, 'type', '') ==# 'blob' || path =~# '[^/]$'
        let url = root . "/blob/" . commit . '/' . path
        if line2 && line1 == line2
            let url .= '#L'.line1
        elseif line2
            let url .= '#L' . line1 . '-' . line2
        endif
    else
        let url = root . '/commit/' . commit
    endif

    return url
endfunction

function! gitlab#homepage_for_remote(remote) abort
    let domains = exists('g:fugitive_gitlab_domains') ? g:fugitive_gitlab_domains : []
    call map(copy(domains), 'substitute(v:val, "/$", "", "")')
    let domain_pattern = 'gitlab\.com'
    for domain in domains
        let domain_pattern .= '\|' . escape(split(domain, '://')[-1], '.')
    endfor

    " git://domain:path
    " https://domain/path
    " ssh://git@domain/path.git
    let base = matchstr(a:remote, '^\%(https\=://\|git://\|git@\|ssh://git@\)\=\zs\('.domain_pattern.'\)[/:].\{-\}\ze\%(\.git\)\=$')

    if index(domains, 'http://' . matchstr(base, '^[^:/]*')) >= 0
        return 'http://' . tr(base, ':', '/')
    elseif !empty(base)
        return 'https://' . tr(base, ':', '/')
    else
        return ''
    endif
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Gitlab API related things
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! gitlab#json_parse(string) abort
    if exists('*json_decode')
        return json_decode(a:string)
    endif
    let [null, false, true] = ['', 0, 1]
    let stripped = substitute(a:string,'\C"\(\\.\|[^"\\]\)*"','','g')
    if stripped !~# "[^,:{}\\[\\]0-9.\\-+Eaeflnr-u \n\r\t]"
        try
            return eval(substitute(a:string,"[\r\n]"," ",'g'))
        catch
        endtry
    endif
    call s:throw("invalid JSON: ".a:string)
endfunction

function! gitlab#json_generate(object) abort
    if exists('*json_encode')
        return json_encode(a:object)
    endif
    if type(a:object) == type('')
        return '"' . substitute(a:object, "[\001-\031\"\\\\]", '\=printf("\\u%04x", char2nr(submatch(0)))', 'g') . '"'
    elseif type(a:object) == type([])
        return '['.join(map(copy(a:object), 'gitlab#json_generate(v:val)'),', ').']'
    elseif type(a:object) == type({})
        let pairs = []
        for key in keys(a:object)
            call add(pairs, gitlab#json_generate(key) . ': ' . gitlab#json_generate(a:object[key]))
        endfor
        return '{' . join(pairs, ', ') . '}'
    else
        return string(a:object)
    endif
endfunction

function! s:gitlab_api_key(root) abort
    if exists('b:gitlab_api_key')
        return b:gitlab_api_key
    endif

    " gitlab_api_keys: { "gitlab.com": "myapitoken" }
    if exists('g:gitlab_api_keys')
        let keys = items(g:gitlab_api_keys)
        for item in keys
            if match(a:root, item[0]) >= 0
                return item[1]
            endif
        endfor
    endif

    call s:throw('Missing g:gitlab_api_keys')
endfunction

function! gitlab#api_paths_for_remote(remote) abort
    let homepage = gitlab#homepage_for_remote(a:remote)

    if empty(homepage)
        call s:throw('Not a gitlab repo')
    endif

    let domains = exists('g:fugitive_gitlab_domains') ? g:fugitive_gitlab_domains : []
    call map(copy(domains), 'substitute(v:val, "/$", "", "")')
    call extend(domains, ['https://gitlab.com'])

    for domain in domains
        let path = substitute(homepage, '^'.domain . '/', '', '')
        if path != homepage
            let project = substitute(path, '/', '%2F', 'g')
            let root = domain . '/api/v4'
            break
        endif
    endfor

    if len(root) < 1
        call s:throw(a:remote . " is not a known gitlab remote")
    endif

    return {'root': root, 'project': project}
endfunction

function! s:gitlab_project_from_repo(...) abort
    let repo = fugitive#repo()

    let validremote = '\.\|\.\=/.*\|[[:alnum:]_-]\+\%(://.\{-\}\)\='
    if len(a:000) > 0
        let remote = matchstr(join(a:000, ' '),'@\zs\%('.validremote.'\)$')
    else
        let remote = 'origin'
    endif
    echomsg "remote: ".remote

    if fugitive#git_version() =~# '^[01]\.\|^2\.[0-6]\.'
        let raw = repo.git_chomp('config', 'remote.'.remote.'.url')
    else
        let raw = repo.git_chomp('remote', 'get-url', remote)
    endif
    echomsg "raw: " . raw

    return gitlab#api_paths_for_remote(raw)
endfunction

" Makes a request to the api and returns the resulting text
function! gitlab#request(domain, path, ...) abort
    let key = s:gitlab_api_key(a:domain)

    let url = a:domain . a:path

    let headers = [
        \'PRIVATE-TOKEN: ' . key,
        \'Content-Type: application/json',
        \'Accept: application/json',
    \]

    if a:0
        let json = gitlab#json_generate(a:0)
    endif
    
    if exists('*Post')
        if exists('json')
            let raw = Post(url, headers, json)
        else
            let raw = Post(url, headers)
        endif
        return gitlab#json_parse(raw)
    endif

    if !executable('curl')
        call s:throw('cURL is required')
    endif

    let data = ['-q', '--silent', 'A', 'fugitive-gitlab.vim']
    for header in headers
        call extend(data, ['-H', header])
    endfor
    if a:0
        let temp = tempfile()
        writefile([json], temp)
        call extend(data, ['-XPOST'])
        call extend(data, ['--data', '@'.temp])
    endif

    call extend(data, headers)
    call extend(data, [url])

    let options = join(map(copy(data), 'shellescape(v:val)'), ' ')
    let raw = system('curl '.options)

    return gitlab#json_parse(raw)
endfunction

function! gitlab#issues(params, ...) abort
    let res = call('s:gitlab_project_from_repo', a:000)

    let path = '/projects/' . res.project . '/issues'
    let params = '?scope=all&state=opened&per_page=100'
    let params .= '&search='.a:params
    return gitlab#request(res.root, path . params)
endfunction

let s:reference = '\<\%(\c\%(clos\|resolv\|referenc\)e[sd]\=\|\cfix\%(e[sd]\)\=\)\>'
function! gitlab#omnifunc(findstart, base) abort
    " Currently omnicompletion requires origin this is the same as rhubarb
    let remote = 'origin'

    if a:findstart
        let existing = matchstr(getline('.')[0:col('.')-1],s:reference.'\s\+\zs[^#/,.;]*$\|[#@[:alnum:]-]*$')
        return col('.')-1-strlen(existing)
    endif
    try
        if a:base =~# '^@'
            call s:throw('Users possibly coming soon?')
        else
            if a:base =~# '^#'
                let prefix = '#'
            else
                let repo = fugitive#repo()
                let homepage = gitlab#homepage_for_remote(repo.config('remote.'.remote.'.url'))
                let prefix = homepage . '/issues/'
            endif
            " this differ to rhubarb slightly,
            " we always search for the search term, unless its purely a number
            if a:base =~# '^#\=\d\+$'
                let query = ''
            else
                let query = substitute(a:base, '#', '', '')
            endif

            let response = gitlab#issues(query, '@'.remote)
            if type(response) != type([])
                call s:throw('unknown error')
            endif
            return map(response, '{"word": prefix . v:val.iid, "abbr": "#".v:val.iid, "menu": v:val.title, "info": substitute(v:val.description,"\\r","","g")}')
        endif
    catch /^\%(fugitive\|gitlab\):/
        echoerr v:errmsg
    endtry
        
endfunction

function! s:throw(string) abort
    let v:errmsg = 'gitlab: '.a:string
    throw v:errmsg
endfunction

" vim: set ts=4 sw=4 et
