local Players = game:GetService('Players')

local partToPlayer = {}
local connectionTracker = {}

local function handleCharacterUpdate(player, character)
	for _, v in connectionTracker[player] do
		v:Disconnect()
	end
	for part, owner in partToPlayer do
		if owner ~= player then continue end
		partToPlayer[part] = nil
	end
	
	for _, descendant in character:GetDescendants() do
		if not descendant:IsA("BasePart") then continue end
		partToPlayer[descendant] = player
	end
	
	table.insert(connectionTracker[player], character.DescendantAdded:Connect(function(descendant)
		if not descendant:IsA("BasePart") then return end
		partToPlayer[descendant] = player
	end))
	
	table.insert(connectionTracker[player], character.DescendantRemoving:Connect(function(descendant)
		if not descendant:IsA("BasePart") then return end
		partToPlayer[descendant] = nil
	end))
end

local function onPlayerAdded(player)
	connectionTracker[player] = {}
	
	player.CharacterAdded:Connect(function(character)
		handleCharacterUpdate(player, character)
	end)
	
	if player.Character then
		handleCharacterUpdate(player, player.Character)
	end
end

local function onPlayerRemoving(player)
	for _, v in connectionTracker[player] do
		v:Disconnect()
	end
	connectionTracker[player] = nil
	
	for part, owner in partToPlayer do
		if owner ~= player then continue end
		
		partToPlayer[part] = nil
	end
end

local function start()
	local playerAdded = Players.PlayerAdded:Connect(onPlayerAdded)
	local playerRemoving = Players.PlayerRemoving:Connect(onPlayerRemoving)
	
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	return playerAdded, playerRemoving
end

return {
	characterObjects = partToPlayer,
	start = start,
	onPlayerAdded = onPlayerAdded,
	onPlayerRemoving = onPlayerRemoving
}
