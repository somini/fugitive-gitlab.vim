if exists('g:autoloaded_fugitive_gitlab')
    finish
endif
let g:autoloaded_fugitive_gitlab = 1

function! gitlab#fugitive_handler(opts, ...)
    let path   = substitute(get(a:opts, 'path', ''), '^/', '', '')
    let line1  = get(a:opts, 'line1')
    let line2  = get(a:opts, 'line2')
    let remote = get(a:opts, 'remote')

    let domains = exists('g:fugitive_gitlab_domains') ? g:fugitive_gitlab_domains : []
    let rel_path = {}

    let domain_pattern = 'gitlab\.com'
    for domain in domains
        let domain = escape(split(domain, '://')[-1], '.')
        let domain_path = matchstr(domain, '/')
        if domain_path ==# '/'
            let domain_path = substitute(domain,'^[^/]*/','','')
        else
            let domain_path = ''
        endif
        let domain_root = split(domain, '/')[0]
        let domain_pattern .= '\|' . domain_root
        let rel_path[domain_root] = domain_path
    endfor

    " Try and extract a domain name from the remote
    " See https://git-scm.com/book/en/v2/Git-on-the-Server-The-Protocols for the types of protocols.
    " If we can't extract the domain, we don't understand this protocol.
    " git://domain:path
    " https://domain/path
    let repo = matchstr(remote,'^\%(https\=://\|git://\|git@\)\=\zs\('.domain_pattern.'\)[/:].\{-\}\ze\%(\.git\)\=$')
    " ssh://user@domain:port/path.git
    if repo ==# ''
        let repo = matchstr(remote,'^\%(ssh://\%(\w*@\)\=\)\zs\('.domain_pattern.'\).\{-\}\ze\%(\.git\)\=$')
        let repo = substitute(repo, ':[0-9]\+', '', '')
    endif
    if repo ==# ''
        return ''
    endif

    " look for http:// + repo in the domains array
    " if it exists, prepend http, otherwise https
    " git/ssh URLs contain : instead of /, http ones don't contain :
    let repo_root = escape(split(split(repo, '://')[-1],':')[0], '.')
    let repo_path = get(rel_path, repo_root, '')
    if repo_path ==# ''
        let repo = substitute(repo,':','/','')
    else
        let repo = substitute(repo,':','/' . repo_path . '/','')
    endif
    if index(domains, 'http://' . matchstr(repo, '^[^:/]*')) >= 0
        let root = 'http://' . repo
    else
        let root = 'https://' . repo
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

" vim: set ts=4 sw=4 et