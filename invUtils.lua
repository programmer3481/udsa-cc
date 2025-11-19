
---@class GenericInventory : ccTweaked.peripheral.Inventory, ccTweaked.peripheral.FluidStorage

---Wrap a peripheral as an inventory & fluid storage, allow push/pulling to any peripheral, deal with peripheral reconnect bugs
---@param name string|ccTweaked.peripheral.computerSide The name of the peripheral to wrap
---@return GenericInventory|nil wrappedPeripheral The table containing the peripheral's methods or `nil` if the peripheral does not exist
local function wrapInvSafe(name)
    local wrappedPeripheral = peripheral.wrap(name)
    if wrappedPeripheral == nil then return wrappedPeripheral end
    -- create dummy methods
    if not peripheral.hasType(wrappedPeripheral, "inventory") then
        wrappedPeripheral.size = function() return 0 end
        wrappedPeripheral.list = function() return {} end
        wrappedPeripheral.getItemDetail = function(slot) error("Slot out of range") end
        wrappedPeripheral.getItemLimit = function(slot) error("Slot out of range") end
        wrappedPeripheral.pushItems = function(toName, fromSlot, limit, toSlot) error("From slot out of range") end
        wrappedPeripheral.pullItems = function(fromName, fromSlot, limit, toSlot) error("From slot out of range") end
    end
    if not peripheral.hasType(wrappedPeripheral, "fluid_storage") then
        wrappedPeripheral.tanks = function () return {} end
        wrappedPeripheral.pushFluid = function (toName, limit, fluidName) return 0 end
        wrappedPeripheral.pullFluid = function (fromName, limit, fluidName) return 0 end
    end
    -- make it work for any target inventory, also return nil instead of error when target peripheral doesn't exist
    local old = wrappedPeripheral.pushItems
    wrappedPeripheral.pushItems = function(toName, fromSlot, limit, toSlot)
        if peripheral.hasType(toName, "meBridge") then
            local bridge = peripheral.wrap(toName)
            if not bridge then return nil end
---@diagnostic disable-next-line: undefined-field
            local success, result = pcall(bridge.importItemFromPeripheral, {fromSlot = fromSlot - 1, count = limit}, peripheral.getName(wrappedPeripheral))
            if success then return result
            elseif result--[[@as string]]:find("valid side$") ~= nil then return nil
            else return error(result, 0) end
        end
        if peripheral.hasType(toName, "inventory") == false then
            if toSlot then error("To slot out of range") else return 0 end
        end
        local success, result = pcall(old, toName, fromSlot, limit, toSlot)
        if success then return result
        elseif result--[[@as string]]:find("exist$") ~= nil then return nil
        else return error(result, 0) end
    end
    local old = wrappedPeripheral.pullItems
    wrappedPeripheral.pullItems = function(fromName, fromSlot, limit, toSlot)
        if peripheral.hasType(fromName, "inventory") == false then
            if toSlot then error("To slot out of range") else return 0 end
        end
        local success, result = pcall(old, fromName, fromSlot, limit, toSlot)
        if success then return result
        elseif result--[[@as string]]:find("exist$") ~= nil then return nil
        else return error(result, 0) end
    end
    local old = wrappedPeripheral.pushFluid
    wrappedPeripheral.pushFluid = function (toName, limit, fluidName)
        if peripheral.hasType(toName, "meBridge") then
            local bridge = peripheral.wrap(toName)
            if not bridge then return nil end
---@diagnostic disable-next-line: undefined-field
            local success, result = pcall(bridge.importFluidFromPeripheral, {name = fluidName, count = limit}, peripheral.getName(wrappedPeripheral))
            if success then return result
            elseif result--[[@as string]]:find("valid side$") ~= nil then return nil
            else return error(result, 0) end
        end
        if peripheral.hasType(toName, "fluid_storage") == false then return 0 end
        local success, result = pcall(old, toName, limit, fluidName)
        if success then return result
        elseif result--[[@as string]]:find("exist$") ~= nil then return nil
        else return error(result, 0) end
    end
    local old = wrappedPeripheral.pullFluid
    wrappedPeripheral.pullFluid = function (fromName, limit, fluidName)
        if peripheral.hasType(fromName, "meBridge") then
            local bridge = peripheral.wrap(fromName)
            if not bridge then return nil end
---@diagnostic disable-next-line: undefined-field
            local success, result = pcall(bridge.exportFluidToPeripheral, {name = fluidName, count = limit}, peripheral.getName(wrappedPeripheral))
            if success then return result
            elseif result--[[@as string]]:find("valid side$") ~= nil then return nil
            else return error(result, 0) end
        end
        if peripheral.hasType(fromName, "fluid_storage") == false then return 0 end
        local success, result = pcall(old, fromName, limit, fluidName)
        if success then return result
        elseif result--[[@as string]]:find("exist$") ~= nil then return nil
        else return error(result, 0) end
    end
    -- reconnect proof methods
    local function tryCallFunc(f, default)
        return function(...)
            for i = 1, 5 do
                local res = f(...)
                if res ~= nil then return res end
            end
            printError("Attempted to access a disconnected peripheral: "..peripheral.getName(wrappedPeripheral))
            return default
        end
    end
    wrappedPeripheral.size = tryCallFunc(wrappedPeripheral.size, 0)
    wrappedPeripheral.list = tryCallFunc(wrappedPeripheral.list, {})
    wrappedPeripheral.getItemLimit = tryCallFunc(wrappedPeripheral.getItemLimit, 0)
    wrappedPeripheral.pushItems = tryCallFunc(wrappedPeripheral.pushItems, 0)
    wrappedPeripheral.pullItems = tryCallFunc(wrappedPeripheral.pullItems, 0)

    wrappedPeripheral.tanks = tryCallFunc(wrappedPeripheral.tanks, {})
    wrappedPeripheral.pushFluid = tryCallFunc(wrappedPeripheral.pushFluid, 0)
    wrappedPeripheral.pullFluid = tryCallFunc(wrappedPeripheral.pullFluid, 0)

    -- getItemDetail needs special handling, as it may return nil not from a result of a disconnect
    local old = wrappedPeripheral.getItemDetail
    wrappedPeripheral.getItemDetail = function(slot)
        if wrappedPeripheral.list()[slot] == nil then return nil end -- yes, bit of extra nessary overhead, to check if slot is empty
        for i = 1, 5 do
            local res = old(slot)
            if res ~= nil then return res end
        end
        printError("Attempted to access a disconnected peripheral: "..peripheral.getName(wrappedPeripheral))
        return nil
    end
    ---@cast wrappedPeripheral GenericInventory
    return wrappedPeripheral
end

local queueLimit = 128

local queue = {}

local function flush()
    parallel.waitForAll(table.unpack(queue))
    queue = {}
end

---@param op function
local function enqueue(op)
    table.insert(queue, op)
    if #queue >= queueLimit then
        flush()
    end
end

---@param ops function[]
local function enqueueAll(ops)
    for i, f in ipairs(ops) do
        enqueue(f)
    end
end

---@param inv GenericInventory
---@param result [ccTweaked.peripheral.itemList, table|nil[]]
local function enqueueScanInv(inv, result)
    enqueue(function () result[1] = inv.list() end)
    enqueue(function () result[2] = inv.tanks() end)
end

---@param inv GenericInventory
---@param slots [ccTweaked.peripheral.itemList, table|nil[]]
---@param target GenericInventory
---@param failSources table
---@param failTargets table
local function enqueueMoveSlots(inv, slots, target, failSources, failTargets)
    local sourceName = peripheral.getName(inv)
    local targetName = peripheral.getName(target)
    for itemSlot, item in pairs(slots[1]) do
        enqueue(function ()
            local transferred = inv.pushItems(targetName, itemSlot, item.count)
            if transferred ~= item.count then
                failSources[sourceName] = true
                failTargets[targetName] = true
            end
        end)
    end
    for fluidSlot, fluid in pairs(slots[2]) do
        enqueue(function ()
            local transferred = inv.pushFluid(targetName, fluid.amount, fluid.name)
            if transferred ~= fluid.amount then
                failSources[sourceName] = true
                failTargets[targetName] = true
            end
        end)
    end
end

return {
    wrapInvSafe = wrapInvSafe,
    flush = flush,
    enqueue = enqueue,
    enqueueAll = enqueueAll,
    enqueueScanInv = enqueueScanInv,
    enqueueMoveSlots = enqueueMoveSlots,
}

