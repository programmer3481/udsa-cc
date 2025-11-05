local invUtils = require("invUtils")

---@class RecipeType
---@field processor string
---@field items string[]

local side, processorType = ...
if not side and processorType then
    error("Usage: addRecipeType <side> <processorType>")
end

local inputInv
inputInv = invUtils.wrapInvSafe(side)
if not inputInv then
    error("Input inventory not found")
end

local function getNcId(item)
    local id = item.name
    if item.nbt then
        id = id.."|"..item.nbt
    end
    return id
end

local recipeType = {}
recipeType.items = {}
for slot, item in pairs(inputInv.list()) do
    table.insert(recipeType.items, getNcId(item))
end
recipeType.processor = processorType
write("Recipe type name: ")
local recipeTypeName = read()


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
    printError("unable to read recipeTypes, creating a new one")
    recipeTypes = {}
end


recipeTypes[recipeTypeName] = recipeType
local recipeTypesFile, err = fs.open(shell.resolve("recipeTypes.txt"), "w")
if not recipeTypesFile then
    error("Unable to open recipe types file: " .. err)
end
recipeTypesFile.write(textutils.serialise(recipeTypes))
recipeTypesFile.flush()
recipeTypesFile.close()

