if vim.b.current_syntax then
    return
end

vim.cmd([[syntax keyword AlpackaLabel branch dir contained]])
vim.cmd([[syntax keyword AlpackaModified MODIFIED contained]])
vim.cmd([[syntax match AlpackaPluginName "^> \zs\S\+"]])
vim.cmd([[syntax match AlpackaHelpTag " \u[a-zA-Z ]* \[.\{1,5}\] "]])
vim.cmd([[syntax match AlpackaCommitHash "^   [a-z0-9]\{7,} "]])
vim.cmd([[syntax match AlpackaCommitDate "(\d\{4}-\d\{2}-\d\{2})"]])
vim.cmd([[syntax match AlpackaComment ";;.*" contains=CONTAINED]])
vim.cmd([[syntax match AlpackaLockEntry "^- \zs.*"]])

vim.api.nvim_set_hl(0, 'AlpackaLabel', {
    default = true,
    link = 'DiagnosticHint',
})

vim.api.nvim_set_hl(0, 'AlpackaModified', {
    default = true,
    link = 'DiagnosticWarn',
})

vim.api.nvim_set_hl(0, 'AlpackaPluginName', {
    default = true,
    link = 'Keyword',
})

vim.api.nvim_set_hl(0, 'AlpackaHelpTag', {
    default = true,
    link = 'CursorLine',
})

vim.api.nvim_set_hl(0, 'AlpackaCommitHash', {
    default = true,
    link = 'String',
})

vim.api.nvim_set_hl(0, 'AlpackaCommitDate', {
    default = true,
    link = 'Comment',
})

vim.api.nvim_set_hl(0, 'AlpackaComment', {
    default = true,
    link = 'Comment',
})

vim.api.nvim_set_hl(0, 'AlpackaLockEntry', {
    default = true,
    link = 'DiagnosticInfo',
})

vim.b.current_syntax = 'alpacka'
