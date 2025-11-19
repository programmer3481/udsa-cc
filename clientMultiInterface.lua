local strings = require("cc.strings")
local invUtils = require("invUtils")

local CRAFTNET_SEND = 3481
local CRAFTNET_RECIEVE = 3482
local POLL_DELAY = 0.1

local storage, craftNet, formation, bus
local id
local ncSlotsCache = {}

local pollTimer = nil
local pollLock = false

local displaySide
local active = false

local function getPeripherals()
    local storage = nil
    if peripheral.hasType("top", "inventory") then
        storage = invUtils.wrapInvSafe("top")
    end
    if not storage then error("Input Storage not found") end

    local bus = nil
    if peripheral.hasType("back", "inventory") then
        bus = invUtils.wrapInvSafe("back")
    end
    if not bus then error("Input Storage not found") end

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

    return storage, craftNet, formation, bus
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
        local activityText = "{color white idle}"
        if active then
            activityText = "{color green active}"
        end
        storage.setBufferedText(displaySide, 1, activityText)
    end
end
---@diagnostic enable: undefined-field

local function loadnc()
    local items = storage.list()
    items[1] = nil

    local transferErrors = {}
    invUtils.enqueueMoveSlots(storage, {items, {}}, bus, {}, transferErrors)
    invUtils.flush()
    if transferErrors["back"] then
        error("Failed to insert nonconsumables into input bus")
    end
    ncSlotsCache = bus.list()
end

local function load()
    local toMove = {}
    invUtils.enqueueScanInv(storage, toMove)
    invUtils.flush()

    toMove[1][1] = nil
    local transferErrors = {}
    invUtils.enqueueMoveSlots(storage, {toMove[1], {}}, bus, transferErrors, {})
    invUtils.enqueueMoveSlots(storage, {{}, toMove[2]}, formation, transferErrors, {})
    invUtils.flush()
    active = true
    updateDisplay()
    if transferErrors[peripheral.getName(storage)] then
        return false
    end
    while true do
        local tanks = formation.tanks()
        if next(tanks) == nil then
            return true
        end
        sleep(POLL_DELAY)
    end
end

local function isEmpty()
    local busInv = bus.list()
    for slot, item in pairs(ncSlotsCache) do
        busInv[slot] = nil
    end
    return not redstone.getInput(peripheral.getName(craftNet)) and next(busInv) == nil
end

local function isActive()
    return redstone.getInput("bottom")
end

local function unloadnc()
    if next(ncSlotsCache) == nil then -- bus is empty (loaded recipeType had no nonconsumables)
        return
    end
    redstone.setOutput("top", true)
    local items = {}
    while true do
        sleep(POLL_DELAY)
        items = storage.list()
        items[1] = nil
        if next(items) ~= nil then
            break
        end
    end
    redstone.setOutput("top", false)

    local busSlot = nil
    for slot, item in pairs(items) do
        if item.name:find("input_bus$") ~= nil then
            busSlot = slot
        end
    end
    if not busSlot then
        error("Failed to collect input bus")
    end
    storage.pushItems(peripheral.getName(formation), busSlot, 1)
    while true do
        local e, side = os.pullEvent("peripheral")
        if side == "back" then break end
    end
    bus = invUtils.wrapInvSafe("back")
    if not bus then
        error("Input bus connection error")
    end
    ncSlotsCache = {}
end

local function ready()
    redstone.setOutput("top", false)
    redstone.setOutput("front", false)
    while isActive() do
        sleep(POLL_DELAY)
    end
    ncSlotsCache = bus.list()
    unloadnc()
    updateDisplay()
end

local function getPollLock()
    while true do
        if not pollLock then
            pollLock = true
            return
        end
        sleep(0)
    end
end

local function handleMessage(msg)
    if msg[1] == "cn" and msg[2] == "ready" then
        print("Resetting...")
        ready()
        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn ready "..id)
    elseif msg[1] == "cn" and msg[3] == id then
        if msg[2] == "loadnc" then
            loadnc()
            craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn loadnc "..id)
        elseif msg[2] == "load" then
            getPollLock()
            if pollTimer ~= nil then os.cancelTimer(pollTimer) pollTimer = nil end
            while true do
                local storageEmpty = load()
                local empty = isEmpty() and storageEmpty
                active = isActive() or not empty
                updateDisplay()

                if empty then
                    craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn available "..id)
                    if not active then
                        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn load "..id)
                    else -- empty but active
                        pollTimer = os.startTimer(POLL_DELAY)
                    end
                    break
                end

                sleep(POLL_DELAY)
            end
            pollLock = false
        elseif msg[2] == "unloadnc" then
            unloadnc()
            craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn unloadnc "..id)
        end
    end
end

local function pollMachineService()
    while true do
        local _, timer = os.pullEvent("timer")
        if timer == pollTimer and not pollLock then -- if poll locked then no need to poll
            pollLock = true
            pollTimer = nil
            active = isActive()
            updateDisplay()
            if not active then
                craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn load "..id)
            else
                pollTimer = os.startTimer(POLL_DELAY)
            end
            pollLock = false
        end
    end
end

local function run()
    ready()

    craftNet.open(CRAFTNET_SEND)
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
print("Connecting periphrals...")
storage, craftNet, formation, bus = getPeripherals()
displaySide = getDisplaySide()
if displaySide then
    print("Display found: "..displaySide)
end
print("Getting CraftNet processor ID...")
id = getId()
print("Processor ID: "..id)

parallel.waitForAll(run, pollMachineService)
