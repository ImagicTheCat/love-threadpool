-- https://github.com/ImagicTheCat/love-threadpool
-- MIT license (see LICENSE or src/love-threadpool.lua)
--[[
MIT License

Copyright (c) 2022 ImagicTheCat

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local function pack(...) return {n = select("#", ...), ...} end

local function thread_main(...)
  local unpack = unpack or table.unpack
  local function pack(...) return {n = select("#", ...), ...} end
  -- inputs
  local cin, cout, interface_code = ...
  -- load interface
  local interface_loader, err = load(interface_code)
  assert(interface_loader, err)
  local interface = interface_loader()
  -- setup dispatch
  local function dispatch(id, op, ...)
    cout:push({id, true, pack(interface[op](...))})
  end
  local traceback
  local function error_handler(err) traceback = debug.traceback(err, 2) end
  -- task loop
  local msg = cin:demand()
  while msg and msg ~= "exit" do
    local ok = xpcall(dispatch, error_handler, unpack(msg, 1, msg.n))
    if not ok then cout:push({msg[1], false, traceback}) end
    -- next
    msg = cin:demand()
  end
end
local thread_code = love.data.newByteData(string.dump(thread_main))

local threadpool = {}
local threadpool_mt = {__index = threadpool}

-- Module

local M = {}

-- Thread pool

-- Create a thread pool.
-- thread_count: number of threads in the pool
-- interface_loader: a Lua function (uses string.dump) or a string of Lua
--   code/bytecode which returns a map of functions (called from worker threads)
function M.new(thread_count, interface_loader)
  local interface_code = type(interface_loader) == "string" and
    interface_loader or string.dump(interface_loader)
  -- instantiate
  local o = setmetatable({}, threadpool_mt)
  o.ids = 0
  o.tasks = {}
  -- build async interface (bind interface call functions)
  o.interface = setmetatable({}, {__index = function(t, k)
    -- build call handler
    local function handler(...)
      local co, main = coroutine.running()
      if not co or main then error("interface call from a non-coroutine thread") end
      o:call(k, co, ...)
      local ok, values_errtrace = coroutine.yield()
      if ok then return unpack(values_errtrace, 1, values_errtrace.n)
      else error(values_errtrace, 0) end -- propagate error
    end
    t[k] = handler; return handler
  end})
  -- create threads and channels
  o.threads = {}
  for i=1, thread_count do
    local thread = love.thread.newThread(thread_code)
    table.insert(o.threads, thread)
  end
  o.cin, o.cout = love.thread.newChannel(), love.thread.newChannel()
  -- start threads
  for _, thread in ipairs(o.threads) do
    thread:start(o.cin, o.cout, interface_code)
  end
  return o
end

-- Call an operation on the thread pool interface.
-- The callback can be a coroutine (will call coroutine.resume with the same parameters).
--
-- op: key to an operation of the interface
-- callback(ok, values_errtrace): called on operation return
--- values_errtrace: packed return values or the error traceback
-- ...: call arguments
function threadpool:call(op, callback, ...)
  assert(not self.closed, "thread pool is closed")
  -- gen id
  self.ids = self.ids+1
  if self.ids >= 2^53 then self.ids = 0 end
  local id = self.ids
  -- send
  self.cin:push(pack(id, op, ...))
  -- setup task: done afterwards to prevent clutter on an eventual push error
  self.tasks[id] = callback
end

-- Handle the inter-thread communications (result of operations).
function threadpool:tick()
  local msg = self.cout:pop()
  while msg do
    local id, ok, values_errtrace = msg[1], msg[2], msg[3]
    local callback = self.tasks[id]
    if type(callback) == "thread" then
      local ok, err = coroutine.resume(callback, ok, values_errtrace)
      if not ok then error(debug.traceback(callback, err), 0) end
    else callback(ok, values_errtrace) end
    -- next
    msg = self.cout:pop()
  end
end

-- Close the thread pool (send exit signal and wait/join all threads).
function threadpool:close()
  self.closed = true
  for _, thread in ipairs(self.threads) do self.cin:push("exit") end
  for _, thread in ipairs(self.threads) do thread:wait() end
end

return M
