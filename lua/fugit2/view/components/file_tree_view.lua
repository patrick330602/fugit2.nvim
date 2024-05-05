---Fugit2 Git status file tree

local LogLevel = vim.log.levels

local NuiLine = require "nui.line"
local NuiPopup = require "nui.popup"
local NuiText = require "nui.text"
local NuiTree = require "nui.tree"
local Object = require "nui.object"
local Path = require "plenary.path"
local WebDevIcons = require "nvim-web-devicons"
local plenary_filetype = require "plenary.filetype"
local strings = require "plenary.strings"

local git2 = require "fugit2.git2"
local utils = require "fugit2.utils"

-- =================
-- |  Status tree  |
-- =================

---@class Fugit2StatusTreeNodeData
---@field id string
---@field text string
---@field icon string
---@field color string Extmark.
---@field wstatus string Worktree short status.
---@field istatus string Index short status.
---@field modified boolean Buffer is modifed or not
---@field loaded boolean Buffer is loaded or not

---@param dir_tree table
---@param prefix string Name to concat to form id
---@return NuiTree.Node[]
local function tree_construct_nodes(dir_tree, prefix)
  local files = {}
  local dir_idx = 1 -- index to insert directory
  for k, v in pairs(dir_tree) do
    if k == "." then
      for _, f in ipairs(v) do
        table.insert(files, NuiTree.Node(f))
      end
    else
      local id = prefix .. "/" .. k
      local children = tree_construct_nodes(v, id)
      local node = NuiTree.Node({ text = k, id = id }, children)
      node:expand()
      table.insert(files, dir_idx, node)
      dir_idx = dir_idx + 1
    end
  end

  return files
end

-- Gets colors for a tree node
---@param worktree_status GIT_DELTA
---@param index_status GIT_DELTA
---@param modified boolean
---@return string text_color Text color
---@return string icon_color Icon color
---@return string status_icon Status icon
local function tree_node_colors(worktree_status, index_status, modified)
  local text_color, icon_color = "Fugit2Modifier", "Fugit2Modifier"
  local status_icon = utils.get_git_status_icon(worktree_status, "  ")

  if worktree_status == git2.GIT_DELTA.CONFLICTED then
    text_color = "Fugit2Untracked"
    icon_color = "Fugit2Untracked"
  elseif worktree_status == git2.GIT_DELTA.UNTRACKED then
    text_color = "Fugit2Untracked"
    icon_color = "Fugit2Untracked"
  elseif worktree_status == git2.GIT_DELTA.IGNORED or index_status == git2.GIT_DELTA.IGNORED then
    text_color = "Fugit2Ignored"
    icon_color = "Fugit2Ignored"
    status_icon = utils.get_git_status_icon(git2.GIT_DELTA.IGNORED, "  ")
  elseif index_status == git2.GIT_DELTA.UNMODIFIED then
    text_color = "Fugit2Unchanged"
    icon_color = "Fugit2Unstaged"
    status_icon = "󰆢 "
  elseif worktree_status == git2.GIT_DELTA.MODIFIED then
    text_color = "Fugit2Modified"
    icon_color = "Fugit2Staged"
  else
    text_color = "Fugit2Staged"
    icon_color = "Fugit2Staged"
    status_icon = utils.get_git_status_icon(index_status, "󰱒 ")
  end

  if modified then
    text_color = "Fugit2Modified"
  end

  return text_color, icon_color, status_icon
end

---@param item GitStatusItem
---@param bufs table
---@param stats_head_to_index { [string]: GitDiffStats }
---@return Fugit2StatusTreeNodeData
local function tree_node_data_from_item(item, bufs, stats_head_to_index)
  local path = item.path
  local alt_path
  if item.renamed and item.worktree_status == git2.GIT_DELTA.UNMODIFIED then
    path = item.new_path or ""
  end

  local filename = vim.fs.basename(path)
  local extension = plenary_filetype.detect(filename, { fs_access = false })
  local loaded = bufs[path] ~= nil
  local modified = loaded and bufs[path].modified or false
  local conflicted = (
    item.worktree_status == git2.GIT_DELTA.CONFLICTED or item.index_status == git2.GIT_DELTA.CONFLICTED
  )

  local icon = WebDevIcons.get_icon(filename, extension, { default = true })
  local wstatus = git2.status_char_dash(item.worktree_status)
  local istatus = git2.status_char_dash(item.index_status)

  local text_color, icon_color, stage_icon = tree_node_colors(item.worktree_status, item.index_status, modified)

  local insertions, deletions
  if item.index_status ~= git2.GIT_DELTA.UNMODIFIED and item.index_status ~= git2.GIT_DELTA.UNTRACKED then
    local stats = stats_head_to_index[item.path]
    if stats then
      insertions = tostring(stats.insertions)
      deletions = tostring(stats.deletions)
    end
  end

  local rename = ""
  if item.renamed and item.index_status == git2.GIT_DELTA.UNMODIFIED then
    rename = " -> " .. utils.make_relative_path(vim.fs.dirname(item.path), item.new_path)
    alt_path = item.new_path
  elseif item.renamed and item.worktree_status == git2.GIT_DELTA.UNMODIFIED then
    rename = " <- " .. utils.make_relative_path(vim.fs.dirname(item.new_path), item.path)
    alt_path = item.path
  end

  local text = filename .. rename

  return {
    id = path,
    alt_path = alt_path,
    text = text,
    icon = icon,
    color = text_color,
    wstatus = wstatus,
    istatus = istatus,
    stage_icon = stage_icon,
    stage_color = icon_color,
    conflicted = conflicted,
    modified = modified,
    loaded = loaded,
    insertions = insertions,
    deletions = deletions,
  }
end

---@class Fugit2GitStatusTreeState
---@field padding integer

---@param states Fugit2GitStatusTreeState file entry padding
---@return fun(node: NuiTree.Node): NuiLine
local function create_tree_prepare_node_fn(states)
  return function(node)
    local line = NuiLine()
    line:append(string.rep("  ", node:get_depth() - 1))

    if node:has_children() then
      line:append(node:is_expanded() and "  " or "  ", "Fugit2SymbolicRef")
      line:append(node.text, "Fugit2SymbolicRef")
    else
      -- local format_str = "%s %-" .. (states.padding - node:get_depth() * 2) .. "s"
      -- line:append(string.format(format_str, node.icon, node.text), node.color)

      local left_align = (
        states.padding
        - node:get_depth() * 2
        - (node.modified and 4 or 0)
        - (node.insertions and node.insertions:len() + 2 or 0)
        - (node.deletions and node.deletions:len() + 2 or 0)
      )
      line:append(strings.align_str(node.icon .. " " .. node.text, left_align), node.color)

      if node.modified then
        line:append(" [+]", node.color)
      end

      if node.insertions then
        line:append(" +" .. node.insertions, "Fugit2Insertions")
      end
      if node.deletions then
        line:append(" -" .. node.deletions, "Fugit2Deletions")
      end

      line:append(" " .. node.stage_icon .. " " .. node.wstatus .. node.istatus, node.stage_color)
    end

    return line
  end
end

---@class Fugit2GitStatusTree
---@field ns_id integer
---@field tree NuiTree
---@field popup NuiPopup
local GitStatusTree = Object "Fugit2GitStatusTree"

---@param ns_id integer
---@param top_title string
---@param bottom_title string
---@param min_width integer
function GitStatusTree:init(ns_id, top_title, bottom_title, min_width)
  self.namespace = ns_id

  self.popup = NuiPopup {
    ns_id = ns_id,
    enter = true,
    focusable = true,
    zindex = 50,
    border = {
      style = "rounded",
      padding = { left = 1, right = 1 },
      text = {
        top = NuiText(top_title, "Fugit2FloatTitle"),
        top_align = "left",
        bottom = NuiText(bottom_title, "FloatFooter"),
        bottom_align = "right",
      },
    },
    win_options = {
      winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
      cursorline = true,
    },
    buf_options = {
      modifiable = false,
      readonly = true,
      swapfile = false,
      buftype = "nofile",
    },
  }

  ---@type Fugit2GitStatusTreeState
  self.states = { padding = min_width - 10 }

  self.tree = NuiTree {
    bufnr = self.popup.bufnr,
    ns_id = ns_id,
    buf_options = {
      buftype = "nofile",
      swapfile = false,
    },
    prepare_node = create_tree_prepare_node_fn(self.states),
    nodes = {},
  }
end

---@return NuiTree.Node?
---@return integer? linenr
function GitStatusTree:get_child_node_linenr()
  local node, linenr, _ = self.tree:get_node() -- get current node

  -- depth first search to get first child
  while node and node:has_children() do
    local children = node:get_child_ids()
    node, linenr, _ = self.tree:get_node(children[1])
  end

  return node, linenr
end

---@param status GitStatusItem[]
---@param git_path string git root path, used to detect modifed buffer
---@param diff_head_to_index GitDiff? diff head to index
function GitStatusTree:update(status, git_path, diff_head_to_index)
  -- get all bufs modified info
  local bufs = {}
  for _, bufnr in pairs(vim.tbl_filter(vim.api.nvim_buf_is_loaded, vim.api.nvim_list_bufs())) do
    local b = vim.bo[bufnr]
    if b then
      local path = Path:new(vim.api.nvim_buf_get_name(bufnr)):make_relative(git_path)
      bufs[path] = {
        modified = b.modified,
      }
    end
  end

  -- get stats head to index
  local stats_head_to_index = {}
  if diff_head_to_index then
    local patches, _ = diff_head_to_index:patches(false)
    if patches then
      for _, p in ipairs(patches) do
        local stats, _ = p.patch:stats()
        if stats then
          stats_head_to_index[p.path] = stats
        end
      end
    end
  end

  -- prepare tree
  local dir_tree = {}

  for _, item in ipairs(status) do
    local dirname = vim.fs.dirname(item.path)
    if item.renamed and item.worktree_status == git2.GIT_DELTA.UNMODIFIED then
      dirname = vim.fs.dirname(item.new_path)
    end

    local dir = dir_tree
    if dirname ~= "" and dirname ~= "." then
      for s in vim.gsplit(dirname, "/", { plain = true }) do
        if dir[s] then
          dir = dir[s]
        else
          dir[s] = {}
          dir = dir[s]
        end
      end
    end

    local entry = tree_node_data_from_item(item, bufs, stats_head_to_index)

    if dir["."] then
      table.insert(dir["."], entry)
    else
      dir["."] = { entry }
    end
  end

  self.tree:set_nodes(tree_construct_nodes(dir_tree, ""))
end

-- Adds, stage unstage a node from index.
---@param repo GitRepository
---@param index GitIndex
---@param add boolean enable add to index
---@param reset boolean enable reset from index
---@param node NuiTree.Node
---@return boolean updated Tree is updated or not.
---@return boolean refresh Whether needed to do full refresh.
function GitStatusTree:index_add_reset(repo, index, add, reset, node)
  local err
  local updated = false
  local inplace = true -- whether can update status inplace

  if add and node.alt_path and (node.wstatus == "R" or node.wstatus == "M") then
    -- rename
    err = index:add_bypath(node.alt_path)
    if err ~= 0 then
      vim.notify("[Fugit2] Git Error when handling rename " .. err, LogLevel.ERROR)
      return false, false
    end

    err = index:remove_bypath(node.id)
    if err ~= 0 then
      vim.notify("[Fugit2] Git Error when handling rename " .. err, LogLevel.ERROR)
      return false, false
    end

    updated = true
    inplace = false -- requires full refresh
  elseif add and (node.wstatus == "?" or node.wstatus == "T" or node.wstatus == "M" or node.conflicted) then
    -- add to index if worktree status is in (UNTRACKED, MODIFIED, TYPECHANGE)
    err = index:add_bypath(node.id)
    if err ~= 0 then
      vim.notify("[Fugit2] Git Error when adding to index: " .. err, LogLevel.ERROR)
      return false, false
    end

    updated = true
  elseif add and node.wstatus == "D" then
    -- remove from index
    err = index:remove_bypath(node.id)
    if err ~= 0 then
      vim.notify("[Fugit2] Git error when removing from index: " .. err, LogLevel.ERROR)
      return false, false
    end

    updated = true
  elseif reset and node.alt_path and (node.istatus == "R" or node.istatus == "M") then
    -- reset both paths if rename in index
    err = repo:reset_default { node.id, node.alt_path }
    if err ~= 0 then
      vim.notify("[Fugit2] Git error when reset rename: " .. err, LogLevel.ERROR)
      return false, false
    end

    updated = true
    inplace = false -- requires full refresh
  elseif reset and node.istatus ~= "-" and node.istatus ~= "?" then
    -- else reset if index status is not in (UNCHANGED, UNTRACKED, RENAMED)
    err = repo:reset_default { node.id }
    if err == git2.GIT_ERROR.GIT_EUNBORNBRANCH then
      err = index:remove_bypath(node.id)
    end
    if err ~= 0 then
      vim.notify("[Fugit2] Git error when unstage from index: " .. err, LogLevel.ERROR)
      return false, false
    end

    updated = true
  end

  -- inplace update
  if updated and inplace then
    if self:update_single_node(repo, node) ~= 0 then
      -- require full refresh if update failed
      inplace = false
    end
  end

  return updated, not inplace
end

-- Checkouts file from head, have the same effect as discard.
---@param repo GitRepository
---@param index GitIndex
---@param node NuiTree.Node
---@return boolean updated Tree is updated or not.
---@return boolean refresh Whether needed to do full refresh.
function GitStatusTree:index_checkout(repo, index, node)
  local err
  local updated = false
  local inplace = true -- whether can update status inplace

  if node.wstatus ~= "-" then
    -- err = repo:checkout_head({node.id})
    err = repo:checkout_index(index, git2.GIT_CHECKOUT.FORCE, { node.id })
    if err ~= 0 then
      error("Git Error when checkout head: " .. err)
    end
    updated = true
  end

  -- inplace update
  if updated then
    if self:update_single_node(repo, node) ~= 0 then
      -- require full refresh if update failed
      inplace = false
    end
  end

  -- update file buffer
  if node.loaded then
    vim.cmd.checktime(node.id)
  end

  return updated, not inplace
end

---Updates file node status info, usually called after stage/unstage
---@param repo GitRepository
---@param node NuiTree.Node
---@return GIT_ERROR
function GitStatusTree:update_single_node(repo, node)
  if not node.id then
    return 0
  end

  local worktree_status, index_status, err = repo:status_file(node.id)
  if err ~= 0 then
    return err
  end

  node.wstatus = git2.status_char_dash(worktree_status)
  node.istatus = git2.status_char_dash(index_status)
  node.color, node.stage_color, node.stage_icon =
    tree_node_colors(worktree_status, index_status, node.modified or false)
  node.conflicted = worktree_status == git2.GIT_DELTA.CONFLICTED or index_status == git2.GIT_DELTA.CONFLICTED

  -- update insertions and deletions
  if node.istatus ~= "-" and node.istatus ~= "?" then
    local diff, _ = repo:diff_head_to_index(nil, { node.id })
    if diff then
      local stats = diff:stats()
      if stats and stats.changed == 1 then
        node.insertions = tostring(stats.insertions)
        node.deletions = tostring(stats.deletions)
      end
    end
  else
    node.insertions = nil
    node.deletions = nil
  end

  -- delete node when status == "--" and not conflicted
  if node.wstatus == "-" and node.istatus == "-" and not node.conflicted then
    local parent_id = node:get_parent_id()
    self.tree:remove_node(node:get_id())
    while parent_id ~= nil do
      local n = self.tree:get_node(parent_id)
      if n and not n:has_children() then
        parent_id = n:get_parent_id()
        self.tree:remove_node(n:get_id())
      else
        break
      end
    end
  end

  return 0
end

---@param width integer
function GitStatusTree:set_width(width)
  self.states.padding = width - 13
end

function GitStatusTree:render()
  vim.api.nvim_buf_set_option(self.popup.bufnr, "readonly", false)
  self.tree:render()
  vim.api.nvim_buf_set_option(self.popup.bufnr, "readonly", true)
end

function GitStatusTree:focus()
  local winid = self.popup.winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_set_current_win(winid)
  end
end

---@param mode string
---@param key string|string[]
---@param fn fun()|string
---@param opts table
function GitStatusTree:map(mode, key, fn, opts)
  return self.popup:map(mode, key, fn, opts)
end

---@param event string | string[]
---@param handler fun()
function GitStatusTree:on(event, handler)
  return self.popup:on(event, handler)
end

return GitStatusTree
