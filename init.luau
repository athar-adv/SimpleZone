--!optimize 2

--[[
	Zone Module (open source ver 2)
	
	Author: athar_adv
]]

local RunService 		= game:GetService('RunService')
local ScriptService		= game:GetService('ServerScriptService')
local Players 			= game:GetService('Players')
local ReplicatedStorage	= game:GetService('ReplicatedStorage')
local HttpService		= game:GetService('HttpService')

local IS_CLIENT			= RunService:IsClient()

local utility			= script.Utility
local templates			= script.Templates

local BVH				= require(utility.BVH)
local Signal 			= require(utility.SimpleSignal)
local JumpTable			= require(utility.JumpTable)

local SearchFor 		= require(script.SearchFor)
local PlayerLookup		= require(script.PlayerLookup)
local Zones				= require(script.Zones)

local characterObjects	= PlayerLookup.characterObjects

local clientTemplate	= templates.ClientWorker
local serverTemplate	= templates.ServerWorker

local Zone 				= {}
Zone.__index 			= Zone

export type Metadata  = {[any]: any}
export type QueryOptions = {
	FireMode: "OnEnter"|"OnExit"|"Both"|"None",
	TrackItemEnabled: boolean,
	StoreByClass: boolean,
	AcceptMetadata: boolean,
	UpdateInterval: number,
	InSeperateQuerySpace: boolean,
	Static: boolean,
	QuerySpace: {
		Space: QuerySpace,
		World: WorldRoot
	}?
}
export type QueryInfo = {
	QueryParams: OverlapParams | (zone: Zone) -> OverlapParams, 
	QueryOptions: QueryOptions
}
export type QuerySpace = {
	dynamic: {
		index: {BasePart},
		replicas: {BasePart}
	},

	static: {
		index: {BasePart},
		replicas: {BasePart}
	}
}

-- A folder to store actors
local actorContainer	= Instance.new("Folder")
actorContainer.Name		= "SIMPLEZONE_ZONE_ACTORS"
actorContainer.Parent 	= IS_CLIENT and Players.LocalPlayer.PlayerScripts or ScriptService

local actorTemplate		= IS_CLIENT and clientTemplate or serverTemplate
-- A folder to store WorldModels
local worldContainer			= Instance.new("Folder")
worldContainer.Name		= `SIMPLE_ZONE_QUERY_SPACES:CLIENT:{IS_CLIENT}`
worldContainer.Parent	= game:GetService('ReplicatedStorage')

local PART_QUERY_JUMP = JumpTable {
	Block = function(worldModel, part, params)
		return worldModel:GetPartBoundsInBox(part.CFrame, part.Size, params)
	end,
	Ball = function(worldModel, part, params)
		return worldModel:GetPartBoundsInRadius(part.Position, part.ExtentsSize.Y, params)
	end,
	_ = function(worldModel, part, params)
		return worldModel:GetPartsInPart(part, params)
	end,
}

local PART_WHITELIST = {Shape = true}
local PART_BLACKLIST = {
	CFrame = true,
	Position = true,
	Orientation = true
}

-- Create a new <code>QueryOptions</code> object.
local function queryop_new(): QueryOptions
	return {
		FireMode = "Both",
		TrackItemEnabled = false,
		StoreByClass = false,
		AcceptMetadata = false,
		UpdateInterval = 0,
		InSeperateQuerySpace = false,
		Static = true,
	}
end

local function isArray(t)
	if type(t) ~= "table" then
		return false
	end
	local len = #t
	if len == 0 then return false end

	return next(t, len) == nil
end

local function isPointInBox(point, boxCFrame, size)
	local localPoint = boxCFrame:PointToObjectSpace(point)
	
	return math.abs(localPoint.X) <= size.X and
		math.abs(localPoint.Y) <= size.Y and
		math.abs(localPoint.Z) <= size.Z
end

local function areAnyItemPointsInBox(world: {Instance}, boxCFrame: CFrame, boxSize: Vector3): boolean
	local size = boxSize/2
	
	for _, item in world do
		if not isPointInBox(item.Position, boxCFrame, size) then continue end
		
		return true
	end
	return false
end

local function removeFromQuerySpace(self, part: BasePart)
	if not part:IsA("BasePart") then return end
	local querySpace: QuerySpace = self._querySpace
	local connections = self._replicaConnect
	
	for _, c in connections[part] do
		c:Disconnect()
	end

	local index, tbl
	local staticIndex = table.find(querySpace.static.index, part)
	if staticIndex then
		index = staticIndex
		tbl = querySpace.static
	else
		index = table.find(querySpace.dynamic.index, part)
		tbl = querySpace.dynamic
	end
	if not index then return end

	table.remove(tbl.index, index)
	table.remove(tbl.replicas, index)
end

local function copyToQuerySpace(self, part: BasePart, static: boolean, propertyReplicationWhitelist, returnedReplicas)
	if not part:IsA("BasePart") then return end
	local querySpace: QuerySpace = self._querySpace
	local worldModel: WorldModel = self._worldModel
	local connections = self._replicaConnect

	local indexTable = static and querySpace.static.index or querySpace.dynamic.index
	local replicas = static and querySpace.static.replicas or querySpace.dynamic.replicas

	--local returnedReplicas = table.create(#parts)
	local index = #replicas + 1

	local replica = Instance.fromExisting(part)
	replica.Name = `REPLICA:{index}`
	replica.Parent = worldModel

	indexTable[index] = part
	replicas[index] = replica

	connections[part] = {
		propertyReplicationWhitelist ~= nil and part.Changed:Connect(function(property)
			if PART_BLACKLIST[property] then return end
			if not propertyReplicationWhitelist[property] then return end

			replica[property] = part[property]
		end),
		part.Destroying:Once(function()
			removeFromQuerySpace(self, part)
		end)
	}

	if returnedReplicas then
		table.insert(returnedReplicas, replica)
	end
	return replica
end

local function getTracked(self, item)
	for v in self._tracked do
		if item:IsDescendantOf(v) then
			return v
		end
	end
end

local function getParamsForPlayerCharacters(zone: Zone)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	
	local characters = {}
	for _, player in Players:GetPlayers() do
		if not player.Character then continue end
		table.insert(characters, player.Character)
	end
	
	params.FilterDescendantsInstances = characters
	return params
end

local function getItem(self, data)
	local querySpace: QuerySpace = self._querySpace
	local queryOptions = self._queryOptions
	
	local item = (typeof(data) == "table" and queryOptions.AcceptMetadata) and data.item or data
	if querySpace ~= nil then
		local index = table.find(querySpace.dynamic.replicas, item)
		if index then
			item = querySpace.dynamic.index[index]
		end
	end
	
	return 
		(queryOptions.TrackItemEnabled and getTracked(self, item)) 
	or	characterObjects[item] 
	or 	item
end

--[[
	Updates the items of the <code>Zone</code> and fires events.
]]
function Zone:Update(params: OverlapParams?, onEnter: boolean?, onExit: boolean?): ()
	local queryOptions = self._queryOptions
	
	local storeByClass = queryOptions.StoreByClass
	local acceptMetadata = queryOptions.AcceptMetadata
	
	local datas = self:Query(params)
	local lookup = {}
	
	for _, data in datas do
		if lookup[data] then continue end

		local item = getItem(self, data)
		
		if lookup[item] then continue end
		lookup[item] = true
		
		if self._items[item] then continue end
		local isTable = typeof(data) == "table"
		
		-- If accepts metadata, store the metadata (or true) inside the persistent items lookup
		if acceptMetadata then
			self._items[item] = isTable and data.metadata or true
			-- Else, just store as true to avoid indexing or doing logical operations
		else
			self._items[item] = true
		end

		-- If items should be stored by their class, then:
		if storeByClass then
			-- Get the class of the item (if item is an instance, that's the ClassName)
			local vtype = typeof(item)
			local class = vtype == "Instance" and item.ClassName or vtype

			local classes = self._storedClasses[class]

			-- If the classes table doesn't exist, create a new one:
			if not classes then
				classes = {}
				self._storedClasses[class] = classes
			end

			-- Store the item in the class array
			classes[#classes + 1] = item
		end
		
		if not onEnter then continue end
		-- If don't accept metadata, just fire the event straight away
		if not acceptMetadata then
			self.ItemEntered:Fire(item)
			continue
		end

		if isTable then
			self.ItemEntered:Fire(item, data.metadata)
		else
			self.ItemEntered:Fire(item)
		end
	end
	for item, metadata in self._items do
		-- If the item still exists within the query, keep it within the persistent items lookup
		if lookup[item] then continue end

		-- Remove the item from the persistent items lookup
		self._items[item] = nil
		
		--FORGIVE ME FOR NESTING SO HARD HERE
		
		-- If items should be stored by their class, then:
		if storeByClass then
			-- Get the class of the item (if item is an instance, that's the ClassName)
			local vtype = typeof(item)
			local class = vtype == "Instance" and item.ClassName or vtype
			
			local classes = self._storedClasses[class]
			
			-- If the classes table exists, remove the item from it as it is no longer inside the zone
			if classes then
				local index = table.find(classes, item)
				if index then
					table.remove(classes, index)

					-- If the classes table is now empty, remove it from the storedClasses dict
					if #classes == 0 then
						self._storedClasses[class] = nil
					end
				end
			end
		end
		
		if not onExit then continue end
		-- If don't accept metadata, just fire the event straight away
		if not acceptMetadata then
			self.ItemExited:Fire(item)
			continue
		end
		self.ItemExited:Fire(item, if metadata == true then nil else metadata)
	end
end

--[[
	Stops the automatic query of the <code>Zone</code>.
]]
function Zone:UnbindFromHeartbeat(): ()
	Zones.deregisterZone(self)
	table.clear(self._items)
end

--[[
	Starts the automatic query of the <code>Zone</code>.
	If <code>params</code> is provided, then all queries will be done using it.
	Otherwise, a function returning an <code>OverlapParams</code> to include all player characters will be used instead.
	Returns the <code>QueryInfo</code> which is used when querying the <code>Zone</code>.
]]
function Zone:BindToHeartbeat(params: (OverlapParams | (zone: Zone) -> OverlapParams)?): QueryInfo
	assert(params == nil or typeof(params) == "OverlapParams" or type(params) == "function", "params must be OverlapParams, function or nothing.")
	self:UnbindFromHeartbeat()
	
	local tbl = {
		QueryParams = params or getParamsForPlayerCharacters,
		QueryOptions = self._queryOptions
	}
	Zones.registerZone(self, tbl)
	
	return tbl
end

--[[
	If a descendant of <code>item</code> is found during query, <code>item</code> is returned instead of the descendant.
]]
function Zone:TrackItem(item: Instance): ()
	assert(typeof(item) == "Instance", `Bad item argument: {item} must be an instance.`)
	
	local trackItemEnabled = self._queryOptions.TrackItemEnabled
	if not trackItemEnabled then
		warn("TrackItemEnabled is not enabled, cannot call Zone:TrackItem(...)")
		return
	end
	if self._tracked[item] then
		warn(`Item {item} is already being tracked.`)
		return
	end
	self._tracked[item] = true
	
	local connections = self._trackedConnect
	connections[item] = item.Destroying:Once(function()
		connections[item] = nil
		self:UntrackItem(item)
	end)
end

--[[
	Untracks an item tracked by <code>self: Zone:TrackItem(...)</code>.
]]
function Zone:UntrackItem(item: Instance): ()
	assert(typeof(item) == "Instance", `Bad item argument: {item} must be an instance.`)
	
	if not self._tracked[item] then
		warn(`Item {item} is not currently being tracked.`)
		return
	end
	self._tracked[item] = nil
	
	local connections = self._trackedConnect
	if connections[item] then
		connections[item]:Disconnect()
		connections[item] = nil
	end
end

--[[
	Gets all items contained within the zone which are of <code>class</code> class/type.
]]
function Zone:GetItemsWhichAreA(class: string): {any}
	assert(typeof(class) == "string", "Bad class argument: class must be a string.")
	
	if not self._queryOptions.StoreByClass then
		warn("StoreByClass is not enabled, cannot call Zone:GetItemsWhichAreA(...)")
		return
	end
	
	return self._storedClasses[class] or {}
end

--[[
	Queries the <code>Zone</code> for <code>Instance</code>s with the specified properties.
	
	If <code>mode</code> is <code>"And"</code>, then it will only return <code>Instance</code>s that fully match the properties.
	Else if <code>mode</code> is <code>"Or"</code>, then it will return <code>Instance</code>s that match atleast one of the properties.
]]
function Zone:SearchFor(properties: {[string]: "Tag"|any}, mode: "And" | "Or"): {Instance?}
	assert(type(properties) == "table", "Bad properties argument.")
	assert(type(mode) == "string", "Bad mode argument.")
	local parts = self:Query()
	
	return SearchFor(
		parts,
		properties,
		mode
	)
end

--[[
	Calls <code>fn</code> when an item of class <code>datatype</code> enters/exits the <code>Zone</code>.
]]
function Zone:ListenTo(datatype: string | "LocalPlayer" | "Player" | "BasePart", mode: "Entered"|"Exited", fn: (item: Instance, metadata: Metadata?) -> ())
: Signal.RBXScriptConnection
	if datatype == "LocalPlayer" and not IS_CLIENT then
		error("Can only listen to LocalPlayer on the client.")
	end
	assert(mode == "Entered" or mode == "Exited", "Bad mode argument.")
	
	return self[`Item{mode}`]:Connect(function(item: Instance?, metadata)
		if datatype == "LocalPlayer" and item ~= Players.LocalPlayer then
			return
		end
		if datatype ~= "LocalPlayer" and not item:IsA(datatype) then
			return
		end

		fn(item, metadata)
	end)
end

--[[
	Returns wether or not an item is currently being tracked.
]]
function Zone:IsItemTracked(item: Instance): boolean
	return self._tracked[item] ~= nil
end

--[[
	Returns wether or not an item is currently within the <code>Zone</code>.
]]
function Zone:IsItemWithinZone(item: any): boolean
	return self._items[item] ~= nil
end

--[[
	Gets all items currently within the bounds of this <code>Zone</code>.
]]
function Zone:GetContainedItems(): {any}
	return self._items
end

--[[
	Gets all items currently being tracked by this <code>Zone</code>.
]]
function Zone:GetTracked(): {Instance?}
	return self._tracked
end

--[[
	Disconnects all bin related to this <code>Zone</code> and removes any associated <code>Actors</code>.
]]
function Zone:Destroy(): ()
	local bin = self._bin
	local tracked = self._trackedConnect
	local replica = self._replicaConnect
	for _, v in bin do
		if typeof(v) == "Instance" then
			v:Destroy()
		elseif typeof(v) == "RBXScriptConnection" then
			v:Disconnect()
		end
	end
	for _, v in tracked do
		v:Disconnect()
	end
	for _, v in replica do
		for _, w in v do
			w:Disconnect()
		end
	end
	task.defer(function()
		self.ItemEntered:Destroy()
		self.ItemExited:Destroy()

		setmetatable(self, nil)
		table.clear(self)
	end)
end

function Zone:GetQuerySpace(): WorldRoot
	return self._worldModel
end

--[[
	Copies an array of <code>BaseParts</code> to be replicated inside the query space. Returns the replicas
]]
function Zone:CopyToQuerySpace(parts: {Instance}, static: boolean?, propertyReplicationWhitelist: {[string]: true}?): {BasePart}
	assert(self._queryOptions.InSeperateQuerySpace, "InSeperateQuerySpace is not enabled, cannot call Zone:RegisterToQuerySpace(...)")
	
	local returnedReplicas = table.create(#parts)
	for _, part in parts do
		copyToQuerySpace(self, part, static, propertyReplicationWhitelist, returnedReplicas)
	end
	
	return returnedReplicas
end

function Zone:RemoveFromQuerySpace(originalParts: {Instance})
	assert(self._queryOptions.InSeperateQuerySpace, "InSeperateQuerySpace is not enabled, cannot call Zone:RemoveFromQuerySpace(...)")
	for _, part in originalParts do
		removeFromQuerySpace(self, part)
	end
end

function Zone:UseQuerySpaceOf(otherZone: Zone | "self")
	assert(self._queryOptions.InSeperateQuerySpace, "InSeperateQuerySpace is not enabled, cannot call Zone:UseQuerySpaceOf(...)")
	assert(otherZone ~= nil, "Bad otherZone argument")
	
	local queryOp: QueryOptions = self._queryOptions
	assert(not (not queryOp.InSeperateQuerySpace and otherZone == "self"), 
		"Cannot use query space of self because zone was not created in a seperate query space.")
	
	local querySpace, worldModel
	if otherZone == "self" then
		querySpace = self._ownQuerySpace or self._querySpace
		worldModel = self._worldModel
	else
		querySpace = otherZone._querySpace
		worldModel = otherZone._worldModel
	end
	
	if otherZone ~= "self" then
		self._ownQuerySpace = self._querySpace
	else
		self._ownQuerySpace = nil
	end
	
	self._querySpace = querySpace
	self._worldModel = worldModel
end

function Zone:OverwriteQuerySpace(otherZone: Zone)
	assert(self._queryOptions.InSeperateQuerySpace, "InSeperateQuerySpace is not enabled, cannot call Zone:OverwriteQuerySpace(...)")
	assert(otherZone ~= nil, "Bad otherZone argument")
	
	local querySpace: QuerySpace = self._querySpace
	
	self:RemoveFromQuerySpace(querySpace.dynamic.index)
	self:RemoveFromQuerySpace(querySpace.static.index)
	self._worldModel:Destroy()
	
	self._querySpace = otherZone._querySpace
	self._worldModel = otherZone._worldModel
end

local function assertQueryOp(queryOp)
	if not queryOp then return end

	local mode = queryOp.FireMode

	assert(
		mode == "Both"
	or	mode == "OnExit"
	or	mode == "OnEnter"
	or	mode == "None",
		"Bad QueryOptions argument. (FireMode not specified)"
	)
	if queryOp.ThrottlingEnabled and not queryOp.UpdateInterval then
		error("QueryOptions.UpdateInterval must be specified if QueryOptions.ThrottlingEnabled is true.")
	end
end

export type Zone = typeof(Zone) & {
	Query: typeof(
		--[[
			A replaceable callback function that the <code>Zone</code> calls whenever querying the <code>Zone</code>.
		]]
		function(self: Zone, params: OverlapParams?): {Metadata | Instance | any}
		end
	),
	
	ItemExited: Signal.RBXScriptSignal<Instance?, {[any]: any}?>,
	ItemEntered: Signal.RBXScriptSignal<Instance?, {[any]: any}?>
}

-- The reason why there is a metatable argument is to allow easy extensibility of this module
local function zone_new<T>(queryOp: QueryOptions, ...)
: {ItemEntered: Signal.RBXScriptSignal, ItemExited: Signal.RBXScriptSignal} & MT<T>
	queryOp = queryOp or queryop_new()
	assertQueryOp(queryOp)
	
	local bin = {...}
	local zone = setmetatable({
		-- Tables with [Instance]: RBXScriptConnection pairs to track connections
		_trackedConnect	= {},
		_replicaConnect	= {},
		
		-- Main
		_items 			= {},
		_storedClasses	= {},
		_tracked		= {},
		_bin			= bin,
		_queryOptions 	= queryOp,
		_lastUpdate		= os.clock(),
		
		_worldModel		= workspace,
		
		ItemEntered 	= Signal.new(),
		ItemExited 		= Signal.new(),

	}, Zone)
	
	if queryOp.InSeperateQuerySpace and queryOp.QuerySpace == nil then
		local model = Instance.new("WorldModel")
		model.Name = `SimpleZone_QuerySpace({HttpService:GenerateGUID(false)})`
		model.Parent = worldContainer
		table.insert(bin, model)
		-- Internal query space
		zone._worldModel = model
		zone._querySpace = {
			dynamic = {
				index = {},
				replicas = {}
			},
			
			static = {
				index = {},
				replicas = {}
			},
		}
	elseif queryOp.QuerySpace ~= nil then
		assert(queryOp.QuerySpace.World ~= nil and queryOp.QuerySpace.Space ~= nil, "Missing world/space fields for QuerySpace")
		zone._worldModel = queryOp.QuerySpace.World
		zone._querySpace = queryOp.QuerySpace.Space
	end
	
	return zone
end

local function getBoxesFromParts(parts)
	local boxes = {}
	local VOXEL_SIZE = BVH.VoxelSize

	for _, part in parts do
		local pos = part.Position
		local size = part.Size
		
		if part.Size.Magnitude > 500 then
			pos = Vector3.new(
				(pos.X // VOXEL_SIZE) * VOXEL_SIZE,
				(pos.Y // VOXEL_SIZE) * VOXEL_SIZE,
				(pos.Z // VOXEL_SIZE) * VOXEL_SIZE 
			)
			size = Vector3.new(
				(size.X // VOXEL_SIZE) * VOXEL_SIZE,
				(size.Y // VOXEL_SIZE) * VOXEL_SIZE,
				(size.Z // VOXEL_SIZE) * VOXEL_SIZE 
			)
		end
		
		boxes[#boxes + 1] = {
			cframe = part.CFrame.Rotation + pos,
			size = size,
			part = part
		}
	end
	
	return boxes
end

-- Creates a new <code>Zone</code> based on a <code>BasePart</code>.
local function zone_fromPart(part: BasePart, queryOp: QueryOptions?): Zone
	assertQueryOp(queryOp)
	queryOp = queryOp or queryop_new()
	
	local zone = zone_new(queryOp)
	if queryOp.InSeperateQuerySpace then
		part = copyToQuerySpace(zone, part, queryOp.Static, PART_WHITELIST)
	end
	
	function zone:Query(params: OverlapParams)
		local worldModel = self._worldModel
		if part:IsA("Part") then
			return PART_QUERY_JUMP(part.Shape.Name, worldModel, part, params)
		end

		return worldModel:GetPartsInPart(part, params)
	end
	
	return zone
end

-- Creates a new <code>Zone</code> based on an bounding box.
local function zone_fromBox(cframe: CFrame, size: Vector3, queryOp: QueryOptions?): Zone
	assertQueryOp(queryOp)
	queryOp = queryOp or queryop_new()
	
	local zone = zone_new(queryOp)
	
	function zone:Query(params: OverlapParams)
		return self._worldModel:GetPartBoundsInBox(cframe, size, params)
	end
	
	return zone
end

-- Creates a new <code>Zone</code> based on an array of bounding boxes made with a BVH structure for optimal efficiency
local function zone_fromBoxes(boxes: {{cframe: CFrame, size: Vector3}}, queryOp: QueryOptions?): Zone
	assertQueryOp(queryOp)
	queryOp = queryOp or queryop_new()
	
	local bvh, leaves = BVH.createBVH(boxes)

	local zone = zone_new(queryOp)
	
	function zone:Query(params: OverlapParams?)
		local queryOp: QueryOptions = self._queryOptions
		local querySpace: QuerySpace = self._querySpace
		local worldModel = self._worldModel
		local result = {}
		
		BVH.traverseBVH(bvh, function(box)
			local query
			if querySpace ~= nil then
				if not areAnyItemPointsInBox(querySpace.dynamic.replicas, box.cframe, box.size) then
					return false
				end
				if box.right or box.left then
					return true
				end
				query = worldModel:GetPartBoundsInBox(box.cframe, box.size, params)
			else
				query = worldModel:GetPartBoundsInBox(box.cframe, box.size, params)
				-- Is empty, don't continue
				if #query == 0 then
					return false
				end
				-- Is not a leaf node, but isnt empty, so should contiune
				if box.right or box.left then
					return true
				end
			end

			-- Is leaf node
			if self._queryOptions.AcceptMetadata then
				for _, item in query do
					table.insert(result, {item = item, metadata = {box = box}})
				end
			else
				table.move(query, 1, #query, #result + 1, result)
			end

			return false
		end)

		return result
	end
	
	return zone
end

-- Creates a new <code>Zone</code> based on an array of <code>BaseParts</code> made with a BVH structure for optimal efficiency
local function zone_fromParts(parts: {BasePart}, queryOp: QueryOptions?): Zone
	assertQueryOp(queryOp)
	queryOp = queryOp or queryop_new()
	
	local boxes
	
	local zone = zone_new(queryOp)
	if queryOp.InSeperateQuerySpace then
		local replicas = zone:CopyToQuerySpace(parts, queryOp.Static, PART_WHITELIST)
		boxes = getBoxesFromParts(replicas)
	else
		boxes = getBoxesFromParts(parts)
	end
	
	local bvh = BVH.createBVH(boxes)
	
	function zone:Query(params: OverlapParams?)
		local querySpace: QuerySpace = self._querySpace
		local queryOp: QueryOptions = self._queryOptions
		local worldModel = self._worldModel
		local result = {}
		
		local zonePlace = querySpace ~= nil and (queryOp.Static and querySpace.static or querySpace.dynamic)
		
		BVH.traverseBVH(bvh, function(box)
			local blockQuery = nil
			if querySpace then
				if not areAnyItemPointsInBox(querySpace.dynamic.replicas, box.cframe, box.size) then
					return false
				end
				if not box.part then
					return true 
				end
			else
				blockQuery = worldModel:GetPartBoundsInBox(box.cframe, box.size, params)
				if not box.part then
					return #blockQuery > 0
				end
			end
			
			local query
			local part: BasePart = box.part

			if part:IsA("Part") then
				if part.Shape == Enum.PartType.Block and blockQuery then
					query = blockQuery
				else
					query = PART_QUERY_JUMP(part.Shape.Name, worldModel, part, params)
				end
			else
				query = worldModel:GetPartsInPart(part, params)
			end
			
			-- Is leaf node
			if queryOp.AcceptMetadata then
				local part = box.part
				if queryOp.InSeperateQuerySpace then
					local index = table.find(zonePlace.replicas, box.part)
					part = zonePlace.index[index]
				end
				
				for _, item in query do
					table.insert(result, {item = item, metadata = {part = part}})
				end
			else
				table.move(query, 1, #query, #result + 1, result)
			end

			return false -- Stop traversing this branch
		end)

		return result
	end
	
	return zone
end

local function zone_fromPartsLPO()
	error("Zone.fromPartsLPO() is deprecated, it should not be used for new work.")
end

local function zone_fromPartsUpdatable()
	error("Zone.fromPartsUpdatable() is deprecated, it should not be used for new work.")
end

-- Creates a new <code>Zone</code> based on a <code>part</code>. Does queries in parallel.
local function zone_fromPartParallel(part: BasePart, queryOp: QueryOptions?): Zone
	assertQueryOp(queryOp)
	queryOp = queryOp or queryop_new()
	
	local worker = actorTemplate:Clone()
	worker.Parent = actorContainer

	local resultEvent = worker.Result

	local zone = zone_new(queryOp, worker)
	if queryOp.InSeperateQuerySpace then
		part = copyToQuerySpace(zone, part, queryOp.Static, PART_WHITELIST)
	end
	
	function zone:Query(params: OverlapParams)
		local worldModel = self._worldModel
		task.defer(worker.SendMessage, worker, "GetPartsInPart", worldModel, params, part)
		return resultEvent.Event:Wait()
	end
	
	return zone
end

-- Creates a new <code>Zone</code> using a custom query function <code>queryFn</code>.
local function zone_fromCustom(queryFn: (self: Zone, params: OverlapParams?) -> {{item: any, metadata: Metadata} | any | Instance}, queryOp: QueryOptions?): Zone
	assert(queryFn ~= nil, "Bad queryFn argument.")
	assertQueryOp(queryOp)
	queryOp = queryOp or queryop_new()
	
	local zone = zone_new(queryOp)
	zone.Query = queryFn
	
	return zone
end

local zone_new_overload: 
	typeof(zone_fromPart) & typeof(zone_fromBox) & typeof(zone_fromParts) & typeof(zone_fromBoxes) 
= function(a, b, c)
	
	if isArray(a) then
		if typeof(a[1]) == "Instance" and a[1]:IsA("BasePart") then
			return zone_fromParts(a, b)
		elseif typeof(a[1]) == "table" then
			return zone_fromBoxes(a, b)
		else
			error("Unable to find an overload.")
		end
	end
	
	if typeof(a) == "CFrame" and typeof(b) == "Vector3" then
		return zone_fromBox(a, b, c)
	elseif typeof(a) == "Instance" and a:IsA("BasePart") then
		return zone_fromPart(a, b)
	else
		error("Unable to find an overload.")
	end
end

local lpOnly = script:GetAttribute("ClientOnlyDetectLocalPlayer")
if lpOnly and RunService:IsClient() then
	PlayerLookup.onPlayerAdded(Players.LocalPlayer)
else
	PlayerLookup.start()
end

return table.freeze {
	new = zone_new_overload,
	fromBox = zone_fromBox,
	fromPart = zone_fromPart,
	fromParts = zone_fromParts,
	fromBoxes = zone_fromBoxes,
	fromCustom = zone_fromCustom,
	fromPartParallel = zone_fromPartParallel,
	fromPartsUpdatable = zone_fromPartsUpdatable,
	fromPartsLPO = zone_fromPartsLPO,
	
	QueryOptions = {
		new = queryop_new
	},
	
	-- Incase someone wants to use these independently
	searchFor = SearchFor,
	BVH = BVH,
	ZoneClass = Zone,
	PlayerLookup = PlayerLookup,
	PartQueryJump = PART_QUERY_JUMP
}
