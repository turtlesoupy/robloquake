--!strict
-- Reassembles a chunked asset folder (base64 StringValues named 0001..N,
-- produced by tools/build_assets.py) into one buffer. Decodes chunk-wise
-- with yields so the live-server script watchdog never triggers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local base64 = require(Shared.engine.common.base64)

local assetchunks = {}

function assetchunks.loadRaw(folder: Instance): buffer
	local chunks = {}
	for _, child in folder:GetChildren() do
		if child:IsA("StringValue") then
			table.insert(chunks, child)
		end
	end
	table.sort(chunks, function(a, b)
		return a.Name < b.Name
	end)
	local total = 0
	local lens = table.create(#chunks)
	for i, chunk in chunks do
		local n = base64.decodedLen((chunk :: StringValue).Value)
		lens[i] = n
		total += n
	end
	local data = buffer.create(total)
	local pos = 0
	for i, chunk in chunks do
		base64.decodeInto((chunk :: StringValue).Value, data, pos)
		pos += lens[i]
		if i % 16 == 0 then
			task.wait()
		end
	end
	return data
end

return assetchunks
