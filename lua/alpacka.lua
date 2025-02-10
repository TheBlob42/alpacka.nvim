local M = {}

-- ~~~~~~~~~~~~~~~~~
--  Classes & Types
-- ~~~~~~~~~~~~~~~~~

---@class AlpackaPluginSpec
---@field load (fun(name: string, spec: AlpackaPluginSpec): boolean)? Should the plugin be loaded
---@field build fun(name: string, spec: AlpackaPluginSpec)? Function to call after plugin is installed or updated. This function is called with the cwd set to the plugin directory if you need to call scripts or compile components
---@field config fun(name: string, spec: AlpackaPluginSpec)? Function to call after plugin has been loaded
---@field init fun(name: string, spec: AlpackaPluginSpec)? Function to call before the plugin will be loaded
---@field dir string? Local directory to use instead of cloning the plugin from git

---@class AlpackaLockFileSpec
---@field hash string Git hash of the plugin

-- ~~~~~~~~~~~~~~~~~~
--  Script Variables
-- ~~~~~~~~~~~~~~~~~~

---Plugin registry for all plugins managed by alpacka
---@type { [string]: AlpackaPluginSpec }
local alpacka_plugins = {}

---Lock state for all plugins managed by alpacka
---@type { [string]: AlpackaLockFileSpec }
local lock = {}

---@diagnostic disable-next-line: param-type-mismatch
local packpath = vim.fs.joinpath(vim.fn.stdpath('data'), 'site', 'pack', 'alpacka', 'opt')

---@diagnostic disable-next-line: param-type-mismatch
local lockfile = vim.fs.joinpath(vim.fn.stdpath('config'), 'alpacka-lock.json')

-- ~~~~~~~~~~~~~~~~~~~
--  Utility Functions
-- ~~~~~~~~~~~~~~~~~~~

---Capitalize the given string `s`
---```lua
---capitalize('hello') -- 'Hello'
---```
---@param s string
---@return string
local function capitalize(s)
    return s:sub(1,1):upper() .. s:sub(2)
end

---Resolve given string `s` into a valid git URL
---If it does not match a valid git URL already we assume this is a short Github repository description and edit it accordingly
---@param s string
---@return string
local function get_git_url(s)
    if not s:match('^http.*%.git$') then
       return string.format('https://github.com/%s.git', s)
    end
    return s
end

---Extract the plugin name from the given git URL
---Also works with short Github repository descriptions
---@param url string The plugin URL
---@return string name The extracted plugin name
local function get_plugin_name(url)
    url = get_git_url(url)
    return url:match('^.*/(.*)%.git')
end

---Delete the element at `path`
---If the element is a directory, delete its children recursively
---@param path string The element to delete
---@param type string? Optional type of the element (mainly used by recursive calls)
---@return boolean success If the delete operation was successful
---@return string? error Error message in case something did go wrong
local function delete(path, type)
    local t = type or vim.uv.fs_lstat(path).type

    if t == 'directory' then
        local data, scan_error = vim.uv.fs_scandir(path)
        if scan_error then
            return false, scan_error
        end
        assert(data)

        while true do
            local next_name, next_type = vim.uv.fs_scandir_next(data)
            if not next_name then
                break
            end

            local _, error = delete(vim.fs.joinpath(path, next_name), next_type)
            if error then
                return false, error
            end
        end

        local _, error = vim.uv.fs_rmdir(path)
        if error then
            return false, error
        end
    else
        local _, error = vim.uv.fs_unlink(path)
        if error then
            return false, error
        end
    end

    return true, nil
end

---Helper function to ease usage of asynchronous `vim.system` calls
---
---## Example
---
---Instead of nesting callbacks like this:
---```lua
---vim.system({ 'unzip', 'big.zip' }, { text = true }, function(_)
---    vim.system({ 'ls' }, { text = true }, function(_)
---        vim.system({ 'rm', 'big.zip' }, { text = true }, function(out)
---            print(out.stdout)
---        end)
---    end)
---end)
---```
---Write async/await style code like this:
---```lua
---async(function(sys)
---    sys({ 'unzip', 'big.zip' }, { text = true })
---    sys({ 'rm', 'big.zip' }, { text = true})
---    print(sys({ 'ls' }, { text = true }).stdout)
---end)
---```
---@param fn fun(sys: fun(cmd: string[], opts?: vim.SystemOpts): vim.SystemCompleted)
---@see vim.system
local function async(fn)
    local cb

    local sys = function(cmd, opts)
        local sys_completed
        coroutine.yield(vim.system(cmd, opts, function(obj)
            sys_completed = obj
            cb()
        end))
        return sys_completed
    end

    cb = coroutine.wrap(function()
        fn(sys)
    end)
    cb()
end

-- ~~~~~~~~~~~
--  Lock File
-- ~~~~~~~~~~~

---Read the `lockfile` content into `lock`
local function read_lockfile()
    lock = {}

    if not vim.uv.fs_lstat(lockfile) then
        return
    end

    local ok, res = pcall(vim.json.decode, table.concat(vim.fn.readfile(lockfile), '\n'), { object = true, array = true })
    if ok then
        lock = res
    end
end

---Write the current lock state from `lock` as JSON to the `lockfile`
local function write_lockfile()
    local f = assert(io.open(lockfile, 'wb'))
    f:write('{\n')
    local keys = vim.tbl_keys(lock)
    table.sort(keys) -- ensure same order, minimize git diff
    for i, k in ipairs(keys) do
        f:write(('  "%s": { "hash": "%s" }'):format(k, lock[k].hash))
        if i ~= vim.tbl_count(keys) then
            f:write(',\n')
        end
    end
    f:write('\n}')
    f:close()
end

-- ~~~~~
--  Git
-- ~~~~~

---Get the `path` for the plugin name by `name`
---Does NOT check if the `path` is valid and existing
---@param name string
---@return string path
local function get_plugin_path(name)
    return vim.fs.joinpath(packpath, name)
end

---Clone the given `url` from git
---@param url string The repository URL
---@result boolean ok
---@result string? error
local function git_clone(url)
    url = get_git_url(url)

    local out = vim.system(
      { 'git', 'clone', '--filter=blob:none', "--recurse-submodules", "--also-filter-submodules", url },
      { text = true, cwd = packpath }):wait()

    if out.code ~= 0 then
        return false, out.stderr
    end
    return true
end

---Extract the current git commit hash of the given plugin
---@param name string
---@return string
local function git_get_hash(name)
    local hash = vim.system(
        { 'git', 'rev-parse', 'HEAD' },
        { text = true, cwd = get_plugin_path(name) }):wait().stdout:gsub('\n$', '')
    return hash
end

---Check is `commit` is an ancestor of `maybe_parent`
---@param plugin string
---@param commit string
---@param maybe_parent string
---@return boolean result
local function git_is_ancestor(plugin, commit, maybe_parent)
    return vim.system(
        { 'git', 'merge-base', '--is-ancestor', maybe_parent, commit },
        { text = true, cwd = get_plugin_path(plugin) }):wait().code == 0
end

---Check out the specified `hash` for the git repository at `url`
---If `hash` is omitted this will check out the latest commit
---@param name string
---@param hash string?
local function git_checkout(name, hash)
    vim.system(
        { 'git', 'checkout', '--recurse-submodules', hash or 'origin/HEAD' },
        { text = true, cwd = get_plugin_path(name) }):wait()
end

---Fetch new git commits remotely available for the plugin `name` asynchronously and trigger the given `callback` function afterwards
---@param name string The name of the plugin
---@param callback fun(commits: string[]) Callback function that is being called with the commits afterwards
local function git_commits(name, callback)
    async(function(sys)
        sys(
            { 'git', 'fetch', '--recurse-submodules=yes' },
            { text = true, cwd = get_plugin_path(name) })

        local out = sys(
            { 'git', 'log', '--pretty=format:%h %s (%cs)', 'HEAD..origin/HEAD' },
            { text = true, cwd = get_plugin_path(name) })

        local commits = vim.iter(vim.split(out.stdout, '\n'))
            :filter(function(s) return s ~= '' end)
            :totable()

        if vim.tbl_isempty(commits) then
            commits = { ';; no new commits' }
        end

        callback(commits)
    end)
end

-- ~~~~~~~~~~~~~~~~
--  Public Lua API
-- ~~~~~~~~~~~~~~~~

---Return all plugin specs managed by alpacka
---@return { [string]: AlpackaPluginSpec } plugin_specs
function M.plugins()
    return alpacka_plugins
end

---Helper function to avoid code repetition for common logic
---@param label string Label of the action to be done (lowercase)
---@param plugins string[] The plugins that should be processed (empty means "all of them")
---@param filter_managed_only boolean Remove non-managed plugins from the given list for commands that should only execute on those
---@param process fun(plugin: string): boolean, string? Processing function. Return `true` if successful, otherwise `false` + optional message
local function process_plugins(label, plugins, filter_managed_only, process)
    if vim.tbl_isempty(plugins) then
        plugins = vim.tbl_keys(alpacka_plugins)
    elseif filter_managed_only then
        plugins = vim.iter(plugins)
            :filter(function(p)
                return alpacka_plugins[p] ~= nil
            end)
            :totable()
    end

    local count = 0
    local issues = {}

    for _, name in ipairs(plugins) do
        -- always skip local plugins
        if alpacka_plugins[name] and alpacka_plugins[name].dir then
            table.insert(issues, '- local plugin "'..name..'" can not be '..label)
            goto continue
        end

        local success, msg = process(name)
        if success then
            count = count + 1
        elseif msg then
            table.insert(issues, msg)
        end
        ::continue::
    end

    local issues_msg = ''
    if vim.tbl_count(issues) > 0 then
        issues_msg = ':'
        for _, is in ipairs(issues) do
            issues_msg = issues_msg .. '\n' .. is
        end
    end

    vim.notify(capitalize(label)..' '..count..' plugins'..issues_msg, vim.log.levels.INFO, {})
end

---Restore all given plugins or all (registered) plugins if none are provided
---@param ... string The plugins you want to restore
function M.restore(...)
    process_plugins('restored', {...}, true,
        function(name)
            local diff = git_get_hash(name) ~= lock[name].hash
            if not diff then
                return false, '- "' .. name .. '" is in locked state already'
            end

            git_checkout(name, lock[name].hash)
            return true
        end)
end

---Update all given plugins or all (registered) plugins if none are provided
---@param ... string The plugins you want to update
function M.update(...)
    process_plugins('updated', {...}, true,
        function(name)
            local before_hash = git_get_hash(name)
            git_checkout(name)
            local success = before_hash ~= git_get_hash(name)
            local spec = alpacka_plugins[name]

            -- if the update changed something retrigger the `build` function
            if success and spec.build then
                spec.build(name, spec)
            end

            return success
        end)
end

---Lock all given plugins or all (registered) plugins if none are provided
---@param ... string The plugins you want to lock
function M.lock(...)
    process_plugins('locked', {...}, true,
        function(name)
            local hash = git_get_hash(name)
            local modified = lock[name].hash ~= hash
            lock[name].hash = hash
            return modified
        end)
    write_lockfile()
end

---Delete the given non-local `plugin` 
---Asks for confirmation first before executing the procedure
---@param plugin string
function M.delete(plugin)
    local input = vim.fn.confirm('Do you want to delete "'..plugin..'"?', '&Yes\n&No', 2)
    if input == 1 then
        process_plugins('deleted', { plugin }, false,
            function(name)
                local success, error = delete(get_plugin_path(name), 'directory')
                if success then
                    alpacka_plugins[plugin] = nil
                else
                    vim.notify('Could not delete the plugin "'..name..'":\n'..error, vim.log.levels.ERROR, {})
                end
                return success
            end)
    end
end

---Remove all non-managed plugins from the lock file and save it to disk
function M.clean_lockfile()
    local count = 0
    for plugin, _ in pairs(lock) do
        if not alpacka_plugins[plugin] then
            lock[plugin] = nil
            count = count + 1
        end
    end
    write_lockfile()
    vim.notify('Removed '..count..' entries from the lockfile', vim.log.levels.INFO, {})
end

---Load the given `plugins`
---
---NOTE: While you can re-execute this function to install new plugins it will not remove already setup plugins from the runtimepath even if they have been removed from the configuration
---
---## Example
---```lua
---require('alpacka').setup {
---  'plugin-1',
---  'plugin-2',
---  {
---    'plugin-3',
---    config = function()
---      require('plugin-3').setup()
---    end
---  }
---}
---```
---@param plugins (string | AlpackaPluginSpec)[] The plugins that should be managed by alpacka
function M.setup(plugins)
    local cwd = assert(vim.uv.cwd())
    read_lockfile()
    alpacka_plugins = {}

    for _, spec in ipairs(plugins) do
        if type(spec) == 'string' then
            spec = { spec }
        end

        local url = spec[1]
        local name = get_plugin_name(url)

        if spec.load and not spec.load(name, spec) then
            return
        end

        if spec.dir then
            local dir = vim.fn.fnamemodify(spec.dir, ':p'):sub(0, -2) -- remove trailing slash

            if not vim.uv.fs_lstat(dir) then
                vim.notify('The provided directory for "'..name..'": "'..spec.dir..'" does not exist!', vim.log.levels.ERROR, {})
                return
            end

            -- local plugins should not be part of the lockfile
            -- but if they are in there already we're not messing with it

            if spec.init then
                local ok, error = pcall(spec.init, name, spec)
                if not ok then
                    print('Init function for '..name..' threw an error: '..error)
                end
            end

            vim.opt.runtimepath:prepend(dir)
        else
            local call_build = false
            if not vim.uv.fs_lstat(get_plugin_path(name)) then
                print('Installing ' .. name .. '...')
                local ok, error = git_clone(url)
                if not ok then
                    print('Cloning '..name..' encountered an issue: '..error)
                    goto continue
                end

                if lock[name] then
                    git_checkout(name, lock[name].hash)
                end

                call_build = spec.build ~= nil
            end

            if not lock[name] then
                lock[name] = {
                    hash = git_get_hash(name)
                }
            end

            if spec.init then
                local ok, error = pcall(spec.init, name, spec)
                if not ok then
                    print('Init function for '..name..' threw an error: '..error)
                end
            end

            vim.cmd.packadd(name)

            if call_build then
                vim.uv.chdir(get_plugin_path(name))
                local build_ok, build_error = pcall(spec.build, name, spec)
                if not build_ok then
                    print('Build function for '..name..' threw an error: '..build_error)
                end
                vim.uv.chdir(cwd)
            end
        end

        if spec.config then
            local ok, error = pcall(spec.config, name, spec)
            if not ok then
                print('Config function for '..name..' threw an error: '..error)
            end
        end

        -- mark plugin as handled by alpacka
        alpacka_plugins[name] = spec

        ::continue::
    end

    write_lockfile()
end

---Create the content for the status buffer
---@return string[] lines The lines to show in the status buffer
local function gen_alpacka_status()
    -- find lockfile entries that point towards unmanaged plugins
    local outdated_lock_entries = {}
    for plugin, _ in pairs(lock) do
        if not alpacka_plugins[plugin] then
            table.insert(outdated_lock_entries, plugin)
        end
    end

    -- e.g. manually installed plugins, plugins removed (commented) from the `setup` function etc.
    local unmanaged = {}
    for name, type in vim.fs.dir(packpath) do
        if type == 'directory' and not alpacka_plugins[name] then
            table.insert(unmanaged, '> '..name)
        end
    end

    local rtp = vim.iter(vim.api.nvim_list_runtime_paths())
        :map(function(path)
            return path:match('^.*/(.*)$')
        end)
        :fold({}, function(acc, name)
            acc[name] = true
            return acc
        end)

    local loaded, not_loaded = {}, {}
    for name, spec in pairs(alpacka_plugins) do
        local entry = '> ' .. name

        if spec.dir then
            entry = entry .. ' ;; ' .. spec.dir
        else
            local hash = git_get_hash(name)
            if hash ~= lock[name].hash then
                local newer = git_is_ancestor(name, hash, lock[name].hash)
                local info = newer and ' (newer commit)' or ''
                entry = entry .. ' ;; MODIFIED' .. info
            end
        end

        if rtp[name] then
            table.insert(loaded, entry)
        else
            table.insert(not_loaded, entry)
        end
    end

    table.sort(loaded)
    table.sort(not_loaded)

    local lines = {
        '',
        'Loaded (' .. vim.tbl_count(loaded) .. ')',
        '',
        ' Check [c]   Update [u]   Restore [r]   Lock [o]   Open Directory [<C-o>]   Retrigger Build [<C-b>] ',
        ';; use upper case letters for check, update, restore & lock to execute them on all plugins',
        '',
    }
    for _, s in ipairs(loaded) do
        table.insert(lines, s)
    end

    if vim.tbl_count(not_loaded) > 0 then
        table.insert(lines, '')
        table.insert(lines, 'Not Loaded (' .. vim.tbl_count(not_loaded) .. ')')
        table.insert(lines, '')
        for _, s in ipairs(not_loaded) do
            table.insert(lines, s)
        end
    end

    if vim.tbl_count(unmanaged) > 0 then
        table.insert(lines, '')
        table.insert(lines, 'Unmanaged (' .. vim.tbl_count(unmanaged) .. ')')
        table.insert(lines, '')
        table.insert(lines, ' Delete [x] ')
        table.insert(lines, '')
        for _, s in ipairs(unmanaged) do
            table.insert(lines, s)
        end
    end

    if vim.tbl_count(outdated_lock_entries) > 0 then
        table.insert(lines, '')
        table.insert(lines, 'Outdated Lockfile Entries ('..vim.tbl_count(outdated_lock_entries)..')')
        table.insert(lines, '')
        table.insert(lines, ' Clean All [<C-x>] ')
        table.insert(lines, '')
        for _, entry in ipairs(outdated_lock_entries) do
            table.insert(lines, '- ' .. entry)
        end
    end

    return lines
end

---Show an alpacka status window
function M.status()
    local info_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, gen_alpacka_status())
    vim.api.nvim_buf_set_option(info_buf, 'syntax', 'alpacka')
    vim.api.nvim_buf_set_option(info_buf, 'modifiable', false)
    vim.api.nvim_open_win(info_buf, true, {
        relative = 'editor',
        title = ' Alpacka Plugin Overview ',
        row = math.floor(vim.opt.lines:get() * 0.05),
        col = math.floor(vim.opt.columns:get() * 0.1),
        height = math.floor(vim.opt.lines:get() * 0.8),
        width = math.floor(vim.opt.columns:get() * 0.8),
        border = 'single',
        style = 'minimal',
        zindex = 10,
    })

    ---Reset the currently shown info buffer
    local reset_info_buf = function()
        vim.api.nvim_buf_set_option(info_buf, 'modifiable', true)
        vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, gen_alpacka_status())
        vim.api.nvim_buf_set_option(info_buf, 'modifiable', false)
    end

    ---Return The name of the plugin under the cursor
    ---@return string name
    local current_plugin_name = function()
        return string.match(vim.fn.getline('.'), '> (%S+)')
    end

    ---Execute the given `fn` for the plugin under the cursor (if present)
    ---Refresh info buffer afterwards
    ---@param fn function
    local execute_for_plugin = function(fn)
        local name = current_plugin_name()
        if name then
            fn(name)
            reset_info_buf()
        end
    end

    ---Fetch new commits for the given `plugins` asynchronously
    ---Edit the status buffer by adding the new commit when they are ready
    ---@param plugins string[]
    local show_commits = function(plugins)
        for _, plugin in ipairs(plugins) do
            if not alpacka_plugins[plugin].dir then
                git_commits(plugin, vim.schedule_wrap(function(c)
                    vim.api.nvim_buf_set_option(info_buf, 'modifiable', true)
                    local lines = vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)
                    local index = -1
                    for i, line in ipairs(lines) do
                        if line:match(vim.pesc(plugin)) then
                            index = i
                            break
                        end
                    end
                    vim.api.nvim_buf_set_lines(info_buf, index, index, false, vim.iter(c):map(function(s) return '   '..s end):totable())
                    vim.api.nvim_buf_set_option(info_buf, 'modifiable', false)
                end))
            end
        end
    end

    vim.keymap.set('n', 'q', '<CMD>q<CR>', { buffer = info_buf })
    vim.keymap.set('n', '<C-o>', function()
        local name = current_plugin_name()
        if name then
            local spec = alpacka_plugins[name]
            local dir = (spec and spec.dir) or get_plugin_path(name) -- make sure that also works with unmanaged plugins
            vim.cmd.tabnew()
            vim.cmd.edit(dir)
        end
    end, { buffer = info_buf, desc = 'Open the directory for the plugin under the cursor in a new tab' })
    vim.keymap.set('n', 'c', function()
        local name = current_plugin_name()
        if name then
            reset_info_buf()
            show_commits({ name })
        end
    end, { buffer = info_buf, desc = 'Check for newer commits of the plugin under the cursor' })
    vim.keymap.set('n', 'C', function()
        reset_info_buf()
        show_commits(vim.tbl_keys(alpacka_plugins))
    end, { buffer = info_buf, desc = 'Check for newer commits for all plugins' })
    vim.keymap.set('n', 'u', function()
        execute_for_plugin(M.update)
    end, { buffer = info_buf, desc = 'Update the plugin under the cursor' })
    vim.keymap.set('n', 'U', function()
        M.update()
        reset_info_buf()
    end, { buffer = info_buf, desc = 'Update all plugins' })
    vim.keymap.set('n', 'o', function()
        execute_for_plugin(M.lock)
    end, { buffer = info_buf, desc = 'Lock the plugin under the cursor' })
    vim.keymap.set('n', 'O', function()
        M.lock()
        reset_info_buf()
    end, { buffer = info_buf, desc = 'Lock all plugins' })
    vim.keymap.set('n', 'r', function()
        execute_for_plugin(M.restore)
    end, { buffer = info_buf, desc = 'Restore the plugin under the cursor' })
    vim.keymap.set('n', 'R', function()
        M.restore()
        reset_info_buf()
    end, { buffer = info_buf, desc = 'Restore all plugins' })
    vim.keymap.set('n', 'x', function()
        execute_for_plugin(M.delete)
    end, { buffer = info_buf, desc = 'Delete the plugin under the cursor' })
    vim.keymap.set('n', '<C-x>', function()
        M.clean_lockfile()
        reset_info_buf()
    end, { buffer = info_buf, desc = 'Clean outdated entries from the lockfile' })
    vim.keymap.set('n', '<C-b>', function()
        local name = current_plugin_name()
        if name then
            local spec = alpacka_plugins[name]
            if spec and spec.build and not spec.dir then
                spec.build(name, spec)
            end
        end
    end, { buffer = info_buf, desc = 'Retrigger the build for the plugin under the cursor' })
end

vim.api.nvim_create_user_command('Alpacka', M.status, { desc = 'Open the Alpacka info window' })

return M
