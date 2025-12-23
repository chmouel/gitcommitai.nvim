local TRAILER_RE = "^[%w%-]+:"

-- Configuration
local M = {}
M.config = {
  model = "gemini:gemini-2.5-flash-lite",
  role = "gitcommit",
  subject_warn_length = 50,
  subject_error_length = 72,
  ticket_patterns = {
    "(%a+%-%d%d%d+)",                                 -- letters-digits (3+ digits): srvkp-9991, JIRA-123
    "(%a+_%d%d%d+)",                                  -- letters_digits (3+ digits): JIRA_123
    "#(%d+)",                                         -- #123 (GitHub issues)
  },
  jira_base_url = "https://issues.redhat.com/browse", -- Base URL for Jira tickets
  jira_uppercase = true,                              -- Convert ticket to uppercase (srvkp-9991 -> SRVKP-9991)
  trailers = {
    { name = "Claude",         line = "Co-Authored-By: Claude <noreply@anthropic.com>" },
    { name = "GitHub Copilot", line = "AI-assisted-by: GitHub Copilot" },
    { name = "Google Gemini",  line = "AI-assisted-by: Google Gemini" },
    { name = "OpenAI ChatGPT", line = "AI-assisted-by: OpenAI ChatGPT" },
    { name = "Cursor",         line = "AI-assisted-by: Cursor" },
  },
  conventional_commits = {
    { type = "feat",     desc = "A new feature" },
    { type = "fix",      desc = "A bug fix" },
    { type = "docs",     desc = "Documentation only changes" },
    { type = "style",    desc = "Code style (formatting, semicolons, etc)" },
    { type = "refactor", desc = "Code change that neither fixes a bug nor adds a feature" },
    { type = "perf",     desc = "A code change that improves performance" },
    { type = "test",     desc = "Adding missing tests or correcting existing tests" },
    { type = "build",    desc = "Changes to build system or dependencies" },
    { type = "ci",       desc = "Changes to CI configuration" },
    { type = "chore",    desc = "Other changes that don't modify src or test files" },
    { type = "revert",   desc = "Reverts a previous commit" },
  },
}

-- State
local state = {
  last_message = nil, -- for undo
  ns_id = nil,        -- namespace for virtual text
}

--- Setup function for plugin configuration
---@param opts table|nil Configuration options
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- Forward declaration
local reflow_commit_message

-- Helper functions (consolidated)
local function is_blank(s) return s:match("^%s*$") ~= nil end

-- Remove "END OF INPUT" marker from AI output
local function clean_ai_output(lines)
  while #lines > 0 and lines[#lines]:match("^END OF INPUT$") do
    lines[#lines] = nil
  end
  return lines
end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function is_trailer_key_line(line) return line:match("^[%w][%w%-]*:%s+%S") ~= nil end
local function is_trailer_continuation(line) return line:match("^[ \t]+%S") ~= nil end

local function get_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function set_lines(bufnr, start, finish, lines)
  vim.api.nvim_buf_set_lines(bufnr, start, finish, false, lines)
end

local function find_comment_start(lines)
  for i, l in ipairs(lines) do
    if l:match("^#") then return i end
  end
  return nil
end

local function split_comments(lines)
  local c = find_comment_start(lines)
  if not c then return lines, {} end

  local msg, comments = {}, {}
  for i = 1, c - 1 do msg[#msg + 1] = lines[i] end
  for i = c, #lines do comments[#comments + 1] = lines[i] end
  return msg, comments
end

local function scan_commit(lines)
  local scan = {
    has_content = false,
    first_trailer = nil,
    first_comment = nil,
  }

  for i, line in ipairs(lines) do
    if line:match("^#") then
      scan.first_comment = i
      break
    end

    if line:match(TRAILER_RE) then
      scan.first_trailer = scan.first_trailer or i
    elseif line:match("%S") then
      scan.has_content = true
    end
  end

  return scan
end

local function peel_trailers(message_lines)
  local n = #message_lines
  if n == 0 then return {}, {} end

  local i = n
  while i >= 1 and is_blank(message_lines[i]) do
    i = i - 1
  end
  if i < 1 then return {}, {} end

  local trailer_end = i
  local saw_key = false

  while i >= 1 do
    local line = message_lines[i]
    if is_trailer_key_line(line) then
      saw_key = true
      i = i - 1
    elseif is_trailer_continuation(line) then
      i = i - 1
    else
      break
    end
  end

  if not saw_key then
    return message_lines, {}
  end

  local trailer_start = i + 1

  local body = {}
  for j = 1, trailer_start - 1 do body[#body + 1] = message_lines[j] end

  local trailers = {}
  for j = trailer_start, trailer_end do trailers[#trailers + 1] = message_lines[j] end

  return body, trailers
end

-- Get message lines (excluding comments and trailers) for undo
local function get_message_for_undo(bufnr)
  local lines = get_lines(bufnr)
  local msg, _ = split_comments(lines)
  local body, _ = peel_trailers(msg)
  return body
end

-- Save current message for undo
local function save_for_undo(bufnr)
  state.last_message = get_message_for_undo(bufnr)
end

-- Extract ticket from branch name
local function extract_ticket_from_branch()
  local branch = vim.fn.system("git branch --show-current 2>/dev/null"):gsub("\n", "")
  if vim.v.shell_error ~= 0 or branch == "" then
    return nil, nil
  end

  for _, pattern in ipairs(M.config.ticket_patterns) do
    local ticket = branch:match(pattern)
    if ticket then
      -- For GitHub-style #123, return with hash and mark as github
      if pattern:match("^#") then
        return "#" .. ticket, "github"
      end
      -- For Jira-style tickets
      if M.config.jira_uppercase then
        ticket = ticket:upper()
      end
      return ticket, "jira"
    end
  end
  return nil, nil
end

-- Subject line length indicator
local function update_subject_indicator(bufnr)
  if not state.ns_id then
    state.ns_id = vim.api.nvim_create_namespace("gitcommit_subject")
  end

  -- Clear all existing virtual text in namespace
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns_id, 0, -1)

  local lines = get_lines(bufnr)
  if #lines == 0 then return end

  local subject = lines[1]
  local len = #subject

  if len == 0 then return end

  local text, hl
  if len > M.config.subject_error_length then
    text = string.format(" ← %d chars (max %d)", len, M.config.subject_error_length)
    hl = "DiagnosticError"
  elseif len > M.config.subject_warn_length then
    text = string.format(" ← %d chars (aim for ≤%d)", len, M.config.subject_warn_length)
    hl = "DiagnosticWarn"
  else
    text = string.format(" ← %d", len)
    hl = "DiagnosticHint"
  end

  vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, 0, 0, {
    virt_text = { { text, hl } },
    virt_text_pos = "eol",
  })
end

-- Setup subject line indicator autocmd
local function setup_subject_indicator(bufnr)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = function()
      update_subject_indicator(bufnr)
    end,
  })
  -- Initial update
  update_subject_indicator(bufnr)
end

-- Async commit generation using vim.system (Neovim 0.10+)
local function generate_commit_async(bufnr, callback)
  local input = table.concat(get_lines(bufnr), "\n")

  local cmd = {
    "aichat",
    "-m" .. M.config.model,
    "-r" .. M.config.role,
  }

  -- Check if vim.system exists (Neovim 0.10+)
  if vim.system then
    vim.notify("Generating commit message...", vim.log.levels.INFO)

    vim.system(cmd, { stdin = input }, function(obj)
      vim.schedule(function()
        if obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
          vim.notify("Failed to generate commit message via aichat", vim.log.levels.WARN)
          if callback then callback(false) end
          return
        end

        local output = vim.split(obj.stdout, "\n", { trimempty = true })
        clean_ai_output(output)
        vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, output)
        reflow_commit_message(bufnr)
        vim.notify("Commit message generated", vim.log.levels.INFO)
        if callback then callback(true) end
      end)
    end)
  else
    -- Fallback to sync for older Neovim
    local output = vim.fn.systemlist(cmd, input)
    if vim.v.shell_error ~= 0 or not output or #output == 0 then
      vim.notify("Failed to generate commit message via aichat", vim.log.levels.WARN)
      if callback then callback(false) end
      return
    end
    clean_ai_output(output)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, output)
    reflow_commit_message(bufnr)
    if callback then callback(true) end
  end
end

local function wrap_body(bufnr, start_line, end_line)
  if not start_line or not end_line or end_line < start_line then
    return
  end

  local tw = vim.bo[bufnr].textwidth
  if tw == 0 then
    tw = 72
  end

  local ok, err = pcall(function()
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd(
        string.format(
          "silent %d,%d!fmt -w %d",
          start_line,
          end_line,
          tw
        )
      )
    end)
  end)

  if not ok then
    vim.notify("fmt command failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function cleanup_blank_lines(bufnr, scan)
  if not scan.first_comment then
    return
  end

  local lines = get_lines(bufnr)
  local last = scan.first_comment - 1

  while last > 0 and lines[last]:match("^%s*$") do
    last = last - 1
  end

  if last < scan.first_comment - 1 then
    set_lines(bufnr, last + 1, scan.first_comment - 1, {})
  end
end

local function delete_message(bufnr)
  local lines = get_lines(bufnr)
  local scan = scan_commit(lines)

  local stop = scan.first_comment
      or scan.first_trailer
      or (#lines + 1)

  if stop > 1 then
    set_lines(bufnr, 0, stop - 1, {})
  end
end

local function insert_trailer(bufnr, trailer_kv)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local message_lines, _ = split_comments(lines)
  local message = table.concat(message_lines, "\n")

  local cmd = { "git", "interpret-trailers", "--trailer", trailer_kv }
  local out = vim.fn.systemlist(cmd, message)

  if vim.v.shell_error ~= 0 or not out or #out == 0 then
    vim.notify("git interpret-trailers failed", vim.log.levels.WARN)
    return
  end

  local msg_end = #message_lines
  local new_lines = out
  if msg_end < #lines then
    for i = msg_end + 1, #lines do
      new_lines[#new_lines + 1] = lines[i]
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

local function wrap_paragraph_words(words, first_prefix, next_prefix, width)
  local out = {}
  local line = first_prefix
  local line_len = #line

  for _, w in ipairs(words) do
    local wlen = #w
    local needs_space = line_len > #first_prefix

    if needs_space then
      if line_len + 1 + wlen <= width then
        line = line .. " " .. w
        line_len = line_len + 1 + wlen
      else
        out[#out + 1] = line
        line = next_prefix .. w
        line_len = #line
      end
    else
      line = line .. w
      line_len = line_len + wlen
    end
  end

  out[#out + 1] = line
  return out
end

-- Check if line starts a new list item
local function is_list_item(line)
  local content = line:match("^%s*(.*)") or line
  return content:match("^[%-%*%+]%s+") or content:match("^%d+%.%s+")
end

local function wrap_body_lines(body_lines, width)
  local wrapped = {}
  local i = 1

  local function flush_paragraph(par_lines)
    if #par_lines == 0 then return end

    local first = par_lines[1]
    local leading = first:match("^(%s*)") or ""
    local content = first:sub(#leading + 1)

    local bullet = content:match("^([%-%*%+])%s+")
    local ordered = content:match("^%d+%.%s+")
    local prefix_first, prefix_next

    if bullet then
      prefix_first = leading .. bullet .. " "
      prefix_next = leading .. string.rep(" ", #bullet + 1)
      content = content:gsub("^" .. vim.pesc(bullet) .. "%s+", "")
    elseif ordered then
      prefix_first = leading .. ordered
      prefix_next = leading .. string.rep(" ", #ordered)
      content = content:gsub("^%d+%.%s+", "")
    else
      prefix_first = leading
      prefix_next = leading
    end

    local words = {}
    local hard_breaks = {}

    local function add_words_from(s)
      for w in s:gmatch("%S+") do
        words[#words + 1] = w
      end
    end

    add_words_from(content)
    hard_breaks[#hard_breaks + 1] = first:match("%s%s$") ~= nil

    for k = 2, #par_lines do
      local ln = par_lines[k]
      local ln_trim = trim(ln)
      add_words_from(ln_trim)
      hard_breaks[#hard_breaks + 1] = ln:match("%s%s$") ~= nil
    end

    if vim.tbl_contains(hard_breaks, true) then
      for _, ln in ipairs(par_lines) do
        local ln_lead = ln:match("^(%s*)") or ""
        local ln_content = trim(ln)
        if ln_content == "" then
          wrapped[#wrapped + 1] = ""
        else
          local wds = {}
          for w in ln_content:gmatch("%S+") do wds[#wds + 1] = w end
          local chunk = wrap_paragraph_words(wds, ln_lead, ln_lead, width)
          for _, o in ipairs(chunk) do wrapped[#wrapped + 1] = o end
        end
      end
      return
    end

    local out = wrap_paragraph_words(words, prefix_first, prefix_next, width)
    for _, o in ipairs(out) do wrapped[#wrapped + 1] = o end
  end

  while i <= #body_lines do
    if is_blank(body_lines[i]) then
      wrapped[#wrapped + 1] = ""
      i = i + 1
    else
      local par = {}
      while i <= #body_lines and not is_blank(body_lines[i]) do
        -- If this is a new list item and we already have content, start new paragraph
        if #par > 0 and is_list_item(body_lines[i]) then
          break
        end
        par[#par + 1] = body_lines[i]
        i = i + 1
      end
      flush_paragraph(par)
    end
  end

  while #wrapped > 0 and is_blank(wrapped[#wrapped]) do
    wrapped[#wrapped] = nil
  end

  return wrapped
end

reflow_commit_message = function(bufnr)
  local tw = vim.bo[bufnr].textwidth
  if tw == 0 then tw = 72 end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local message, comments = split_comments(lines)

  while #message > 0 and is_blank(message[1]) do
    table.remove(message, 1)
  end
  if #message == 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, comments)
    return
  end

  local msg_wo_trailers, trailers = peel_trailers(message)

  local subject = trim(msg_wo_trailers[1] or "")
  local rest = {}
  for j = 2, #msg_wo_trailers do rest[#rest + 1] = msg_wo_trailers[j] end

  while #rest > 0 and is_blank(rest[1]) do
    table.remove(rest, 1)
  end

  local body = wrap_body_lines(rest, tw)

  local out = {}
  out[#out + 1] = subject
  out[#out + 1] = ""

  for _, l in ipairs(body) do out[#out + 1] = l end

  if #trailers > 0 then
    if #out > 0 and not is_blank(out[#out]) then
      out[#out + 1] = ""
    elseif #out > 0 then
      while #out > 0 and is_blank(out[#out]) do out[#out] = nil end
      out[#out + 1] = ""
    end
    for _, l in ipairs(trailers) do out[#out + 1] = l end
  end

  for _, l in ipairs(comments) do out[#out + 1] = l end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, out)
end

local function replace_message_keep_trailers(bufnr, new_message_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local msg, comments = split_comments(lines)
  local _, trailers = peel_trailers(msg)

  local out = {}
  for _, l in ipairs(new_message_lines) do out[#out + 1] = l end

  if #trailers > 0 then
    while #out > 0 and is_blank(out[#out]) do out[#out] = nil end
    out[#out + 1] = ""
    for _, l in ipairs(trailers) do out[#out + 1] = l end
  end

  for _, l in ipairs(comments) do out[#out + 1] = l end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, out)
end

-- Async regenerate commit message
local function regenerate_commit_message(bufnr)
  save_for_undo(bufnr)

  local input = table.concat(get_lines(bufnr), "\n")
  local cmd = { "aichat", "-m" .. M.config.model, "-r" .. M.config.role }

  if vim.system then
    vim.notify("Regenerating commit message...", vim.log.levels.INFO)

    vim.system(cmd, { stdin = input }, function(obj)
      vim.schedule(function()
        if obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
          vim.notify("Failed to generate commit message via aichat", vim.log.levels.WARN)
          return
        end

        local gen = vim.split(obj.stdout, "\n", { trimempty = true })
        clean_ai_output(gen)
        replace_message_keep_trailers(bufnr, gen)
        reflow_commit_message(bufnr)
        update_subject_indicator(bufnr)
        vim.notify("Commit message regenerated", vim.log.levels.INFO)
      end)
    end)
  else
    -- Fallback to sync
    local gen = vim.fn.systemlist(cmd, input)
    if vim.v.shell_error ~= 0 or not gen or #gen == 0 then
      vim.notify("Failed to generate commit message via aichat", vim.log.levels.WARN)
      return
    end
    clean_ai_output(gen)
    replace_message_keep_trailers(bufnr, gen)
    reflow_commit_message(bufnr)
    update_subject_indicator(bufnr)
  end
end

-- Restore previous message (undo)
local function restore_previous_message(bufnr)
  if not state.last_message or #state.last_message == 0 then
    vim.notify("No previous message to restore", vim.log.levels.WARN)
    return
  end

  replace_message_keep_trailers(bufnr, state.last_message)
  vim.notify("Previous message restored", vim.log.levels.INFO)
  update_subject_indicator(bufnr)
end

-- Apply conventional commit type to subject line
local function apply_conventional_commit(bufnr)
  vim.ui.select(
    M.config.conventional_commits,
    {
      prompt = "Select commit type:",
      format_item = function(item)
        return string.format("%-10s %s", item.type .. ":", item.desc)
      end,
    },
    function(choice)
      if not choice then return end

      local lines = get_lines(bufnr)
      if #lines == 0 then
        set_lines(bufnr, 0, 0, { choice.type .. ": " })
        return
      end

      local subject = lines[1]

      -- Remove existing conventional commit prefix if present
      local existing_type = subject:match("^(%w+)%(?[^%)]*%)?:%s*")
      if existing_type then
        -- Check if it's a known type
        for _, cc in ipairs(M.config.conventional_commits) do
          if cc.type == existing_type then
            subject = subject:gsub("^%w+%(?[^%)]*%)?:%s*", "")
            break
          end
        end
      end

      -- Prompt for optional scope
      vim.ui.input({ prompt = "Scope (optional): " }, function(scope)
        local prefix
        if scope and scope ~= "" then
          prefix = choice.type .. "(" .. scope .. "): "
        else
          prefix = choice.type .. ": "
        end

        local new_subject = prefix .. subject
        lines[1] = new_subject
        set_lines(bufnr, 0, 1, { new_subject })
        update_subject_indicator(bufnr)
      end)
    end
  )
end

-- Insert ticket from branch name
local function insert_ticket_trailer(bufnr)
  local ticket, ticket_type = extract_ticket_from_branch()
  if not ticket then
    vim.notify("No ticket found in branch name", vim.log.levels.WARN)
    return
  end

  -- Determine trailer format based on ticket type
  local trailer
  if ticket_type == "github" then
    trailer = "Fixes: " .. ticket
  else
    -- Jira ticket - build full URL
    local url = M.config.jira_base_url .. "/" .. ticket
    trailer = "Jira: " .. url
  end

  insert_trailer(bufnr, trailer)
  vim.notify("Added ticket: " .. ticket, vim.log.levels.INFO)
end

local function setup_keymaps(bufnr)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = bufnr,
      desc = desc,
      silent = true,
    })
  end

  map("<leader>a.", function()
    regenerate_commit_message(bufnr)
  end, "Regenerate commit message")

  map("<leader>au", function()
    restore_previous_message(bufnr)
  end, "Undo/restore previous message")

  map("<leader>ac", function()
    save_for_undo(bufnr)
    set_lines(bufnr, 0, -1, {})
  end, "Clear entire buffer")

  map("<leader>ad", function()
    save_for_undo(bufnr)
    delete_message(bufnr)
  end, "Delete commit message body")

  map("<leader>at", function()
    insert_ticket_trailer(bufnr)
  end, "Add ticket from branch name")

  map("<leader>aT", function()
    apply_conventional_commit(bufnr)
  end, "Apply conventional commit type")

  map("<leader>a,", function()
    vim.ui.select(
      M.config.trailers,
      {
        prompt = "Choose AI tool for trailer:",
        format_item = function(item)
          return item.name
        end,
      },
      function(choice)
        if choice then
          insert_trailer(bufnr, choice.line)
        end
      end
    )
  end, "Add AI or co-author trailer")
end

vim.api.nvim_create_autocmd("BufEnter", {
  pattern = "COMMIT_EDITMSG",
  once = true,
  callback = function(args)
    local bufnr = args.buf

    vim.bo[bufnr].filetype = "gitcommit"
    setup_keymaps(bufnr)
    setup_subject_indicator(bufnr)

    local lines = get_lines(bufnr)
    local scan = scan_commit(lines)

    if scan.has_content then
      return
    end

    generate_commit_async(bufnr, function(success)
      if not success then return end

      local new_lines = get_lines(bufnr)
      local new_scan = scan_commit(new_lines)

      local body_start = 1
      local body_end =
          (new_scan.first_trailer or new_scan.first_comment or (#new_lines + 1))
          - 1

      wrap_body(bufnr, body_start, body_end)
      cleanup_blank_lines(bufnr, new_scan)
      update_subject_indicator(bufnr)
    end)
  end,
})

return M
