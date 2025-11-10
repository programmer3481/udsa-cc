local strings = require("cc.strings")
local invUtils = require("invUtils")

local CRAFTNET_SEND = 3481
local CRAFTNET_RECIEVE = 3482
local POLL_DELAY = 0.1

local storage, craftNet, formation, bus
local id
local ncSlotsCache = {}

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
    local toMove = storage.list()

    toMove[1] = nil
    local transferErrors = {}
    invUtils.enqueueMoveSlots(storage, {toMove, {}}, bus, {}, transferErrors)
    invUtils.flush()
    if transferErrors["back"] then
        error("Failed to insert items into input bus")
    end
    while true do
        local tanks = storage.tanks()
        if next(tanks) == nil then
            sleep(0.25) -- give some time for interface -> input hatches?
            break
        end
        sleep(POLL_DELAY)
    end
    active = true
    updateDisplay()
end

local function isEmpty(busInv)
    return not redstone.getInput(peripheral.getName(craftNet)) and next(busInv) == nil
end

local function isActive(busInv)
    return redstone.getInput("bottom") or not isEmpty(busInv)
end

local function waitInactive()
    while active do
        sleep(POLL_DELAY)
        local busInv = bus.list()
        for slot, item in pairs(ncSlotsCache) do
            busInv[slot] = nil
        end
        active = isActive(busInv)
        updateDisplay()
    end
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
        load()
        waitInactive()
        unloadnc()
        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn ready "..id)
    elseif msg[1] == "cn" and msg[3] == id then
        if msg[2] == "loadnc" then
            loadnc()
            craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn loadnc "..id)
        elseif msg[2] == "load" then
            load()
            local availableSent = false
            while active do
                local doLoad = false
                parallel.waitForAll(function () doLoad = waitMessage(POLL_DELAY) end,
                function ()
                    local busInv = bus.list()
                    for slot, item in pairs(ncSlotsCache) do
                        busInv[slot] = nil
                    end

                    local empty = isEmpty(busInv)
                    if empty and not availableSent then
                        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn available "..id)
                        availableSent = true
                    end

                    active = isActive(busInv)
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
    ncSlotsCache = bus.list()
    load()
    waitInactive()
    unloadnc()

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

print("Connecting periphrals...")
storage, craftNet, formation, bus = getPeripherals()
displaySide = getDisplaySide()
if displaySide then
    print("Display found: "..displaySide)
end
print("Getting CraftNet processor ID...")
id = getId()
print("Processor ID: "..id)

run()
