local mr = require 'mason-registry'

local SETTINGS = {
  ensure_installed = {},
  auto_update = false,
  run_on_start = true,
  start_delay = 0,
  debounce_hours = nil,
}

local setup = function(settings)
  SETTINGS = vim.tbl_deep_extend('force', SETTINGS, settings)
  vim.validate {
    ensure_installed = { SETTINGS.ensure_installed, 'table', true },
    auto_update = { SETTINGS.auto_update, 'boolean', true },
    run_on_start = { SETTINGS.run_on_start, 'boolean', true },
    start_delay = { SETTINGS.start_delay, 'number', true },
    debounce_hours = { SETTINGS.debounce_hours, 'number', true },
  }
end

local debounce_file = ((vim.fn.has 'nvim-0.8' == 1) and vim.fn.stdpath 'state' or vim.fn.stdpath 'data')
  .. '/mason-tool-installer-debounce'

local read_last_timestamp = function()
  local f = io.open(debounce_file)
  if f ~= nil then
    local last = f:read()
    f:close()
    return last
  end
  return nil
end

local write_new_timestamp = function()
  local f = assert(io.open(debounce_file, 'w+'))
  f:write(os.time())
  f:close()
end

local can_run = function(hours)
  local last = read_last_timestamp()
  if last == nil then
    write_new_timestamp()
    return true
  end
  if (os.time() - last) > hours * 3600 then
    write_new_timestamp()
    return true
  end
  return false
end

local show = vim.schedule_wrap(function(msg)
  vim.notify(string.format('[mason-tool-installer] %s', msg), vim.log.levels.INFO)
end)

local show_error = vim.schedule_wrap(function(msg)
  vim.notify(string.format('[mason-tool-installer] %s', msg), vim.log.levels.ERROR)
end)

local installed = false
local installed_packages = {}
local do_install = function(p, version, on_close)
  if version ~= nil then
    show(string.format('%s: updating to %s', p.name, version))
  else
    show(string.format('%s: installing', p.name))
  end
  p:once('install:success', function()
    show(string.format('%s: successfully installed', p.name))
  end)
  p:once('install:failed', function()
    show_error(string.format('%s: failed to install', p.name))
  end)
  if not installed then
    installed = true
    vim.schedule(function()
      vim.api.nvim_exec_autocmds('User', {
        pattern = 'MasonToolsStartingInstall',
      })
    end)
  end
  table.insert(installed_packages, p.name)
  p:install({ version = version }):once('closed', vim.schedule_wrap(on_close))
end

local check_install = function(force_update)
  if not force_update and SETTINGS.debounce_hours ~= nil and not can_run(SETTINGS.debounce_hours) then
    return
  end
  installed = false -- reset for triggered events
  installed_packages = {} -- reset
  local completed = 0
  local total = vim.tbl_count(SETTINGS.ensure_installed)
  local on_close = function()
    completed = completed + 1
    if completed >= total then
      local event = {
        pattern = 'MasonToolsUpdateCompleted',
      }
      if vim.fn.has 'nvim-0.8' == 1 then
        event.data = installed_packages
      end
      vim.api.nvim_exec_autocmds('User', event)
    end
  end
  local ensure_installed = function()
    for _, item in ipairs(SETTINGS.ensure_installed or {}) do
      local name, version, auto_update
      if type(item) == 'table' then
        name = item[1]
        version = item.version
        auto_update = item.auto_update
      else
        name = item
      end
      local p = mr.get_package(name)
      if p:is_installed() then
        if version ~= nil then
          p:get_installed_version(function(ok, installed_version)
            if ok and installed_version ~= version then
              do_install(p, version, on_close)
            else
              vim.schedule(on_close)
            end
          end)
        elseif
          force_update or (force_update == nil and (auto_update or (auto_update == nil and SETTINGS.auto_update)))
        then
          p:check_new_version(function(ok, version)
            if ok then
              do_install(p, version.latest_version, on_close)
            else
              vim.schedule(on_close)
            end
          end)
        else
          vim.schedule(on_close)
        end
      else
        do_install(p, version, on_close)
      end
    end
  end
  if mr.refresh then
    mr.refresh(ensure_installed)
  else
    ensure_installed()
  end
end

local run_on_start = function()
  if SETTINGS.run_on_start then
    vim.defer_fn(check_install, SETTINGS.start_delay or 0)
  end
end

return {
  run_on_start = run_on_start,
  check_install = check_install,
  setup = setup,
}
