local invUtils = require("invUtils")

local side = ...
if not side then
    error("Usage: addSlotCover <side>")
end

local function getNcId(item)
    local id = item.name
    if item.nbt then
        id = id.."|"..item.nbt
    end
    return id
end

local inputInv
inputInv = invUtils.wrapInvSafe(side)
if not inputInv then
    error("Input inventory not found")
end

local slotCoverItem = inputInv.list()[1]
if not slotCoverItem then
    error("Slot cover item not found (first slot in inventory)")
end
local slotCover = getNcId(slotCoverItem)

local slotCoversFile, err = fs.open(shell.resolve("slotCovers.txt"), "a")
if not slotCoversFile then
    error("Unable to open slotCovers.txt: " .. err)
end
slotCoversFile.writeLine(slotCover)
slotCoversFile.flush()
slotCoversFile.close()