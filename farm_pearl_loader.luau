-- Farm Pearl loader: also supplies source for the farm's teleport continuation.
local url = "https://raw.githubusercontent.com/jejow/main-luau/refs/heads/main/farm_pearl.luau"
local ok, source = pcall(function() return game:HttpGet(url) end)
assert(ok and type(source) == "string" and #source > 0,
    "Farm Pearl: failed to download script: " .. tostring(source))
local run, compileError = loadstring(source, "@FarmPearl")
assert(run, "Farm Pearl: failed to compile script: " .. tostring(compileError))

local environment = getgenv()
environment.SeaPearlSource = source
if type(environment.__sf) == "table" then
    environment.__sf.autoExecuteSource = source
end
run()
