local pretty = require "cc.pretty"
local strings = require("cc.strings")
local invUtils = require("invUtils")

local CRAFTNET_SEND = 3481
local CRAFTNET_RECIEVE = 3482
local POLL_DELAY = 0.1

local machines, machineCount
local storage, craftNet, formation, output
local id
local currentMachine = "none"

local function getMachines()
    local machinesFile = fs.open(shell.resolve("machines.txt"), "r")
    if not machinesFile then
        error("Could not open machine list file")
    end
    local machines = {}
    local machineCount = 0
    while true do
        local machine = machinesFile.readLine()
        if not machine then break end
        machines[machine] = true
        machineCount = machineCount + 1
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

local function getId()
    local idItem = storage.getItemDetail(1)
    local id = nil
    if idItem then
        id = idItem.displayName--[[@as string]]
    else
        pretty.pretty_print(storage.list())
        print(storage.size())
        error("Could not get ID from input storage")
    end
    return id
end

local function updateCurrentMachine()
    --[[
---@diagnostic disable-next-line: undefined-field
    if storage.setBufferedText then
        local directions = {"north", "south", "east", "west", "up", "down"}
        for i, direction in ipairs(directions) do
---@diagnostic disable-next-line: undefined-field
            storage.setBufferedText(direction, 1, currentMachine)
        end
    end
    --]]
end

local function isMachine(name)
    local sep = string.find(name, "_")
    if not sep then return false end
    return machines[string.sub(name, sep+1)]
end

local function loadnc()
    if peripheral.hasType("back", "inventory") then
        error("Recieved command to load nonconsumables, but a machine is already loaded")
    end

    local items = storage.list()
    items[1] = nil
    local machineSlot = nil
    for slot, item in pairs(items) do
        if isMachine(item.name) and item.count == 1 then
            currentMachine = item.name
            updateCurrentMachine()
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
    local machine = invUtils.wrapInvSafe("back")
    if not machine then
        error("Machine connection error")
    end

    local transferErrors = {}
    invUtils.enqueueMoveSlots(storage, {items, {}}, machine, {}, transferErrors)
    invUtils.flush()
    if transferErrors["back"] then
        error("Failed to insert nonconsumables into machine")
    end
end

local function load()
    local machine = invUtils.wrapInvSafe("back")
    if not machine then
        error("Recieved command to load items to machine, no machine is present")
    end
    local ncInv = {}
    invUtils.enqueue(function () ncInv = machine.list() end)
    local toMove = {}
    invUtils.enqueueScanInv(storage, toMove)
    invUtils.flush()

    toMove[1][1] = nil
    local transferErrors = {}
    invUtils.enqueueMoveSlots(storage, toMove, machine, {}, transferErrors)
    invUtils.flush()
    if transferErrors["back"] then
        error("Failed to insert items/fluids into machine")
    end
    while true do
        sleep(POLL_DELAY)
---@diagnostic disable-next-line: undefined-field
        if machine.isActive() == false then
            local toMoveOut = {}
            invUtils.enqueueScanInv(machine, toMoveOut)
            invUtils.flush()
            for slot, item in pairs(ncInv) do
                toMoveOut[1][slot] = nil
            end
            local transferOutErrors = {}
            invUtils.enqueueMoveSlots(machine, toMoveOut, output, transferOutErrors, {})
            invUtils.flush()
            -- only case when machine is not active and everything successfully transfers is when work is done.
            -- (except for when the output interface cannot fit, can be handled in the same way so don't care)
            if not transferOutErrors["back"] then
                break
            end
        end
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
    currentMachine = "none"
    updateCurrentMachine()
    redstone.setOutput("top", false)
end

local function run()
    craftNet.open(CRAFTNET_SEND)

    if peripheral.hasType("back", "inventory") then
        load()
        unloadnc()
    end

    updateCurrentMachine()
    print("Setup complete, awaiting commands...")
    craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn ready "..id)
    while true do
        local e = {os.pullEvent("modem_message")}
        if e[2] == peripheral.getName(craftNet) and e[3] == CRAFTNET_SEND then
            local msg = strings.split(e[5], "%s+")
            if msg[1] == "cn" and msg[2] == "ready" then
                print("Resetting...")
                if peripheral.hasType("back", "inventory") then
                    print("Unloading previously loaded machine")
                    load()
                    unloadnc()
                end
                craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn ready "..id)
            elseif msg[1] == "cn" and msg[3] == id then
                if msg[2] == "loadnc" then
                    local result, err = pcall(loadnc)
                    if not result then
                        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn error "..id)
                        error(err, 0)
                    end
                    print("Machine loaded: "..currentMachine)
                    craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn loadnc "..id)
                elseif msg[2] == "load" then
                    local result, err = pcall(load)
                    if not result then
                        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn error "..id)
                        error(err, 0)
                    end
                    craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn load "..id)
                elseif msg[2] == "unloadnc" then
                    local result, err = pcall(unloadnc)
                    if not result then
                        craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn error "..id)
                        error(err, 0)
                    end
                    craftNet.transmit(CRAFTNET_RECIEVE, 0, "cn unloadnc "..id)
                end
            end
        end
    end
end

print("Loading machine definition list...")
machines, machineCount = getMachines()
print("Loaded "..machineCount.." machines.")
print("Connecting periphrals...")
storage, craftNet, formation, output = getPeripherals()
print("Getting CraftNet processor ID...")
id = getId()
print("Processor ID: "..id)

run()
