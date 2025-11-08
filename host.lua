local strings = require("cc.strings")
local invUtils = require("invUtils")

local CRAFTNET_SEND = 3481
local CRAFTNET_RECIEVE = 3482
local POLL_DELAY = 0.25
local IDLE_POLL_DELAY = 5
local SLEEP_IDLE_CYCLE = 8
local PROCESSOR_IDLE_CYCLE_LIMIT = 4
---@enum processorState
local PROCESSOR_STATE = {
    empty = 0,
    loadnc = 1,
    idle = 2,
    active = 3,
    available = 4, -- ready to process, not ready to unload
    unloadnc = 5,
    ncpending = 6, -- pending to have nc removed
    invalid = 7 -- sent error
}

local recipeTypes
local recipeTypeCount
local craftNet
local idleCycles
local recieveQueue = {}

---@class Processor
---@field state processorState
---@field idleCycles integer
---@field recipeType string

---@type table<string, Processor>
local processors = {}

---@type table<string, string>
local invIdCache = {} -- peripheral id -> craftnet id
---@type table<string, GenericInventory>
local invPeripheralCache = {} -- craftnet id -> peripheral
---@type table<string, boolean>
local invalidInputs = {} -- set



local function getRecipeTypes()
    local recipeTypes
    local recipeTypesFile = fs.open(shell.resolve("recipeTypes.txt"), "r")
    if recipeTypesFile then
        local read = recipeTypesFile.readAll()
        if read then
            recipeTypes = textutils.unserialise(read)
        end
        recipeTypesFile.close()
    end
    ---@cast recipeTypes table<string, RecipeType>?
    if not recipeTypes then
        printError("unable to read recipeTypes")
        recipeTypes = {}
    end
    return recipeTypes
end

local function getCraftNet()
    local craftNet
    for i, dir in ipairs({"left", "right", "back", "bottom", "top"}) do
        if peripheral.hasType(dir, "modem") then
            craftNet = peripheral.wrap(dir)
            break
        end
    end
    ---@cast craftNet ccTweaked.peripheral.WiredModem?
    if not craftNet then error("CraftNet connection not found") end
    return craftNet
end

local function readMessages(timeout)
    local timer = os.startTimer(timeout)
    while true do
        local e = {os.pullEvent()}
        if e[1] == "timer" and e[2] == timer then
            return
        elseif e[1] == "modem_message" and e[2] == peripheral.getName(craftNet) and e[3] == CRAFTNET_RECIEVE then
            table.insert(recieveQueue, e[5])
        end
    end
end

local function handleMessages()
    for i, recieved in ipairs(recieveQueue) do
        local msg = strings.split(recieved, "%s+")
        if msg[1] == "cn" then
            if msg[2] == "ready" or msg[2] == "unloadnc" then
                if msg[2] == "ready" then
                    print("Recipe processor connected: "..msg[3])
                end
                processors[msg[3]] = {state = PROCESSOR_STATE.ncpending, idleCycles = 0, recipeType = ""}
            elseif msg[2] == "loadnc" or msg[2] == "load" then
                processors[msg[3]].state = PROCESSOR_STATE.idle
                processors[msg[3]].idleCycles = 0
            elseif msg[2] == "available" then
                processors[msg[3]].state = PROCESSOR_STATE.available
                processors[msg[3]].idleCycles = 0
            elseif msg[2] == "error" then
                processors[msg[3]].state = PROCESSOR_STATE.invalid
                printError("Recieved error from processor "..msg[3])
            end
        end
    end
    recieveQueue = {}
end

local function getOrCacheInventoryId(peripheralName)
    local cachedId = invIdCache[peripheralName]
    if not cachedId then
        local inv = invUtils.wrapInvSafe(peripheralName)
        local idItem = nil
        if inv and inv.size() >= 1 then
            idItem = inv.getItemDetail(1)
        end
        if idItem then
            cachedId = idItem.displayName--[[@as string]]
            if invPeripheralCache[cachedId] then
                printError("Warning: duplicate inventory id found: "..cachedId)
            end
        else
            cachedId = ""
        end
        invIdCache[peripheralName] = cachedId
        invPeripheralCache[cachedId] = inv
    end
    return cachedId
end

local function getRecipeTypeId(id) -- removes + (use like asm+ for more patprovs)
    return string.gsub(id, "+", "")
end

local function scanInventories()
    local scannedInputs = {}
    local scannedNc = nil
    local scannedPendingNc = {}
    for i, peripheralName in ipairs(craftNet.getNamesRemote()) do
        if peripheral.hasType(peripheralName, "inventory") then
            local invId = getOrCacheInventoryId(peripheralName)
            if invId and invId ~= "" then
                local inv = invPeripheralCache[invId]
                if invId == "nc" and not scannedNc then
                    scannedNc = {}
                    invUtils.enqueue(function () scannedNc = inv.list() end)
                elseif recipeTypes[getRecipeTypeId(invId)] and not invalidInputs[invId] then
                    local scanned = {{}, {}}
                    scannedInputs[invId] = scanned
                    invUtils.enqueueScanInv(inv, scanned)
                elseif processors[invId] and processors[invId].state == PROCESSOR_STATE.ncpending then
                    scannedPendingNc[invId] = {}
                    invUtils.enqueue(function () scannedPendingNc[invId] = inv.list() end)
                end
            end
        end
    end
    if not scannedNc then
        error("Nonconsumable input not found or disconnected")
    end
    invUtils.flush()
    scannedNc[1] = nil
    for inputId, input in pairs(scannedInputs) do
        input[1][1] = nil
        if next(input[1]) == nil and next(input[2]) == nil then
            scannedInputs[inputId] = nil
        end
    end
    for processorId, processorScan in pairs(scannedPendingNc) do
        processorScan[1] = nil
    end
    return scannedInputs, scannedNc, scannedPendingNc
end

local function getNcId(item)
    local id = item.name
    if item.nbt then
        id = id.."|"..item.nbt
    end
    return id
end

local function getNcSlots(ncScan)
    ---@type table<string, integer>
    local ncSlots = {}
    for slot, item in pairs(ncScan) do
        ncSlots[getNcId(item)] = slot
    end
    return ncSlots
end

local function checkProcessorInvs()
    for processorId, processor in pairs(processors) do
        if processor.state ~= PROCESSOR_STATE.invalid then
            local inv = invPeripheralCache[processorId]
            if inv == nil or not craftNet.isPresentRemote(peripheral.getName(inv)) then
                processor.state = PROCESSOR_STATE.invalid
                printError("Inventory for processor "..processorId.." not found or disconnected")
            end
        end
    end
end

local function scanProcessors()
    ---@type table<string, string>
    local recipeTypeProcessors = {}
    ---@type table<string, boolean>
    local loadedRecipeTypes = {}
    for processorId, processor in pairs(processors) do
        if processor.state == PROCESSOR_STATE.idle or processor.state == PROCESSOR_STATE.available then
            recipeTypeProcessors[processor.recipeType] = processorId
            loadedRecipeTypes[processor.recipeType] = true
        elseif processor.state == PROCESSOR_STATE.loadnc then
            loadedRecipeTypes[processor.recipeType] = true
        end
    end
    return recipeTypeProcessors, loadedRecipeTypes
end

local function requestNc(scannedNc, ncSlotCache, recipeId)
    local recipeItems = recipeTypes[recipeId].items
    local allFound = true
    for i, recipeItem in ipairs(recipeItems) do
        if not ncSlotCache[recipeItem] then
            allFound = false
        end
    end
    if not allFound then return nil end
    local nc = {}
    for i, recipeItem in ipairs(recipeItems) do
        local slot = ncSlotCache[recipeItem]
        scannedNc[slot].count = scannedNc[slot].count - 1
        nc[slot] = {name = scannedNc[slot].name, count = 1}
        if scannedNc[slot].count <= 0 then
            ncSlotCache[recipeItem] = nil
        end
    end
    return nc
end

local function loop()
    local validProcessorCycle = false
    local scannedInputs, scannedNc, scannedPendingNc = scanInventories() -- ensure cache, also assume the scanned inventories exist
    local ncSlotCache = getNcSlots(scannedNc)
    checkProcessorInvs() -- ensure processor inventories for non-invalid processors
    local recipeTypeProcessors, loadedRecipeTypes = scanProcessors() -- caches
    idleCycles = idleCycles + 1
    if next(scannedInputs) ~= nil then
        idleCycles = 0
    end

    local messageQueue = {}
    local processorErrors = {}
    local ncErrors = {}

    -- 1. all inputs to available processors
    for inputId, input in pairs(scannedInputs) do
        local recipeTypeId = getRecipeTypeId(inputId)
        if recipeTypeProcessors[recipeTypeId] then
            local processorId = recipeTypeProcessors[recipeTypeId]
            invUtils.enqueueMoveSlots(invPeripheralCache[inputId], input, invPeripheralCache[processorId], invalidInputs, processorErrors)
            table.insert(messageQueue, "cn load "..processorId)
            processors[processorId].state = PROCESSOR_STATE.active
            recipeTypeProcessors[recipeTypeId] = nil
            scannedInputs[inputId] = nil
        end
    end

    -- 2. request recipe types
    for inputId, input in pairs(scannedInputs) do
        local recipeTypeId = getRecipeTypeId(inputId)
        if not loadedRecipeTypes[recipeTypeId] then
            validProcessorCycle = true
            for processorId, processor in pairs(processors) do
                if processor.state == PROCESSOR_STATE.empty and processorId:find("^"..recipeTypes[recipeTypeId].processor) ~= nil then
                    local nc = requestNc(scannedNc, ncSlotCache, recipeTypeId)
                    if nc then
                        print("loading "..recipeTypeId.." to "..processorId.."...")
                        invUtils.enqueueMoveSlots(invPeripheralCache["nc"], {nc, {}}, invPeripheralCache[processorId], ncErrors, processorErrors)
                        table.insert(messageQueue, "cn loadnc "..processorId)
                        processors[processorId].state = PROCESSOR_STATE.loadnc
                        processors[processorId].recipeType = recipeTypeId
                        loadedRecipeTypes[recipeTypeId] = true
                        break
                    end
                end
            end
        end
    end

    -- 3. unload idle processors
    if validProcessorCycle then
        for processorId, processor in pairs(processors) do
            if processor.state == PROCESSOR_STATE.idle then
                processor.idleCycles = processor.idleCycles + 1
                if processor.idleCycles > PROCESSOR_IDLE_CYCLE_LIMIT then
                    table.insert(messageQueue, "cn unloadnc "..processorId)
                    processors[processorId].state = PROCESSOR_STATE.unloadnc
                end
            end
        end
    end

    -- 4. collect all nc
    for processorId, scanned in pairs(scannedPendingNc) do
        invUtils.enqueueMoveSlots(invPeripheralCache[processorId], {scanned, {}}, invPeripheralCache["nc"], processorErrors, ncErrors)
        processors[processorId].state = PROCESSOR_STATE.empty
    end

    invUtils.flush()
    for i, message in ipairs(messageQueue) do
        craftNet.transmit(CRAFTNET_SEND, CRAFTNET_RECIEVE, message)
    end

    for i, processorId in ipairs(processorErrors) do
        printError("Error while moving items to processor: "..processorId)
        processors[processorId].state = PROCESSOR_STATE.invalid
    end
    if ncErrors["nc"] ~= nil then
        error("Failed to move items to/from nonconsumable storage, it may be full")
    end
end

local function run()
    craftNet.open(CRAFTNET_RECIEVE)
    craftNet.transmit(CRAFTNET_SEND, CRAFTNET_RECIEVE, "cn ready")
    readMessages(2)
    handleMessages()

    idleCycles = 0
    while true do
        handleMessages()
        local wait
        if idleCycles > SLEEP_IDLE_CYCLE then
            wait = IDLE_POLL_DELAY
        else
            wait = POLL_DELAY
        end
        parallel.waitForAll(loop, function() readMessages(wait) end)
    end
end

sleep(2)
recipeTypes = getRecipeTypes()
recipeTypeCount = 0
for recipeName, recipeType in pairs(recipeTypes) do
    recipeTypeCount = recipeTypeCount + 1
end
print(recipeTypeCount.." recipeTypes loaded")
craftNet = getCraftNet()
print("CraftNet connection found: "..peripheral.getName(craftNet))

run()
