-- Minimal test of the module.
local threadpool = require "love-threadpool"

local cpu_count = love.system.getProcessorCount()
print("processor count", cpu_count)

-- Create thread pool.
local pool = threadpool.new(cpu_count, function(n)
  assert(n == 42) -- arg check
  require "love.math"
  --
  local interface = {}
  -- Compute the n-th element of the sequence described by the seed.
  function interface.random(seed, n)
    local rng = love.math.newRandomGenerator(seed)
    for i=1,n-1 do rng:random() end
    return rng:random()
  end
  function interface.__exit() print("interface exit") end
  return interface
end, 42)

-- Feed workers.
local result
local finished_count = 0
-- double amount of virtual threads (queue work in advance, compensate tick latency)
local threads = 2*cpu_count
for i=1,threads do
  coroutine.wrap(function()
    local sum = 0
    for j=1,50 do sum = sum + pool.interface.random(j, 1e7) end
    print("vthread #"..i, sum)
    -- check
    if not result then result = sum
    else assert(sum == result, "compute error") end
    finished_count = finished_count+1
    if finished_count == threads then love.event.quit() end
  end)()
end

function love.threaderror(thread, err) error("thread: "..err, 0) end
function love.update(dt) pool:tick() end
function love.quit() pool:close() end
