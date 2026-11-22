local wez = require 'wezterm'
local state = wez.GLOBAL
local M = {}

-- Reconstruct a split tree from the rectangles, including panes hidden by zoom.
local function layout(rects)
  if #rects == 1 then return rects[1].leaf end
  for _, axis in ipairs { { 'left', 'width', 'Right' }, { 'top', 'height', 'Bottom' } } do
    local pos, size, direction = table.unpack(axis)
    table.sort(rects, function(a, b) return a[pos] < b[pos] end)
    local start = rects[1][pos]
    local edge, limit = start, start
    for _, r in ipairs(rects) do limit = math.max(limit, r[pos] + r[size]) end
    for i = 1, #rects - 1 do
      local r, next_start = rects[i], rects[i + 1][pos]
      edge = math.max(edge, r[pos] + r[size])
      if edge < next_start then
        local left, right = {}, {}
        for j, item in ipairs(rects) do
          local group = j <= i and left or right
          table.insert(group, item)
        end
        return { direction = direction, fraction = (limit - next_start) / (limit - start - 1),
          first = layout(left), second = layout(right) }
      end
    end
  end
  error('Cannot reconstruct pane geometry')
end

local function snapshot(target_for)
  local saved = {}
  local windows = wez.mux.all_windows()
  table.sort(windows, function(a, b) return a:window_id() < b:window_id() end)
  for _, window in ipairs(windows) do
    local tabs = {}
    for _, entry in ipairs(window:tabs_with_info()) do
      local rects, zoomed = {}, false
      for _, info in ipairs(entry.tab:panes_with_info()) do
        local target = target_for(info.pane:pane_id())
        table.insert(rects, { left = info.left, top = info.top, width = info.width, height = info.height,
          leaf = { kind = target and 'ssh' or 'local', host = target and target.host,
            port = target and target.port, persistent = target and target.persistent,
            screen_id = target and target.screen_id, active = info.is_active } })
        zoomed = zoomed or info.is_zoomed
      end
      if #rects == 0 then return end
      table.insert(tabs, { title = entry.tab:get_title(), active = entry.is_active,
        zoomed = zoomed, layout = layout(rects) })
    end
    if #tabs == 0 then return end
    local size = window:active_tab():get_size()
    table.insert(saved, { tabs = tabs, width = size.cols, height = size.rows })
  end
  if #saved > 0 then return saved end
end

local function storage()
  if state.los_session_path then return state.los_session_path end
  local ok, slot, err = wez.run_child_process {
    wez.config_dir .. '/Лось SSH.exe', '--session-slot', tostring(wez.procinfo.pid()) }
  assert(ok and tonumber(slot), 'Cannot claim session slot: ' .. (err or ''))
  local dir = os.getenv('LOS_SSH_SESSION_DIR') or (os.getenv('LOCALAPPDATA') .. '/LosSSH')
  local prefix = dir .. '/window-' .. tonumber(slot)
  state.los_session_path = prefix
  return prefix
end

local function valid_tree(node, parse_address)
  if type(node) ~= 'table' then return false end
  if node.kind == 'local' then return true end
  if node.kind == 'ssh' then
    if node.persistent ~= nil and type(node.persistent) ~= 'boolean' then return false end
    if node.screen_id ~= nil and (type(node.screen_id) ~= 'string' or #node.screen_id ~= 32
      or not node.screen_id:match('^[0-9a-f]+$') or node.persistent == false) then return false end
    if type(node.host) ~= 'string' or node.host:find('%s') then return false end
    if node.port ~= nil and (type(node.port) ~= 'string' or not node.port:match('^%d+$')) then return false end
    return parse_address(node.host .. (node.port and ' ' .. node.port or '')) ~= nil
  end
  return (node.direction == 'Right' or node.direction == 'Bottom')
    and type(node.fraction) == 'number' and node.fraction > 0 and node.fraction < 1
    and valid_tree(node.first, parse_address) and valid_tree(node.second, parse_address)
end

local function valid(data, parse_address)
  if type(data) ~= 'table' or data.version ~= 1 or type(data.generation) ~= 'number'
    or type(data.windows) ~= 'table' or #data.windows == 0 then return false end
  for _, w in ipairs(data.windows) do
    if type(w.tabs) ~= 'table' or #w.tabs == 0 or type(w.width) ~= 'number'
      or type(w.height) ~= 'number' or w.width < 1 or w.height < 1 then return false end
    for _, tab in ipairs(w.tabs) do
      if type(tab.title) ~= 'string' or not valid_tree(tab.layout, parse_address) then return false end
    end
  end
  return true
end

local function read_latest(parse_address)
  local prefix = storage()
  local latest
  for i = 0, 1 do
    local f = io.open(prefix .. '.' .. i .. '.json', 'rb')
    if f then
      local bytes = f:read('*a')
      f:close()
      local ok, data = pcall(function()
        local item = wez.json_parse(bytes)
        return valid(item, parse_address) and item
      end)
      if ok and data and (not latest or data.generation > latest.generation) then latest = data end
    end
  end
  state.los_generation = latest and latest.generation or 0
  return latest
end

local function first_leaf(node)
  while node.first do node = node.first end
  return node
end

function M.install(target_for, command_for, remember, parse_address)
  local function restore_tab(w, wdata, saved)
    local function command(leaf) return command_for(leaf.kind == 'ssh' and leaf or nil) end
    local args = command(first_leaf(saved.layout))
    local tab, root
    if w then tab, root = w:spawn_tab(args)
    else
      args.width, args.height = wdata.width, wdata.height
      tab, root, w = wez.mux.spawn_window(args)
    end
    local active
    local function populate(node, pane)
      if node.kind then
        if node.kind == 'ssh' then
          remember(pane, { host = node.host, port = node.port, persistent = node.persistent, screen_id = node.screen_id })
        end
        if node.active then active = pane end
      else
        local split = command(first_leaf(node.second))
        split.direction, split.size = node.direction, node.fraction
        local other = pane:split(split)
        populate(node.first, pane)
        populate(node.second, other)
      end
    end
    populate(saved.layout, root)
    tab:set_title(saved.title)
    if active then active:activate() end
    if saved.zoomed then tab:set_zoomed(true) end
    return w, tab
  end

  wez.on('gui-startup', function(cmd)
    if cmd and cmd.args and #cmd.args > 0 then return end
    state.los_restoring = true
    local ok, err = pcall(function()
      local data = read_latest(parse_address)
      for _, wdata in ipairs(data and data.windows or {}) do
        local w, active, tab
        for _, saved in ipairs(wdata.tabs) do
          w, tab = restore_tab(w, wdata, saved)
          if saved.active then active = tab end
        end
        if active then active:activate() end
      end
    end)
    state.los_restoring = false
    if not ok then
      state.los_restore_error = tostring(err)
      wez.log_error(err)
    end
  end)

  local function save()
    if state.los_restoring or state.los_restore_error then return end
    local windows = snapshot(target_for)
    if not windows then return end
    local content = wez.json_encode(windows)
    if content == state.los_last_snapshot then return end
    if not state.los_generation then read_latest(parse_address) end
    local generation = state.los_generation + 1
    -- Only overwrite the older copy. A truncated write leaves the latest good copy readable.
    local f = assert(io.open(storage() .. '.' .. (generation % 2) .. '.json', 'wb'))
    local bytes = wez.json_encode { version = 1, generation = generation, windows = windows }
    local written, err = f:write(bytes)
    local closed, close_err = f:close()
    assert(written and closed, err or close_err)
    state.los_generation, state.los_last_snapshot = generation, content
  end
  local function checkpoint()
    local ok, err = pcall(save)
    if not ok and state.los_save_error ~= tostring(err) then wez.log_error(err) end
    state.los_save_error = not ok and tostring(err) or nil
  end
  wez.on('update-status', checkpoint)
  wez.on('window-focus-changed', checkpoint)
  return checkpoint
end
return M
