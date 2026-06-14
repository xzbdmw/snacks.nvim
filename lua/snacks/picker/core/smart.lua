local uv = vim.uv or vim.loop

local M = {}

local PATH_SEP = package.config:sub(1, 1)
local STORE_BASE = vim.fn.stdpath("data") .. "/snacks/picker-smart"
local HISTORY_HALF_LIFE_DAYS = 10
local HISTORY_DECAY_RATE = math.log(2) / HISTORY_HALF_LIFE_DAYS
local HISTORY_VISIT_VALUE = 100
local ADJUSTMENT_POINTS = 0.6

local DEFAULT_WEIGHTS = {
  path_fzf = 140,
  virtual_name_fzf = 131,
  open = 3,
  alt = 4,
  proximity = 13,
  project = 10,
  frecency = 17,
  recency = 9,
}

local DEFAULT_IGNORE_PATTERNS = { "*.git/*", "*/tmp/*", "*.pdf" }

local INDEX_FILENAMES = {
  ["index.js"] = true,
  ["index.ts"] = true,
  ["index.jsx"] = true,
  ["index.tsx"] = true,
  ["index.test.js"] = true,
  ["index.test.ts"] = true,
  ["index.test.jsx"] = true,
  ["index.test.tsx"] = true,
  ["__init__.py"] = true,
  ["init.lua"] = true,
  ["mod.rs"] = true,
}

local has_fzf, fzf = pcall(require, "fzf_lib")

local function shallow_copy(tbl)
  local ret = {}
  for k, v in pairs(tbl) do
    ret[k] = v
  end
  return ret
end

local function normalize(path)
  return vim.fs.normalize(path, { _fast = true, expand_env = false })
end

local function escape(str)
  return (str:gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%1"))
end

local function filemask(mask)
  mask = escape(mask)
  return "^" .. mask:gsub("%%%*", ".*"):gsub("%%%?", ".") .. "$"
end

local function filename_match(filename, pattern)
  return filename:find(filemask(pattern)) ~= nil
end

local function normalize_fzf_score(fzf_score, len)
  if fzf_score < 0 then
    return 0
  end
  fzf_score = 1 / fzf_score - 0.001 * len
  return 1 / (1 + math.exp(-0.035 * fzf_score + 5))
end

local function calculate_proximity(a, b)
  local in_common = 0
  local index = 0
  local previous_index = 1

  while true do
    index = a:find(PATH_SEP, index + 1, true)
    if not index then
      break
    elseif index > 1 then
      if a:sub(previous_index, index) == b:sub(previous_index, index) then
        in_common = in_common + 1
      else
        break
      end
    end
    previous_index = index
  end

  return in_common
end

local function normalize_proximity(value)
  return 1 - 1 / (1 + math.exp(value * 0.5 - 3))
end

local function get_virtual_name_pos(path)
  local last, penultimate, current
  local k = 0
  repeat
    penultimate = last
    last = current
    current, k = path:find(PATH_SEP, k + 1, true)
  until current == nil

  if INDEX_FILENAMES[path:sub((last or 0) + 1)] then
    return (penultimate or 0) + 1
  end
  return (last or 0) + 1
end

local function get_virtual_name(path)
  return path:sub(get_virtual_name_pos(path))
end

local function open_store(name, value_type, max_size)
  local base = STORE_BASE .. "-" .. name
  local ok, store = pcall(require("snacks.picker.util.db").new, base .. ".sqlite3", value_type)
  if ok then
    return store
  end
  return require("snacks.picker.util.kv").new(base .. ".dat", { max_size = max_size or 10000 })
end

local SmartStore = {
  setup_done = false,
  opts = {
    ignore_patterns = DEFAULT_IGNORE_PATTERNS,
  },
}

function SmartStore:count(store)
  if store.count then
    return store:count()
  end
  return vim.tbl_count(store:get_all())
end

function SmartStore:close()
  for _, key in ipairs({ "expirations", "last_open", "weights" }) do
    if self[key] then
      self[key]:close()
      self[key] = nil
    end
  end
  self.setup_done = false
end

function SmartStore:is_empty()
  local now = os.time()
  for _, expiration in pairs(self.expirations:get_all()) do
    if type(expiration) == "number" and expiration > now then
      return false
    end
  end
  return true
end

function SmartStore:file_is_ignored(filepath)
  for _, pattern in ipairs(self.opts.ignore_patterns) do
    if filename_match(filepath, pattern) then
      return true
    end
  end
  return false
end

function SmartStore:absolute_path(filepath)
  if not filepath or filepath == "" then
    return
  end
  local path = vim.fn.fnamemodify(filepath, ":p")
  return path ~= "" and normalize(path) or nil
end

function SmartStore:current_score(expiration, now)
  local time_left = (expiration - now) / 86400
  if time_left <= 0 then
    return 1
  end
  return math.exp(HISTORY_DECAY_RATE * time_left)
end

function SmartStore:next_expiration(expiration, now)
  local current_score = self:current_score(expiration, now) + HISTORY_VISIT_VALUE
  return math.floor(now + (math.log(current_score) / HISTORY_DECAY_RATE) * 86400)
end

function SmartStore:handle_open(filepath, batch_mode, now)
  now = now or os.time()
  local expiration = self.expirations:get(filepath) or (now - 1)
  self.expirations:set(filepath, self:next_expiration(expiration, now))
  self.last_open:set(filepath, now)
end

function SmartStore:record_usage(filepath, force, buf)
  self:setup()
  local path = self:absolute_path(filepath)
  if not path then
    return
  end
  if type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) and not force and vim.b[buf].snacks_picker_smart_registered then
    return
  end
  local stat = uv.fs_stat(path)
  if not stat or stat.type == "directory" or self:file_is_ignored(path) then
    return
  end
  if type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].snacks_picker_smart_registered = 1
  end
  self:handle_open(path, false, os.time())
end

function SmartStore:batch_import()
  local oldfiles = vim.api.nvim_get_vvar("oldfiles")
  for index, filepath in ipairs(oldfiles) do
    local path = self:absolute_path(filepath)
    local stat = path and uv.fs_stat(path) or nil
    if path and stat and stat.type ~= "directory" and not self:file_is_ignored(path) then
      local ts = os.time() - ((#oldfiles + 1) - index) * 9000
      self:handle_open(path, true, ts)
    end
  end
end

function SmartStore:get_weights()
  self:setup()
  local ret = shallow_copy(DEFAULT_WEIGHTS)
  for k, v in pairs(self.weights:get_all()) do
    if ret[k] ~= nil then
      ret[k] = v
    end
  end
  return ret
end

function SmartStore:save_weights(weights)
  self:setup()
  for k, v in pairs(weights) do
    if v ~= nil then
      self.weights:set(k, v)
    end
  end
end

function SmartStore:get_history(cwd)
  self:setup()
  local prefix = cwd and cwd ~= "" and (cwd:sub(-1) == "/" and cwd or cwd .. "/") or nil
  local now = os.time()
  local expirations = self.expirations:get_all()
  local last_open = self.last_open:get_all()
  local files = {}

  for path, expiration in pairs(expirations) do
    if type(expiration) == "number" and expiration > now and (not prefix or path:find(prefix, 1, true) == 1) then
      files[#files + 1] = {
        path = path,
        expiration = expiration,
        last_open = tonumber(last_open[path]) or 0,
      }
    end
  end

  table.sort(files, function(a, b)
    if a.expiration ~= b.expiration then
      return a.expiration > b.expiration
    end
    return a.path < b.path
  end)

  local max_score = 1
  if files[1] then
    max_score = math.max(files[1].expiration - now, 1)
  end

  local recent = vim.deepcopy(files)
  table.sort(recent, function(a, b)
    if a.last_open ~= b.last_open then
      return a.last_open > b.last_open
    end
    return a.path < b.path
  end)

  local recent_rank = {}
  for idx, file in ipairs(recent) do
    recent_rank[file.path] = idx
  end

  local ret = {}
  for _, file in ipairs(files) do
    ret[file.path] = {
      frecency = math.max(file.expiration - now, 0) / max_score,
      recent_rank = recent_rank[file.path] or 0,
    }
  end
  return ret
end

function SmartStore:setup()
  if self.setup_done then
    return
  end
  self.setup_done = true
  vim.fn.mkdir(vim.fn.fnamemodify(STORE_BASE, ":h"), "p")
  self.expirations = open_store("expiration", "number", 10000)
  self.last_open = open_store("recent", "number", 10000)
  self.weights = open_store("weights", "number", 128)

  if self:is_empty() then
    vim.defer_fn(function()
      SmartStore:batch_import()
    end, 100)
  end

  local group = vim.api.nvim_create_augroup("SnacksPickerSmart", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWritePost" }, {
    group = group,
    callback = function(args)
      vim.defer_fn(function()
        SmartStore:record_usage(args.match, false, args.buf)
      end, 100)
    end,
  })
  vim.api.nvim_create_autocmd("ExitPre", {
    group = group,
    callback = function()
      SmartStore:close()
    end,
  })
end

local function select_misses(results, selected_path)
  local found_selected = false
  local max_misses = 15
  local target_misses = 1
  local greater_results = {}
  local lesser_results = {}

  for _, result in ipairs(results) do
    local count = #greater_results + #lesser_results
    if selected_path == result.path then
      found_selected = true
    elseif not found_selected then
      greater_results[#greater_results + 1] = result
      if count >= max_misses then
        break
      end
    else
      if count >= target_misses then
        break
      end
      lesser_results[#lesser_results + 1] = result
    end
  end

  return greater_results, lesser_results
end

local function adjust_weights(original_weights, weights, success_entry, miss_entry, factor)
  if success_entry.current or miss_entry.current then
    return
  end

  local function get_unweighted(key, original_weight, entry)
    return entry.scores[key] and entry.scores[key] / original_weight or nil
  end

  local to_deduct = 0
  local to_add = 0

  for key, original_weight in pairs(original_weights) do
    local hit_weight = get_unweighted(key, original_weight, success_entry)
    local miss_weight = get_unweighted(key, original_weight, miss_entry)
    if miss_weight ~= nil and hit_weight ~= nil then
      if miss_weight > hit_weight then
        to_deduct = to_deduct + (miss_weight - hit_weight)
      elseif hit_weight > miss_weight then
        to_add = to_add + (hit_weight - miss_weight)
      end
    end
  end

  for key, original_weight in pairs(original_weights) do
    local hit_weight = get_unweighted(key, original_weight, success_entry)
    local miss_weight = get_unweighted(key, original_weight, miss_entry)
    if miss_weight ~= nil and hit_weight ~= nil then
      local new_weight = weights[key]
      if miss_weight > hit_weight and to_deduct > 0 then
        new_weight = math.max(1, weights[key] - ADJUSTMENT_POINTS * factor * ((miss_weight - hit_weight) / to_deduct))
      elseif hit_weight > miss_weight and to_add > 0 then
        new_weight = weights[key] + ADJUSTMENT_POINTS * factor * ((hit_weight - miss_weight) / to_add)
      end
      weights[key] = new_weight
    end
  end
end

local function revise_weights(original_weights, results, selected)
  local new_weights = shallow_copy(original_weights)
  local greater_misses, lesser_misses = select_misses(results, selected.path)
  if #greater_misses + #lesser_misses == 0 then
    return original_weights
  end
  for _, miss in ipairs(greater_misses) do
    adjust_weights(original_weights, new_weights, selected, miss, 1 / #greater_misses)
  end
  for _, miss in ipairs(lesser_misses) do
    adjust_weights(original_weights, new_weights, selected, miss, 0.1 / #lesser_misses)
  end
  return new_weights
end

local State = {}
State.__index = State

function State.new(matcher, picker)
  SmartStore:setup()

  local current_buf = vim.api.nvim_get_current_buf()
  local current_path = vim.api.nvim_buf_get_name(current_buf)
  local alternate_buf = vim.fn.bufnr("#")
  local alternate_path = alternate_buf > 0 and vim.api.nvim_buf_get_name(alternate_buf) or nil
  local cwd = matcher.cwd or normalize(uv.cwd() or ".")
  local history_cwd = picker.opts.filter and picker.opts.filter.cwd and cwd or nil

  local self = setmetatable({
    store = SmartStore,
    weights = SmartStore:get_weights(),
    history = SmartStore:get_history(history_cwd),
    current_buf = current_buf,
    current_path = current_path ~= "" and normalize(current_path) or nil,
    alternate_buf = alternate_buf > 0 and alternate_buf or nil,
    alternate_path = alternate_path and alternate_path ~= "" and normalize(alternate_path) or nil,
    cwd = cwd,
    open_buffers = {},
    prompt_cache = {},
    slab = has_fzf and fzf.allocate_slab() or nil,
  }, State)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local path = normalize(name)
        self.open_buffers[path] = {
          bufnr = buf,
          is_modified = vim.bo[buf].modified,
        }
      end
    end
  end

  return self
end

function State:destroy()
  if not has_fzf then
    return
  end
  for _, pattern in pairs(self.prompt_cache) do
    fzf.free_pattern(pattern)
  end
  self.prompt_cache = {}
  if self.slab then
    fzf.free_slab(self.slab)
    self.slab = nil
  end
end

function State:path(item)
  if item._smart_path ~= nil then
    return item._smart_path ~= false and item._smart_path or nil
  end
  local path = item.file and Snacks.picker.util.path(item) or nil
  item._smart_path = path or false
  item.path = path
  return path
end

function State:history_data(path)
  return (path and self.history[path]) or { frecency = 0, recent_rank = 0 }
end

function State:get_prompt_struct(prompt)
  if not has_fzf then
    return
  end
  local cached = self.prompt_cache[prompt]
  if cached then
    return cached
  end
  cached = fzf.parse_pattern(prompt, 0, true)
  self.prompt_cache[prompt] = cached
  return cached
end

function State:prompt_score(prompt, text)
  if prompt == "" or text == "" or not has_fzf then
    return 0
  end
  local struct = self:get_prompt_struct(prompt)
  local score = fzf.get_score(text, struct, self.slab)
  if score == 0 then
    return 0
  end
  return normalize_fzf_score(1 / score, #text)
end

function State:score(matcher, item)
  local weights = self.weights
  local prompt = matcher.pattern or ""
  local cwd = matcher.cwd or self.cwd
  local path = self:path(item)
  local history = self:history_data(path)
  local path_text = path or item.file or item.text or ""
  local current = item.buf == self.current_buf or (path and path == self.current_path)
  local alt = item.buf == self.alternate_buf or (path and path == self.alternate_path)
  local open = path and self.open_buffers[path] ~= nil

  local scores = {
    open = 0,
    alt = 0,
    proximity = 0,
    project = 0,
    frecency = 0,
    recency = 0,
  }

  local base_score = 0
  if not current then
    if alt then
      scores.alt = weights.alt
      base_score = base_score + scores.alt
    end
    if open or item.buf then
      scores.open = weights.open
      base_score = base_score + scores.open
    end
    scores.frecency = weights.frecency * history.frecency
    base_score = base_score + scores.frecency
    if history.recent_rank > 0 then
      scores.recency = weights.recency * (8 / (history.recent_rank + 7))
      base_score = base_score + scores.recency
    end
    if path then
      local reference = self.current_path or cwd
      local proximity = calculate_proximity(reference, path)
      scores.proximity = weights.proximity * normalize_proximity(proximity)
      base_score = base_score + scores.proximity
    end
  end
  if path and path:sub(1, #cwd) == cwd then
    scores.project = weights.project
    base_score = base_score + scores.project
  end

  local match_score = 0
  if prompt ~= "" then
    if not has_fzf then
      scores.path_fzf = item.score or 0
      scores.virtual_name_fzf = 0
      match_score = scores.path_fzf
    else
      local path_score = self:prompt_score(prompt, path_text)
      if path_score == 0 then
        item.current = current
        item.scores = scores
        item.smart_base_score = base_score
        item.smart_match_score = 0
        item.score = 0
        return
      end
      scores.path_fzf = weights.path_fzf * path_score
      scores.virtual_name_fzf = weights.virtual_name_fzf * self:prompt_score(prompt, get_virtual_name(path_text))
      match_score = scores.path_fzf + scores.virtual_name_fzf
    end
  end

  item.current = current
  item.path = path
  item.scores = scores
  item.smart_base_score = base_score
  item.smart_match_score = match_score
  item.score = base_score + match_score
end

function M.on_select(picker, items)
  local item = items and items[1]
  local state = picker.matcher and picker.matcher._smart or nil
  local path = state and state:path(item) or (item and item.file and Snacks.picker.util.path(item)) or nil
  if not (item and path) then
    return
  end

  if not (state and state.current_path == path) then
    SmartStore:record_usage(path, true)
  end

  if not (state and item.scores) then
    return
  end

  local results = {}
  for _, result in ipairs(picker.finder.items) do
    if result.match_tick == picker.matcher.tick and result.score > 0 then
      results[#results + 1] = result
    end
  end
  table.sort(results, picker.sort)

  local original_weights = state.store:get_weights()
  local revised_weights = revise_weights(original_weights, results, item)
  state.store:save_weights(revised_weights)
  state.weights = revised_weights
end

function M.setup(opts)
  opts.smart_learn = true
  opts.matcher = vim.tbl_deep_extend("force", opts.matcher or {}, {
    cwd_bonus = false,
    frecency = false,
    sort_empty = true,
    on_start = function(matcher, picker)
      if matcher._smart then
        matcher._smart:destroy()
      end
      matcher._smart = State.new(matcher, picker)
    end,
    on_match = function(matcher, item)
      if matcher._smart then
        matcher._smart:score(matcher, item)
      end
    end,
    on_done = function(matcher)
      local picker = matcher.picker
      local state = matcher._smart
      if not (picker and state) then
        return
      end

      picker.list:set_target()
      picker.list:clear()
      for _, item in ipairs(picker.finder.items) do
        if item.match_tick == matcher.tick and item.score > 0 then
          state:score(matcher, item)
          if item.score > 0 then
            picker.list:add(item, matcher.sorting)
          end
        end
      end
      picker:update({ force = true })
    end,
    on_close = function(matcher)
      if matcher._smart then
        matcher._smart:destroy()
        matcher._smart = nil
      end
    end,
  })
  return opts
end

return M
