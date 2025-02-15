# Alpacka 🦙

A simple plugin manager for Neovim

## Motivation

Moving from [vim-plug](https://github.com/junegunn/vim-plug) to [packer.nvim](https://github.com/wbthomason/packer.nvim) because of Lua and then on to [lazy.nvim](https://github.com/folke/lazy.nvim) because of the support for a lockfile showed me what I expect of a plugin manager and what not. And when I ran into issues with the `lazy-lock.json` file not behaving as I would want and expect (see [here](https://github.com/folke/lazy.nvim/issues/1787) and [here](https://github.com/folke/lazy.nvim/issues/1740) for examples) I took the chance to create my own simple solution tailored toward my own needs:

- I don't care about lazy loading and my startuptime
- I don't need support for [luarocks](https://luarocks.org/)
- I value determinism and simplicity higher than speed

### Features

- Use the existing `packages` feature of Neovim
- Install and load plugins synchronously
  - Always loaded exactly in the order they are defined
  - Simple dependency management
- Provide hook functions for building, initializing and configuring plugins
- A lockfile: `alpacka-lock.json`
  - Keep track of the commits of installed plugins
  - Sync your state to different machines
  - Only manual updates for full control

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

### `branch`

Define a specific git branch that should be checked out

> [!IMPORTANT]  
> If the plugin is already installed simply specifying this property will not switch the branch automatically. Either update the plugin or reinstall it for the change to take place

### `build`

Function to trigger after a plugin has either been cloned or updated. Use this to download assets, build binaries etc.

- Called after the plugin has been loaded
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

Function to setup anything **before** the plugin is being loaded. Use this to setup global variables or other prerequisites. Receives the plugin name and spec as parameters

### `config`

Function to setup any configuration **after** the plugin has been loaded. This is the place for setup instructions (usually by calling  a `setup` function), creating keybindings and so on. Receives the plugin name and spec as parameters

### `load`

Function that decides if a plugin should be loaded. Has to return a boolean value. Receives the plugin name and spec as parameters

If the function returns `true` the package will be loaded via `packadd`. This is the default if no `load` function is specified. Otherwise this step will be skipped. The installation of a plugin is not influenced by this property

> You could use this property to build your own "lazy loading" functionality  
> Just call `packadd` at any given occasion to load the plugin (autocommand, custom user command etc.)

</details>

## Usage

Use the `:Alpacka` command to open a status window with more information about your configured plugins:

![alpacka-status-window](https://github.com/user-attachments/assets/6926e975-3568-49a8-9144-786138b16b00)

- Overview about all plugins managed by alpacka
  - List unmanaged plugins that you might want to get rid off
- Check for new commits available
- Update plugins to the newest commit
- See if a plugin's current commit differs from the lockfile
  - Restore plugins to their locked state
  - Update the lockfile

## References

- [vim-plug](https://github.com/junegunn/vim-plug)
- [packer.nvim](https://github.com/wbthomason/packer.nvim)
- [lazy.nvim](https://github.com/folke/lazy.nvim)

## TODO

- [ ] Support for git ~branches and~ tags
- [ ] Write help files
