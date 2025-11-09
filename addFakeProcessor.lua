
local processorId, recipeType = ...
if not (processorId and recipeType) then
    error("Usage: addRecipeType <processorId> <recipeType>")
end

local fakeProcessorsFile = fs.open(shell.resolve("fakeProcessors.txt"), "a")
if not fakeProcessorsFile then
    error("unable to open fakeProcessors")
end
fakeProcessorsFile.writeLine(processorId.." "..recipeType)
fakeProcessorsFile.flush()
fakeProcessorsFile.close()
