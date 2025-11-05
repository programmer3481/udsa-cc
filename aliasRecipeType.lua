local invUtils = require("invUtils")

local original, aliasName = ...
if not (original and aliasName) then
    error("Usage: addRecipeType <original> <aliasName>")
end

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
    error("unable to read recipeTypes, creating a new one")
end


recipeTypes[aliasName] = recipeTypes[original]
local recipeTypesFile, err = fs.open(shell.resolve("recipeTypes.txt"), "w")
if not recipeTypesFile then
    error("Unable to open recipe types file: " .. err)
end
recipeTypesFile.write(textutils.serialise(recipeTypes))
recipeTypesFile.flush()
recipeTypesFile.close()

