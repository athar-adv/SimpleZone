local RunService = game:GetService('RunService')

local main = script.Parent

type RegisterOptions = {
	QueryParams: OverlapParams,
	QueryOptions: Zone.QueryOptions,
}

local Zones = {
	ActiveZones = {},
	TotalZoneVolume = 0,
}

function Zones.registerZone(zone, options: RegisterOptions)
	Zones.ActiveZones[zone] = options
end

function Zones.deregisterZone(zone)
	Zones.ActiveZones[zone] = nil
end

RunService.PostSimulation:Connect(function(dt)
	for zone, params in Zones.ActiveZones do
		local queryOp = params.QueryOptions
		
		local now = os.clock()
		if now - zone._lastUpdate < queryOp.UpdateInterval then
			continue
		end
		zone._lastUpdate = now
		
		local onEnter = (queryOp.FireMode == "OnEnter" or queryOp.FireMode == "Both") and queryOp.FireMode ~= "None"
		local onExit = (queryOp.FireMode == "OnExit" or queryOp.FireMode == "Both") and queryOp.FireMode ~= "None"
		
		if queryOp.InSeperateQuerySpace then
			local worldModel: WorldModel = zone._worldModel
			local querySpace = zone._querySpace
			local dynamic = querySpace.dynamic
			
			local cframes = table.create(#dynamic.replicas)
			
			for index, part in dynamic.index do
				cframes[index] = part.CFrame
			end
			worldModel:BulkMoveTo(dynamic.replicas, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		end
		
		local overlapParams
		local queryParams = params.QueryParams
		
		if typeof(queryParams) == "function" then
			overlapParams = queryParams(zone)
		else
			overlapParams = queryParams
		end
		zone:Update(overlapParams, onEnter, onExit)
	end
end)

return Zones
