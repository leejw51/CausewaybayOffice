-- AI tool registry (function calling for the assist page) and executor.
--
-- Built-in tools read the terminal screen, run a command (after the user
-- approves its unrestricted access in the panel), search and save notes,
-- and define new tools. A user tool is a shell command template with
-- `{param}` placeholders; the model calls it like any function and the
-- office types the expanded command into the terminal. Definitions are
-- rows of <data dir>/tools.jsonl (Core.jsonlSave "tools") and take effect
-- at once: the next request already carries the new tool.
--
-- The core never runs anything: every command goes through the terminal
-- scene's write, so it is visible. Only confined generated file operations
-- may run automatically in CODE mode; arbitrary shell access needs approval.

local json = require("src.json")

local T = {}
T.STORE = "tools"
T.MAX_RESULT = 6000 -- characters of a tool result handed back to the model
T.MAX_USER_TOOLS = 64
T.TIMEOUT = 30 -- show a waiting hint; silence never means a command finished

T.user = {} -- user-defined tools, in definition order
T.loaded = false

-- ---- helpers ---------------------------------------------------------------

-- One identifier: what a tool and a `{placeholder}` may be called.
T.NAME = "[%a_][%w_]*"

function T.validName(name)
  return type(name) == "string" and name:match("^" .. T.NAME .. "$") ~= nil and #name <= 48
end

-- Single-quoted for POSIX shells: any character but a quote, which is spliced.
function T.shellQuote(v)
  v = tostring(v == nil and "" or v)
  return "'" .. v:gsub("'", "'\\''") .. "'"
end

-- Expand `{param}` placeholders with quoted argument values; a missing
-- argument becomes an empty quoted string. The placeholder pattern is the
-- one `validName` accepts, so every name a tool may declare is expandable.
function T.expand(template, args)
  args = args or {}
  return (
    template:gsub("{(" .. T.NAME .. ")}", function(name)
      return T.shellQuote(args[name])
    end)
  )
end

-- "path, count" or {"path","count"} -> {"path","count"}; a JSON-schema object
-- is kept as the parameters themselves.
function T.paramsOf(spec)
  if type(spec) == "table" then
    if spec.type == "object" then
      return spec
    end
    local out = {}
    for _, p in ipairs(spec) do
      if T.validName(p) then
        out[#out + 1] = p
      end
    end
    return out
  end
  local out = {}
  for p in tostring(spec or ""):gmatch(T.NAME) do
    out[#out + 1] = p
  end
  return out
end

-- JSON schema for a tool's parameters (empty object when it takes none).
function T.schema(tool)
  if tool.parameters then
    return tool.parameters
  end
  local params = tool.params or tool.parameters
  if type(params) == "table" and params.type == "object" then
    return params
  end
  local props, required = json.object({}), {}
  for _, p in ipairs(T.paramsOf(params)) do
    props[p] = { type = "string", description = (tool.paramDocs or {})[p] or p }
    required[#required + 1] = p
  end
  local schema = { type = "object", properties = props }
  if #required > 0 then
    schema.required = required
  end
  return schema
end

local function clip(text, limit)
  text = tostring(text or "")
  limit = limit or T.MAX_RESULT
  if #text > limit then
    return text:sub(1, limit) .. "\n…(clipped)"
  end
  return text
end

local function lastLines(text, n)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  if n and n > 0 and #lines > n then
    local out = {}
    for i = #lines - n + 1, #lines do
      out[#out + 1] = lines[i]
    end
    lines = out
  end
  return table.concat(lines, "\n")
end

-- ---- command jobs ----------------------------------------------------------

-- A command that the terminal types once approved; done when the screen
-- prints its completion marker; result = visible output before the marker.
local Job = {}
Job.__index = Job
local nextJob = 0

function T.commandJob(command, ctx, auto)
  nextJob = nextJob + 1
  local job = setmetatable({
    command = command,
    ctx = ctx,
    done = false,
    result = nil,
    needsApproval = not auto,
    started = false,
    t = 0,
    marker = "CBO_DONE_" .. tostring(ctx.core and ctx.core.nowMs() or 0) .. "_" .. nextJob,
  }, Job)
  if auto then
    job:approve()
  end
  return job
end

function Job:approve()
  if self.started or self.done then
    return
  end
  self.needsApproval = false
  self.started = true
  local ctx = self.ctx
  if not ctx.write then
    self:finish("no terminal to run the command in")
    return
  end
  -- eval preserves the working directory in bash/zsh/fish. Split the marker
  -- in the echoed input so only the printf output can satisfy completion.
  self.startMarker = "CBO_START_" .. self.marker:sub(10)
  local written = ctx.write(
    "printf '\\n%s%s\\n' 'CBO_START_' "
      .. T.shellQuote(self.marker:sub(10))
      .. "; eval "
      .. T.shellQuote(self.command)
      .. " && printf '\\n%s%s:0\\n' 'CBO_DONE_' "
      .. T.shellQuote(self.marker:sub(10))
      .. " || printf '\\n%s%s:1\\n' 'CBO_DONE_' "
      .. T.shellQuote(self.marker:sub(10))
      .. "\n"
  )
  if written == false then
    self:finish("error: terminal session changed or disconnected")
  end
end

function Job:cancel()
  if self.started and not self.done and self.ctx.write then
    self.ctx.write("\3")
  end
  self:finish("Cancelled by the user: " .. self.command)
end

function Job:deny()
  if not self.done then
    self:finish("The user declined to run: " .. self.command)
  end
end

function Job:finish(result)
  self.done = true
  self.result = clip(result)
end

function Job:update(dt)
  if self.done or not self.started then
    return
  end
  self.t = self.t + dt
  local screen = self.ctx.screenText and self.ctx.screenText() or ""
  local result = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do
    local clean = line:match("^%s*(.-)%s*$")
    if clean == self.marker .. ":0" or clean == self.marker .. ":1" then
      self.success = clean == self.marker .. ":0"
      self:finish(
        "$ "
          .. self.command
          .. "\n"
          .. (self.success and "[success]\n" or "[failed]\n")
          .. lastLines(table.concat(result, "\n"), 40)
      )
      return
    end
    if line:match("^%s*(.-)%s*$") == self.startMarker then
      result = {}
    else
      result[#result + 1] = line
    end
  end
  self.waiting = self.t >= T.TIMEOUT
end

-- An immediate result as a job (same interface as a command job).
local function immediate(result)
  return { done = true, result = clip(result) }
end

function T.normalizePath(path)
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
    return nil
  end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      table.remove(parts)
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

function T.insideWorkspace(root, path)
  root, path = T.normalizePath(root), T.normalizePath(path)
  return root ~= nil
    and path ~= nil
    and (root == "/" or path == root or path:sub(1, #root + 1) == root .. "/")
end

-- An arbitrary shell command (including a compiler or the generated program)
-- can access any file available to the SSH user. Never treat a prompt, cwd,
-- or a string/path check as a filesystem sandbox. Approval is per operation.
function T.shellJob(command, ctx)
  local job = T.commandJob(command, ctx, ctx.autoRun and not ctx.restrictWorkspace)
  if ctx.restrictWorkspace then
    job.accessReason =
      "Shell access approval required. This command can access files outside the workspace. ALLOW approves this command once; SKIP declines."
  end
  return job
end

-- Fixed remote helper: every descendant directory is opened relative to its
-- parent descriptor with O_NOFOLLOW. Source is data, never Python/shell code.
-- No fallback to an unconfined write when Python or dir_fd support is absent.
local confinedWriter = [[
import os,sys,stat
root,path,tmp,mode,data,overwrite=sys.argv[1:]
fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY)
parts=path.split('/')
assert all(p not in ('','.','..') for p in parts)
for part in parts[:-1]:
 if mode=='start':
  try: os.mkdir(part,0o700,dir_fd=fd)
  except FileExistsError: pass
 child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
 os.close(fd)
 fd=child
if mode=='start':
 f=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
 os.close(f)
elif mode=='chunk':
 f=os.open(tmp,os.O_WRONLY|os.O_APPEND|os.O_NOFOLLOW,dir_fd=fd)
 info=os.fstat(f)
 assert stat.S_ISREG(info.st_mode) and info.st_nlink==1
 with os.fdopen(f,'ab') as out: out.write(bytes.fromhex(data))
elif mode=='publish':
 if overwrite=='1': os.replace(tmp,parts[-1],src_dir_fd=fd,dst_dir_fd=fd)
 else:
  os.link(tmp,parts[-1],src_dir_fd=fd,dst_dir_fd=fd,follow_symlinks=False)
  os.unlink(tmp,dir_fd=fd)
os.close(fd)
]]

-- File contents travel as bounded ASCII shell lines, preserving UTF-8 bytes,
-- quotes, tabs and newlines without invoking the terminal's line editor on
-- source text. Publish only after every chunk succeeds.
local FileJob = {}
FileJob.__index = FileJob
T.MAX_FILE_BYTES = 64 * 1024
T.FILE_CHUNK = 160

function T.fileJob(path, content, overwrite, ctx)
  if type(path) ~= "string" or path == "" or path:find("[%z\1-\31\127]") or #path > 512 then
    return immediate("error: provide a valid file path")
  end
  if type(content) ~= "string" or content:find("%z") or #content > T.MAX_FILE_BYTES then
    return immediate("error: content must be text, at most 64 KiB, without NUL bytes")
  end
  if path:sub(1, 1) ~= "/" then
    local cwd = ctx.cwd and ctx.cwd() or ""
    if cwd == "" then
      return immediate("error: working directory unknown; use an absolute path from pwd")
    end
    path = cwd:gsub("/$", "") .. "/" .. path
  end
  path = T.normalizePath(path)
  local root = T.normalizePath(ctx.workspace)
  if ctx.restrictWorkspace and not root then
    return immediate(
      "error: workspace folder is unknown; establish the current folder before writing"
    )
  end
  local confined = ctx.restrictWorkspace and T.insideWorkspace(root, path)
  local outside = ctx.restrictWorkspace and not confined
  nextJob = nextJob + 1
  local temp = path .. ".cbo-write-" .. tostring(ctx.core.nowMs()) .. "-" .. nextJob
  local q, commands = T.shellQuote, {}
  local parent = path:match("^(.*)/[^/]+$")
  if not parent then
    return immediate("error: path must name a file")
  end
  local setup = "mkdir -p " .. q(parent) .. " && (umask 077; set -C; : > " .. q(temp) .. ")"
  commands[1] = "sh -c " .. q(setup)
  for pos = 1, #content, T.FILE_CHUNK do
    local octal = content:sub(pos, pos + T.FILE_CHUNK - 1):gsub(".", function(ch)
      return string.format("\\0%03o", ch:byte())
    end)
    commands[#commands + 1] = "printf '%b' " .. q(octal) .. " >> " .. q(temp)
  end
  local publish = overwrite and ("mv -f " .. q(temp) .. " " .. q(path))
    or ("ln " .. q(temp) .. " " .. q(path) .. " && rm -f " .. q(temp))
  commands[#commands + 1] = "test ! -d " .. q(path) .. " && " .. publish
  if confined then
    local relative = path:sub(root == "/" and 2 or #root + 2)
    if relative == "" then
      return immediate("error: path must name a file inside the workspace")
    end
    local function step(mode, data)
      return "python3 -I -c "
        .. q("exec(" .. json.encode(confinedWriter) .. ")")
        .. " "
        .. q(root)
        .. " "
        .. q(relative)
        .. " "
        .. q(temp:match("[^/]+$"))
        .. " "
        .. q(mode)
        .. " "
        .. q(data or "")
        .. " "
        .. q(overwrite and "1" or "0")
    end
    commands = { step("start") }
    for pos = 1, #content, T.FILE_CHUNK do
      local hex = content:sub(pos, pos + T.FILE_CHUNK - 1):gsub(".", function(ch)
        return string.format("%02x", ch:byte())
      end)
      commands[#commands + 1] = step("chunk", hex)
    end
    commands[#commands + 1] = step("publish")
  end
  local job = setmetatable({
    kind = "write_file",
    path = path,
    preview = content,
    command = "Write " .. path,
    commands = commands,
    ctx = ctx,
    index = 0,
    t = 0,
    needsApproval = outside or not ctx.autoRun,
    accessReason = outside
        and ("Outside workspace: " .. root .. "\nRequested file: " .. path .. "\nALLOW approves only this file operation; the workspace stays unchanged.")
      or nil,
    done = false,
    started = false,
    bytes = #content,
    temp = temp,
  }, FileJob)
  if ctx.autoRun and not outside then
    job:approve()
  end
  return job
end

function FileJob:next()
  self.index = self.index + 1
  if self.index > #self.commands then
    self.done, self.success = true, true
    self.result = "Wrote "
      .. self.path
      .. " ("
      .. self.bytes
      .. " bytes). Compile and run it to verify."
  else
    self.child = T.commandJob(self.commands[self.index], self.ctx, true)
  end
end

function FileJob:approve()
  if self.started or self.done then
    return
  end
  self.started, self.needsApproval = true, false
  self:next()
end

function FileJob:deny()
  self.done, self.result = true, "The user declined to write " .. self.path
end

function FileJob:cancel()
  if self.child then
    self.child:cancel()
  end
  self.done, self.result =
    true, "File write cancelled. A temporary file may remain at " .. self.temp
end

function FileJob:update(dt)
  if self.done or not self.started then
    return
  end
  self.t = self.t + dt
  self.child:update(dt)
  self.waiting = self.child.waiting
  if self.child.done then
    if self.child.success then
      self:next()
    else
      self.done, self.success = true, false
      self.result = "File write failed; destination was not published. "
        .. (self.child.result or "")
        .. "\nTemporary file: "
        .. self.temp
    end
  end
end

-- ---- built-in tools --------------------------------------------------------

T.builtin = {
  {
    name = "read_screen",
    description = "The text on the user's terminal screen right now (last `lines` rows, default all).",
    params = { "lines" },
    paramDocs = { lines = "how many rows from the bottom (number), optional" },
    optional = { lines = true },
    run = function(ctx, args)
      local text = ctx.screenText and ctx.screenText() or ""
      local n = tonumber(args.lines)
      return immediate(lastLines(text, n and math.floor(n) or nil))
    end,
  },
  {
    name = "run_command",
    description = "Type a shell command into the user's terminal and return the screen after it ran. The user approves it first unless auto-run is on. One command, no interactive programs.",
    params = { "command", "summary" },
    paramDocs = {
      command = "the exact command line",
      summary = "Short progress label explaining this step, e.g. Checking Go setup or Building and running the program",
    },
    optional = { summary = true },
    run = function(ctx, args)
      local cmd = tostring(args.command or ""):gsub("[\r\n]+$", "")
      if cmd:match("^%s*$") then
        return immediate("error: command is empty")
      end
      if cmd:find("[%z\1-\8\11-\31\127]") then
        return immediate("error: command contains control characters")
      end
      local job = T.shellJob(cmd, ctx)
      job.summary = type(args.summary) == "string" and args.summary or nil
      return job
    end,
  },
  {
    name = "write_file",
    description = "Write source code or text to a file through the connected terminal. Creates parent folders and publishes atomically. Existing files are preserved unless overwrite=true. Use this for code, then compile/run with run_command.",
    params = { "path", "content", "overwrite" },
    paramDocs = {
      path = "Absolute path, or relative to the shell folder",
      content = "Exact source text including newlines",
      overwrite = "Replace an existing file only when the user requested editing it; default false",
    },
    paramTypes = { overwrite = "boolean" },
    optional = { overwrite = true },
    run = function(ctx, args)
      return T.fileJob(args.path, args.content, args.overwrite == true, ctx)
    end,
  },
  {
    name = "search_notes",
    description = "Search the user's saved notes (hybrid text + vector search). Returns the best matches.",
    params = { "query" },
    run = function(ctx, args)
      local hits = ctx.core.noteSearch(tostring(args.query or ""), 5, true)
      if #hits == 0 then
        return immediate("no matching notes")
      end
      local out = {}
      for _, h in ipairs(hits) do
        out[#out + 1] = string.format("[note %s] %s", tostring(h.id), h.snippet or h.title or "")
      end
      return immediate(table.concat(out, "\n\n"))
    end,
  },
  {
    name = "save_note",
    description = "Save a note for the user (kept locally, searchable later).",
    params = { "text" },
    run = function(ctx, args)
      local note, err = ctx.core.noteAdd(tostring(args.text or ""), ctx.sessionId or 0)
      if not note then
        return immediate("error: " .. tostring(err))
      end
      if ctx.onNote then
        ctx.onNote(note)
      end
      return immediate("saved note " .. tostring(note.id))
    end,
  },
  {
    name = "define_tool",
    description = 'Create a reusable tool (function) from a shell command template with {param} placeholders, e.g. command "df -h {path}" with params "path". It is saved and available from the next message on.',
    params = { "name", "description", "command", "params" },
    paramDocs = {
      name = "identifier, letters/digits/underscore",
      description = "what it does, one line",
      command = "shell command template; {param} placeholders are quoted when expanded",
      params = "comma-separated placeholder names, may be empty",
    },
    optional = { params = true },
    run = function(ctx, args)
      local tool, err = T.add({
        name = args.name,
        description = args.description,
        command = args.command,
        params = args.params,
      }, ctx.core)
      if not tool then
        return immediate("error: " .. tostring(err))
      end
      if ctx.onTools then
        ctx.onTools()
      end
      return immediate(string.format("defined tool %s: %s", tool.name, tool.command))
    end,
  },
  {
    name = "remove_tool",
    description = "Delete a user-defined tool by name.",
    params = { "name" },
    run = function(ctx, args)
      if not T.remove(tostring(args.name or ""), ctx.core) then
        return immediate("error: no user tool named " .. tostring(args.name))
      end
      if ctx.onTools then
        ctx.onTools()
      end
      return immediate("removed tool " .. tostring(args.name))
    end,
  },
  {
    name = "list_tools",
    description = "List every tool available right now.",
    params = {},
    run = function()
      local out = {}
      for _, t in ipairs(T.all()) do
        out[#out + 1] = string.format(
          "%s%s: %s%s",
          t.name,
          t.enabled == false and " (disabled)" or "",
          t.description or "",
          t.command and ("  [" .. t.command .. "]") or ""
        )
      end
      return immediate(table.concat(out, "\n"))
    end,
  },
}

-- The required list of a built-in: its params minus the optional ones.
for _, t in ipairs(T.builtin) do
  local props, required = json.object({}), {}
  for _, p in ipairs(t.params) do
    props[p] =
      { type = (t.paramTypes or {})[p] or "string", description = (t.paramDocs or {})[p] or p }
    if not (t.optional or {})[p] then
      required[#required + 1] = p
    end
  end
  t.parameters = { type = "object", properties = props }
  if #required > 0 then
    t.parameters.required = required
  end
  t.builtin = true
end

-- ---- registry --------------------------------------------------------------

local function sanitizeUser(row)
  if type(row) ~= "table" or not T.validName(row.name) then
    return nil
  end
  local command = tostring(row.command or "")
  if command:match("^%s*$") or command:find("[%z\1-\8\11-\31\127]") then
    return nil
  end
  return {
    name = row.name,
    description = tostring(row.description or ""):gsub("[%z\1-\31\127]", " "):sub(1, 300),
    command = command,
    params = T.paramsOf(row.params),
    enabled = row.enabled ~= false,
    ts_ms = tonumber(row.ts_ms) or 0,
  }
end

function T.load(core)
  T.user = {}
  local rows = core and core.jsonlLoad(T.STORE) or nil
  for _, row in ipairs(rows or {}) do
    local t = sanitizeUser(row)
    if t and not T.find(t.name) then
      T.user[#T.user + 1] = t
    end
  end
  T.loaded = true
  return T.user
end

function T.save(core)
  local rows = {}
  for _, t in ipairs(T.user) do
    rows[#rows + 1] = {
      name = t.name,
      description = t.description,
      command = t.command,
      params = t.params,
      enabled = t.enabled ~= false,
      ts_ms = t.ts_ms or 0,
    }
  end
  return core and core.jsonlSave(T.STORE, rows) or false
end

function T.find(name)
  for _, t in ipairs(T.builtin) do
    if t.name == name then
      return t
    end
  end
  for _, t in ipairs(T.user) do
    if t.name == name then
      return t
    end
  end
  return nil
end

-- Add (or replace) a user tool; returns the tool or nil, err.
function T.add(spec, core)
  local t = sanitizeUser(spec)
  if not t then
    return nil, "a tool needs a name (letters, digits, _) and a command"
  end
  for _, b in ipairs(T.builtin) do
    if b.name == t.name then
      return nil, t.name .. " is a built-in tool"
    end
  end
  t.ts_ms = core and core.nowMs() or 0
  local replaced = false
  for i, u in ipairs(T.user) do
    if u.name == t.name then
      T.user[i], replaced = t, true
    end
  end
  if not replaced then
    if #T.user >= T.MAX_USER_TOOLS then
      return nil, "too many tools (" .. T.MAX_USER_TOOLS .. ")"
    end
    T.user[#T.user + 1] = t
  end
  T.save(core)
  return t
end

function T.remove(name, core)
  for i, u in ipairs(T.user) do
    if u.name == name then
      table.remove(T.user, i)
      T.save(core)
      return true
    end
  end
  return false
end

function T.setEnabled(name, on, core)
  local t = T.find(name)
  if not t then
    return false
  end
  t.enabled = on and true or false
  if not t.builtin then
    T.save(core)
  end
  return true
end

-- Every tool, built-ins first.
function T.all()
  local out = {}
  for _, t in ipairs(T.builtin) do
    out[#out + 1] = t
  end
  for _, t in ipairs(T.user) do
    out[#out + 1] = t
  end
  return out
end

-- The neutral list sent with a request (enabled tools only).
function T.forLlm()
  local out = {}
  for _, t in ipairs(T.all()) do
    if t.enabled ~= false then
      out[#out + 1] = { name = t.name, description = t.description or "", parameters = T.schema(t) }
    end
  end
  return out
end

-- Run one call. Returns a job: {done, result, needsApproval?, command?, update, approve, deny}.
function T.run(name, args, ctx)
  args = type(args) == "table" and args or {}
  local t = T.find(name)
  if not t or t.enabled == false then
    return immediate("error: unknown tool " .. tostring(name))
  end
  if t.run then
    local ok, job = pcall(t.run, ctx, args)
    if not ok then
      return immediate("error: " .. tostring(job))
    end
    return job
  end
  local command = T.expand(t.command, args)
  if command:find("[%z\1-\8\11-\31\127]") then
    return immediate("error: command contains control characters")
  end
  return T.shellJob(command, ctx)
end

-- One line describing the tool for the system prompt and the AGI list.
function T.describe(t)
  local params = {}
  for _, p in ipairs(T.paramsOf(t.params)) do
    params[#params + 1] = p
  end
  return string.format("%s(%s)", t.name, table.concat(params, ", "))
end

return T
