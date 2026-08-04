--!strict
--[[
	Registry
	--------
	Maps an aircraft id to its definition module.

	This exists because the id is the only thing that crosses the network. The
	client asks for "c172"; the server spawns from that id and stamps it on the
	model as the AircraftId attribute; the client reads the attribute back off
	the replicated model and needs to arrive at the same definition table. Both
	sides therefore need the same lookup, which is why it lives in
	ReplicatedStorage rather than in either half.

	Definitions are discovered by scanning the Definitions folder, so adding an
	aircraft is one file and no edit here. The id comes from the definition
	itself - a definition whose id disagrees with its filename is not an error,
	because the id is what everything else keys on.
]]

local Definitions = script.Parent:WaitForChild("Definitions")

local Registry = {}

-- What RequestSpawnAircraft assumes when the client does not name one.
Registry.DEFAULT_ID = "c172"

local byId: { [string]: any } = {}

for _, module in Definitions:GetChildren() do
	if module:IsA("ModuleScript") then
		local definition = require(module) :: any

		if type(definition) ~= "table" or type(definition.id) ~= "string" then
			warn(string.format("[Registry] '%s' is not an aircraft definition - no string id. Skipped.", module.Name))
			continue
		end

		if byId[definition.id] then
			-- Two definitions claiming one id means spawning is a coin flip, and
			-- the loser is whichever the child iteration reached first. Loud.
			error(string.format("[Registry] duplicate aircraft id '%s' (from '%s')", definition.id, module.Name))
		end

		byId[definition.id] = definition
	end
end

--[[
	Look up a definition. Returns nil rather than erroring, because the caller
	is usually validating a string that arrived over the network - an unknown id
	is a message to send back, not a crash.
]]
function Registry.get(id: string?): any?
	if type(id) ~= "string" then
		return nil
	end
	return byId[id]
end

-- Every known id, sorted, for error messages and for the hangar UI later.
function Registry.ids(): { string }
	local ids = {}
	for id in byId do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

return Registry
