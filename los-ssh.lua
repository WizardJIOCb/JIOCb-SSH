local wez = require 'wezterm'
local act = wez.action
local cfg = wez.config_builder()
local ssh = (os.getenv('SystemRoot') or 'C:\\Windows') .. '/System32/OpenSSH/ssh.exe'
local ssh_config = os.getenv('LOS_SSH_CONFIG')
local local_shell = { (os.getenv('SystemRoot') or 'C:\\Windows') .. '/System32/WindowsPowerShell/v1.0/powershell.exe', '-NoLogo' }

cfg.default_prog = local_shell
cfg.default_cwd = wez.home_dir
cfg.front_end = 'WebGpu'
cfg.max_fps = 120
cfg.scrollback_lines = 25000
cfg.font_size = 11.5
cfg.initial_cols = 116
cfg.initial_rows = 32
cfg.window_padding = { left = 12, right = 12, top = 8, bottom = 6 }
cfg.use_fancy_tab_bar = false
cfg.tab_max_width = 30
cfg.check_for_updates = false
cfg.colors = {
  foreground = '#dfe9ee', background = '#101823', cursor_bg = '#8be4cc',
  cursor_border = '#8be4cc', cursor_fg = '#101823', selection_bg = '#345268',
  split = '#5e8391',
  tab_bar = {
    background = '#17232e',
    active_tab = { bg_color = '#98e0c4', fg_color = '#0f2926', intensity = 'Bold' },
    inactive_tab = { bg_color = '#20313f', fg_color = '#c4d4df' },
    new_tab = { bg_color = '#17232e', fg_color = '#98e0c4' },
  },
}
cfg.inactive_pane_hsb = { saturation = 0.9, brightness = 0.85 }

local function session(pane_id)
  return wez.GLOBAL['ssh_' .. pane_id]
end

local function command_for(target)
  local command = { cwd = wez.home_dir, args = local_shell, domain = 'DefaultDomain' }
  if target then
    command.args = { ssh }
    if ssh_config and ssh_config ~= '' then
      table.insert(command.args, '-F')
      table.insert(command.args, ssh_config)
    end
    if target.port then
      table.insert(command.args, '-p')
      table.insert(command.args, target.port)
    end
    table.insert(command.args, '--')
    table.insert(command.args, target.host)
  end
  return command
end

local function remember(pane, target)
  if target then wez.GLOBAL['ssh_' .. pane:pane_id()] = target end
end

local checkpoint
local function open_session(window, pane, direction, target)
  local command = command_for(target)
  local next_pane
  if direction then
    command.direction = direction
    next_pane = pane:split(command)
  else
    local tab
    tab, next_pane = window:mux_window():spawn_tab(command)
    tab:activate()
  end
  remember(next_pane, target)
  next_pane:activate()
  checkpoint()
end

local function parse_address(line)
  local host, port = line:match('^%s*(%S+)%s+(%d+)%s*$')
  host = host or line:match('^%s*(%S+)%s*$')
  if not host or (port and (tonumber(port) < 1 or tonumber(port) > 65535)) then return end
  local user, addr = host:match('^([%w_.%-]+)@(.+)$')
  addr = addr or host
  local ipv6 = addr:match('^%[([%x:%.]+)%]$') or addr:match('^([%x:%.]*:[%x:%.]*:[%x:%.]*)$')
  if ipv6 then addr = ipv6
  elseif not addr:match('^[%w_][%w_.%-]*$') then return end
  return { host = (user and user .. '@' or '') .. addr, port = port }
end

package.path = wez.config_dir .. '/?.lua;' .. package.path
checkpoint = require('session').install(session, command_for, remember, parse_address)
cfg.status_update_interval = 500

local function manual(window, pane, direction)
  window:perform_action(act.PromptInputLine {
    description = 'SSH   ·   user@host [порт]   ·   например dev@server 2222',
    action = wez.action_callback(function(w, p, line)
      if not line then return end
      local target = parse_address(line)
      if target then open_session(w, p, direction, target)
      else w:toast_notification('Лось SSH', 'Введите хост или user@host и, при необходимости, порт через пробел.', nil, 4500) end
    end),
  }, pane)
end

local function pick_host(window, pane, direction)
  local choices = { { id = ':manual', label = 'Ввести адрес SSH…' } }
  local ok, hosts
  if ssh_config and ssh_config ~= '' then
    ok, hosts = pcall(wez.enumerate_ssh_hosts, ssh_config)
  else
    ok, hosts = pcall(wez.enumerate_ssh_hosts)
  end
  if ok then
    local names = {}
    for alias in pairs(hosts) do
      if alias:match('^[%w_][%w_.%-]*$') then table.insert(names, alias) end
    end
    table.sort(names)
    for _, alias in ipairs(names) do table.insert(choices, { id = alias, label = alias }) end
  end
  window:perform_action(act.InputSelector {
    title = 'SSH-подключения', fuzzy = true, fuzzy_description = 'Найти сервер  ›  ',
    choices = choices,
    action = wez.action_callback(function(w, p, id)
      if id == ':manual' then manual(w, p, direction)
      elseif id then open_session(w, p, direction, { host = id }) end
    end),
  }, pane)
end

local function split(direction)
  return wez.action_callback(function(w, p) open_session(w, p, direction, session(p:pane_id())) end)
end
local ssh_tab = wez.action_callback(function(w, p) pick_host(w, p) end)
local ssh_right = wez.action_callback(function(w, p) pick_host(w, p, 'Right') end)
local new_tab = wez.action_callback(function(w, p) open_session(w, p) end)
local right, down = split('Right'), split('Bottom')
local zoom = act.TogglePaneZoomState
local rename = act.PromptInputLine {
  description = 'Название вкладки',
  action = wez.action_callback(function(_, p, line)
    if line then p:tab():set_title(line) checkpoint() end
  end),
}
local items = {
  { 'ssh', 'SSH-подключение', ssh_tab }, { 'local', 'Новая вкладка PowerShell', new_tab },
  { 'right', 'Разделить вправо', right }, { 'down', 'Разделить вниз', down },
  { 'other', 'Другой SSH-сервер справа', ssh_right }, { 'zoom', 'Развернуть / свернуть панель', zoom },
  { 'rename', 'Переименовать вкладку', rename }, { 'find', 'Найти в выводе', act.Search 'CurrentSelectionOrEmptyString' },
  { 'close', 'Закрыть активную панель', act.CloseCurrentPane { confirm = true } },
}
local menu = wez.action_callback(function(w, p)
  local choices = {}
  for _, item in ipairs(items) do table.insert(choices, { id = item[1], label = item[2] }) end
  w:perform_action(act.InputSelector {
    title = 'Лось SSH', choices = choices, description = 'Выберите действие   ·   Enter',
    action = wez.action_callback(function(win, pane, id)
      for _, item in ipairs(items) do
        if item[1] == id then win:perform_action(item[3], pane) return end
      end
    end),
  }, p)
end)

cfg.keys = {
  { key = 'k', mods = 'CTRL|SHIFT', action = menu },
  { key = 's', mods = 'CTRL|SHIFT', action = ssh_tab },
  { key = 't', mods = 'CTRL|SHIFT', action = new_tab },
  { key = 'd', mods = 'CTRL|SHIFT', action = right },
  { key = 'e', mods = 'CTRL|SHIFT', action = down },
  { key = 'z', mods = 'CTRL|SHIFT', action = zoom },
  { key = 'w', mods = 'CTRL|SHIFT', action = act.CloseCurrentPane { confirm = true } },
  { key = 'F2', mods = 'NONE', action = rename },
}
for _, dir in ipairs { 'Left', 'Right', 'Up', 'Down' } do
  table.insert(cfg.keys, { key = dir .. 'Arrow', mods = 'ALT', action = act.ActivatePaneDirection(dir) })
  table.insert(cfg.keys, { key = dir .. 'Arrow', mods = 'ALT|SHIFT', action = act.AdjustPaneSize { dir, 3 } })
end
wez.on('new-tab-button-click', function(w, p, button)
  if button == 'Left' then w:perform_action(menu, p) return false end
end)
wez.on('format-tab-title', function(tab)
  local target = session(tab.active_pane.pane_id)
  local title = tab.tab_title
  if title == '' then title = target and target.host or tab.active_pane.title end
  return '  ' .. (tab.tab_index + 1) .. '  ' .. wez.truncate_right(title, 23) .. '  '
end)
wez.on('format-window-title', function(tab)
  local target = session(tab.active_pane.pane_id)
  return 'Лось SSH  |  ' .. (target and target.host or tab.active_pane.title)
end)
wez.on('update-right-status', function(window)
  window:set_right_status(' SSH  Ctrl+Shift+S    Меню  Ctrl+Shift+K  ')
end)
return cfg
