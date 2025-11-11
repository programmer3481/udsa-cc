local strings = require("cc.strings")
local invUtils = require("invUtils")

local CRAFTNET_SEND = 3481
local CRAFTNET_RECIEVE = 3482
local POLL_DELAY = 0.1

local machines, machineCount
local storage, craftNet, formation, output
local id
local currentMachine = nil
local currentMachineName = ""
local currentMachineType = ""
local ncSlotsCache = {}

local displaySide
local active = false

local function getMachines()
    local machinesFile = fs.open(shell.resolve("machines.txt"), "r")
    if not machinesFile then
        error("Could not open machine list file")
    end
    local machines = {}
    local machineCount = 0
    while true do
        local line = machinesFile.readLine()
        if not line then break end
        if line:find("^%s*$") == nil then
            local machineDef = strings.split(line, "%s+")
            machines[machineDef[1]] = {maxItemIn = tonumber(machineDef[2]), maxFluidIn = tonumber(machineDef[3])}
            machineCount = machineCount + 1
        end
    end
    return machines, machineCount
end

local function getPeripherals()
    local storage = nil
    if peripheral.hasType("top", "inventory") then
        storage = invUtils.wrapInvSafe("top")
    end
    if not storage then error("Input Storage not found") end

    local craftNet = nil
    local formation = nil
    if peripheral.hasType("left", "modem") and peripheral.hasType("right", "inventory") then
        craftNet = peripheral.wrap("left")
        formation = invUtils.wrapInvSafe("right")
    elseif peripheral.hasType("right", "modem") and peripheral.hasType("left", "inventory") then
        craftNet = peripheral.wrap("right")
        formation = invUtils.wrapInvSafe("left")
    end
    ---@cast craftNet ccTweaked.peripheral.WiredModem?
    if not (craftNet and formation) then error("CraftNet or formation plane interface not found") end

    local output = nil
    if peripheral.hasType("bottom", "inventory") then
        output = invUtils.wrapInvSafe("bottom")
    end
    if not output then error("Output interface not found") end

    return storage, craftNet, formation, output
end

---@diagnostic disable: undefined-field
local function getDisplaySide()
    if storage.setBufferedText then
        local directions = {"north", "south", "east", "west", "up", "down"}
        for i, direction in ipairs(directions) do
            local success = storage.setBufferedText(direction, 1, "{color white Initializing...}")
            if success then return direction end
        end
    end
    return nil
end
---@diagnostic enable: undefined-field

local function getId()
    local idItem = storage.getItemDetail(1)
    local id = nil
    if idItem then
        id = idItem.displayName--[[@as string]]
    else
        error("Could not get ID from input storage")
    end
    return id
end

---@diagnostic disable: undefined-field
local function updateDisplay()
    redstone.setOutput("front", active)
    if displaySide then
        if currentMachineName == "" then
            storage.setBufferedText(displaySide, 1, "{color white empty}")
            return
        end
        local activityText = "{color white idle}"
        if active then
            activityText = "{color green active}"
        end
        storage.setBufferedText(displaySide, 1, "{color white "..currentMachineType.."}\\n"..activityText)
    end
end
---@diagnostic enable: undefined-field

local function getMachineType(name)
    local sep = string.find(name, "_")
    if not sep then return "" end
    return string.sub(name, sep+1)
end

local function loadnc()
    if peripheral.hasType("back", "inventory") then
        error("Recieved command to load nonconsumables, but a machine is already loaded")
    end

    local items = storage.list()
    items[1] = nil
    local machineSlot = nil
    for slot, item in pairs(items) do
        local machineType = getMachineType(item.name)
        if machines[machineType] and item.count == 1 then
            currentMachineName = item.name
            currentMachineType = machineType
            updateDisplay()
            machineSlot = slot
            break
        end
    end
    if not machineSlot then
        error("Recieved command to load nonconsumables, no machine given")
    end
    items[machineSlot] = nil
    storage.pushItems(peripheral.getName(formation), machineSlot)

    while true do
        local e, side = os.pullEvent("peripheral")
        if side == "back" then break end
    end
    currentMachine = invUtils.wrapInvSafe("back")
    if not currentMachine then
        error("Machine connection error")
    end

    local transferErrors = {}
    invUtils.enqueueMoveSlots(storage, {items, {}}, currentMachine, {}, transferErrors)
    invUtils.flush()
    if transferErrors["back"] then
        error("Failed to insert nonconsumables into machine")
    end
    ncSlotsCache = currentMachine.list()
end

local function load()
    if not currentMachine then
        error("Recieved command to load items to machine, no machine is present")
    end
    local toMove = {}
    invUtils.enqueueScanInv(storage, toMove)
    invUtils.flush()

    toMove[1][1] = nil
    local transferErrors = {}
    invUtils.enqueueMoveSlots(storage, toMove, currentMachine, {}, transferErrors)
    invUtils.flush()
    if transferErrors["back"] then
        error("Failed to insert items/fluids into machine")
    end
    active = true
    updateDisplay()
end

local function isEmpty(machineInv)
    for itemSlot, item in pairs(machineInv[1]) do
        if itemSlot <= machines[currentMachineType].maxItemIn then
            return false
        end
    end
    for fluidSlot, fluid in pairs(machineInv[2]) do
        if fluidSlot <= machines[currentMachineType].maxFluidIn then
            return false
        end
    end
    return true
end

local function isActive(machineInv) -- also flushes output
    if not currentMachine then
        error("Machine connection error")
    end
    if currentMachine.isActive() == false then
        local transferOutErrors = {}
        invUtils.enqueueMoveSlots(currentMachine, machineInv, output, transferOutErrors, {})
        invUtils.flush()
        -- only case when machine is not active and everything successfully transfers is when work is completely done.
        -- (except for when the output interface cannot fit, can be handled in the same way so don't care)
        if not transferOutErrors["back"] then
            return currentMachine.isActive() -- failsafe
        end
    end
    return true
end

local function waitInactive()
    if not currentMachine then
        error("Machine connection error")
    end
    while active do
        sleep(POLL_DELAY)
---@diagnostic disable-next-line: undefined-field
        local machineInv = {}
        invUtils.enqueueScanInv(currentMachine, machineInv)
        invUtils.flush()
        for slot, item in pairs(ncSlotsCache) do
            machineInv[1][slot] = nil
        end
        active = isActive(machineInv)
        if currentMachineType ~= "" then
            active = active or not isEmpty(machineInv)
        end
        updateDisplay()
    end
end

local function unloadnc()
    redstone.setOutput("top", true)
    while true do
        sleep(POLL_DELAY)
        local items = storage.list()
        items[1] = nil
        if next(items) ~= nil then
            break
        end
    end
    redstone.setOutput("top", false)
    currentMachineName = ""
    currentMachineType = ""
    currentMachine = nil
    ncSlotsCache = {}
    updateDisplay()
end

local function waitMessage(timeout)
    local timer = os.startTimer(timeout)
    local doLoad = false
    while true do
        local e = {os.pullEvent()}
        if e[1] == "timer" and e[2] == timer then
            return doLoad
        elseif e[1] == "modem_message" and e[2] == peripheral.getName(craftNet) and e[3] == CRAFTNET_SEND then
            local msg = strings.split(e[5], "%s+")
            if msg[1] == "cn" and msg[2] == "load" and msg[3] == id then
                doLoad = true
            end
        end
    end
end

local function handleMessage(msg)
    if msg[1] == "cn" and msg[2] == "ready" then
        print("Resetting...")
        if peripheral.hasType("back", "inventory") then
            print("Unloading previously loaded machine")
            load()
            waitInactive()
            unloadnc()
        end
        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn ready "..id)
    elseif msg[1] == "cn" and msg[3] == id then
        if msg[2] == "loadnc" then
            loadnc()
            print("Machine loaded: "..currentMachineName)
            craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn loadnc "..id)
        elseif msg[2] == "load" then
            load()
            if not currentMachine then error("Machine connection error") end
            local availableSent = false
            while active do
                local doLoad = false
                parallel.waitForAll(function () doLoad = waitMessage(POLL_DELAY) end,
                function ()
                    local machineInv = {}
                    invUtils.enqueueScanInv(currentMachine, machineInv)
                    invUtils.flush()
                    for slot, item in pairs(ncSlotsCache) do
                        machineInv[1][slot] = nil
                    end

                    local empty = isEmpty(machineInv)
                    if empty and not availableSent then
                        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn available "..id)
                        availableSent = true
                    end

                    active = isActive(machineInv) or not empty
                    updateDisplay()
                end)

                if doLoad then
                    load()
                    availableSent = false
                end
            end
            craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn load "..id)
        elseif msg[2] == "unloadnc" then
            unloadnc()
            craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn unloadnc "..id)
        end
    end
end

local function run()
    craftNet.open(CRAFTNET_SEND)

    redstone.setOutput("top", false)
    redstone.setOutput("front", false)
    if peripheral.hasType("back", "inventory") then
        currentMachine = invUtils.wrapInvSafe("back")
        if not currentMachine then
            error("Machine connection error")
        end
        ncSlotsCache = currentMachine.list()
        load()
        waitInactive()
        unloadnc()
    end

    updateDisplay()
    print("Setup complete, awaiting commands...")
    craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn ready "..id)
    while true do
        local e = {os.pullEvent("modem_message")}
        if e[2] == peripheral.getName(craftNet) and e[3] == CRAFTNET_SEND then
            local msg = strings.split(e[5], "%s+")
            local result, err = pcall(function () handleMessage(msg) end)
            if not result then
                craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn error "..id)
                error(err, 0)
            end
        end
    end
end

sleep(1)
print("Loading machine definition list...")
machines, machineCount = getMachines()
print("Loaded "..machineCount.." machines.")
print("Connecting periphrals...")
storage, craftNet, formation, output = getPeripherals()
displaySide = getDisplaySide()
if displaySide then
    print("Display found: "..displaySide)
end
print("Getting CraftNet processor ID...")
id = getId()
print("Processor ID: "..id)

run()
