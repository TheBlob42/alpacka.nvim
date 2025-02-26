# Alpacka 🦙

A simple plugin manager for Neovim

## Motivation

Moving from [vim-plug](https://github.com/junegunn/vim-plug) to [packer.nvim](https://github.com/wbthomason/packer.nvim) for Lua support and then to [lazy.nvim](https://github.com/folke/lazy.nvim) for its lockfile feature refined my expectations of a plugin manager for Neovim. However, when I encountered issues with the `lazy-lock.json` file not behaving as I expected (see [here](https://github.com/folke/lazy.nvim/issues/1787) and [here](https://github.com/folke/lazy.nvim/issues/1740) for examples) I took the opportunity to create a simpler solution tailored toward my personal needs:

- I don't care about lazy loading and startup time optimizations
- I don't need support for [luarocks](https://luarocks.org/)
- I prioritize determinism and simplicity over raw speed

### Features

- Leverage Neovim's built-in `packages` system
- Install and load plugins synchronously
  - Load exactly in the order of definition
  - Simple and predictable dependency management
- Provide hook functions for building, initializing and configuring plugins
- Includes a lockfile (`alpacka-lock.json`)
  - Track commits of installed plugins
  - Sync your state to different machines
  - Only manual file updates for full control

### Non-Features

- **NO** lazy loading functionality
- **NO** caching or bytecode compilation
- **NO** luarocks support

## Installation & Setup

Requires the following dependencies:

- Neovim >= `0.10.0`
- Git >= `2.19.0` (for partial clone support)

```lua
-- automatically bootstrap alpacka
local alpacka_path = vim.fn.stdpath('data') .. '/site/pack/alpacka/opt/alpacka.nvim'
if not vim.uv.fs_stat(alpacka_path) then
    local out = vim.system({
        'git',
        'clone',
        '--filter=blob:none',
        'https://github.com/theblob42/alpacka.nvim.git',
        alpacka_path,
    }):wait()

    if out.code ~= 0 then
      print('Error when cloning "alpacka.nvim":\n' .. out.stderr)
    end
end

-- IMPORTANT so that alpacka gets loaded on startup
vim.cmd.packadd('alpacka.nvim')

require('alpacka').setup {
  -- alpacka can manage itself
  'theblob42/alpacka.nvim',

  -- simple plugins can be specified as strings
  'tpope/vim-sleuth',

  -- full git URLs are supported (e.g. for non-Github repositories)
  'https://github.com/tpope/vim-sensible.git',

  -- define a specific commit that should be checked out
  {
    'eraserhd/parinfer-rust',
    commit = '327fc9a'
  },

  -- set a git tag that should be checked out
  {
    'folke/noice.nvim',
    tag = 'v4.7.0'
  },

  -- specify a git branch that should be checked out
  {
    'echasnovski/mini.nvim',
    branch = 'stable'
  },

  -- local plugins can be loaded as well
  {
    'my-local-plugin',
    dir = '~/Dev/my-local-plugin'
  },

  -- plugins can have post-install/update hooks
  {
    'nvim-treesitter/nvim-treesitter',
    build = function()
      vim.cmd('TSUpdate')
    end
  },

  -- run lua function before load
  {
    'Olical/conjure',
    init = function()
      vim.g['conjure#mapping#doc_word'] = 'gk'
    end
  },

  -- run lua function after load
  {
    'lukas-reineke/indent-blankline.nvim',
    config = function()
      require('ibl').setup {}
    end
  },

  -- only load plugins if a certain condition is met
  {
    'github/copilot.vim',
    load = function()
      return vim.env.USER == 'work-laptop'
    end
  },
}
```

<details>

<summary>More details about the configuration options</summary>

### `dir`

Specify the directory for a local plugin

Local plugins should be managed by you and therefore come with the following "restrictions":

- Not added to the lock file
- The `build` function will be ignored
- The `branch` property will be ignored
- Updates have to be done manually

### `commit`, `tag` & `branch`

Define a specific reference that should be checked out for a plugin. While these are separate properties **only one** of them will be applied in cases where you provide more than one. The first item from the following table will be used (top to bottom) all others will be ignored:

| Property | Description                                 |
| ---      | ---                                         |
| `commit` | The specific GIT commit will be checked out |
| `tag`    | The specific GIT tag will be checked out    |
| `branch` | The specific GIT branch will be checked out |

**NOTE**: If a plugin is already installed simply specifying any of these properties will not update it automatically. Either update the plugin manually or reinstall it for the desired change to take place

### `build`

Function to trigger after a plugin has either been cloned or updated. Use this to download assets, build binaries etc.

- Called after a plugin has been loaded
  - **After** the `init` function
  - **Before** the `config` function
- Switches the current working directory temporarily to the plugin folder
- Receives the plugin name and spec as parameters
- Updating the plugin via `require('alpacka').update(...)` or the status window will trigger this function again
  - Only if the update actually changed something

```lua
  {
    'iamcco/markdown-preview.nvim',
    build = function()
      vim.sytem(
        { 'yarn', 'install' },
        { cwd = './app' }) -- build is switching to the plugin directory temporarily
    end
  }
```

### `init`

Function to setup anything **before** a plugin is being loaded. Use this to setup global variables or other prerequisites. Receives the plugin name and spec as parameters

### `config`

Function to setup any configuration **after** a plugin has been loaded. This is the place for setup instructions (usually by calling  a `setup` function), creating keybindings and so on. Receives the plugin name and spec as parameters

### `load`

Function that decides if a plugin should be loaded. Has to return a boolean value. Receives the plugin name and spec as parameters

If the function returns `true` the package will be loaded via `packadd`. This is the default if no `load` function is specified. Otherwise this step will be skipped. The installation of a plugin is not influenced by this property

> You could use this property to build your own "lazy loading" functionality  
> Just call `packadd` at any given occasion to load the plugin (autocommand, custom user command etc.)

</details>

## Usage

Use the `:Alpacka` command to open a status window with more information about your configured plugins:

![alpacka-status-window](https://github.com/user-attachments/assets/0949b7d8-7f3b-4413-84f6-53eb9f19ac74)

- Overview about all plugins managed by alpacka
  - List unmanaged plugins that you might want to get rid off
  - List lockfile entries that can be deleted
- Check for new commits available
- Update plugins to the newest commit
- See if a plugin's current commit differs from the lockfile (`Lock*`)
  - Restore plugins to their locked state
  - Update the lockfile
- Show specified plugin ref: `dir`, `commit`, `tag` or `branch`
  - A trailing asterisk indicates a discrepancy between the spec definition and the current plugin state

## References

- [vim-plug](https://github.com/junegunn/vim-plug)
- [packer.nvim](https://github.com/wbthomason/packer.nvim)
- [lazy.nvim](https://github.com/folke/lazy.nvim)

## TODO

- [x] Support for git branches and tags
- [ ] Write help files
