--!optimize 2
--!native

--[[
	Utility module to create a Bounding Volume Hierarchy
	from an array of boxes.
]]

local VOXEL_SIZE = 4

type Box = {cframe: CFrame, size: Vector3}

type BoxNode = {
	cframe: CFrame,
	size: Vector3,
	left: BoxNode?,
	right: BoxNode?
}

function traverseBVH(root: BoxNode, callback: (box: BoxNode, stop: () -> ()) -> boolean)
	local stack = {root}
	local stackSize = 1
	local stopFlag = false
	
	local function stop()
		table.clear(stack)
		stopFlag = true
	end
	while stackSize > 0 do
		if stopFlag then break end
		
		local node = stack[stackSize]
		stackSize -= 1
		
		--local size = node.size
		--if size.x*size.y*size.z > 729_000 then
		--	if node.right then
		--		stackSize += 1
		--		stack[stackSize] = node.right
		--	end

		--	if node.left then
		--		stackSize += 1
		--		stack[stackSize] = node.left
		--	end
		--	continue
		--end
		
		local shouldContinue = callback(node, stop)
		if not shouldContinue then
			continue
		end
		
		if node.right then
			stackSize += 1
			stack[stackSize] = node.right
		end

		if node.left then
			stackSize += 1
			stack[stackSize] = node.left
		end
	end
end

local function getBoundingBox(boxes)
	local minBounds = vector.create(math.huge, math.huge, math.huge)
	local maxBounds = vector.create(-math.huge, -math.huge, -math.huge)

	for _, box in boxes do
		local cframe, size = box.cframe, box.size
		local halfSize = size * 0.5

		-- Calculate the eight corners of the box
		local corners = {
			cframe.Position + vector.create(-halfSize.X, -halfSize.Y, -halfSize.Z),
			cframe.Position + vector.create(halfSize.X, -halfSize.Y, -halfSize.Z),
			cframe.Position + vector.create(-halfSize.X, halfSize.Y, -halfSize.Z),
			cframe.Position + vector.create(halfSize.X, halfSize.Y, -halfSize.Z),
			cframe.Position + vector.create(-halfSize.X, -halfSize.Y, halfSize.Z),
			cframe.Position + vector.create(halfSize.X, -halfSize.Y, halfSize.Z),
			cframe.Position + vector.create(-halfSize.X, halfSize.Y, halfSize.Z),
			cframe.Position + vector.create(halfSize.X, halfSize.Y, halfSize.Z),
		}

		-- Expand the bounding box to include this box's corners
		for _, corner in corners do
			minBounds = vector.create(
				math.min(minBounds.X, corner.X) // VOXEL_SIZE * VOXEL_SIZE,
				math.min(minBounds.Y, corner.Y) // VOXEL_SIZE * VOXEL_SIZE,
				math.min(minBounds.Z, corner.Z) // VOXEL_SIZE * VOXEL_SIZE
			)
			maxBounds = vector.create(
				math.max(maxBounds.X, corner.X) // VOXEL_SIZE * VOXEL_SIZE,
				math.max(maxBounds.Y, corner.Y) // VOXEL_SIZE * VOXEL_SIZE,
				math.max(maxBounds.Z, corner.Z) // VOXEL_SIZE * VOXEL_SIZE
			)
		end
	end

	-- Calculate the bounding box center and size
	local size = maxBounds - minBounds
	local center = (minBounds + maxBounds) / 2
	local boundingCFrame = CFrame.new(center)

	-- Return the CFrame and size
	return boundingCFrame, size
end


local function determine(parent: BoxNode, name: string, boxes: {Box})
	if #boxes > 1 then
		local cframe, size = getBoundingBox(boxes)
		parent[name] = {
			cframe = cframe,
			size = size,
			--volume = size.x * size.y * size.z
		}

		split(parent[name], boxes)
	elseif #boxes == 1 then
		local box = boxes[1]
		parent[name] = {
			cframe = box.cframe,
			size = box.size,
			--volume = box.size.x * box.size.y * box.size.z,
			part = box.part,
		}
	end
end

function split(parent: BoxNode, boxes: {Box})
	local size = parent.size
	local longestAxis

	if size.X >= size.Y and size.X >= size.Z then
		longestAxis = "X"
	elseif size.Y >= size.X and size.Y >= size.Z then
		longestAxis = "Y"
	elseif size.Z >= size.Y and size.Z >= size.X then
		longestAxis = "Z"
	end

	table.sort(boxes, function(a, b)
		return a.cframe[longestAxis] < b.cframe[longestAxis]
	end)

	local len = #boxes
	local mid = len//2

	local leftBoxes = table.create(mid)
	local rightBoxes = table.create(mid)
	table.move(boxes, 1, mid, 1, leftBoxes)
	table.move(boxes, mid + 1, len, 1, rightBoxes)

	determine(parent, "left", leftBoxes)
	determine(parent, "right", rightBoxes)
end

local function createBVH(boxes: {{cframe: CFrame, size: Vector3}}): (BoxNode)
	local cframe, size = getBoundingBox(boxes)

	local root = {
		cframe = cframe,
		size = size,
		--volume = size.x * size.y * size.z
	}

	split(root, boxes)

	return root
end

local function calculateDistance(box1, box2)
	local center1 = box1.cframe.Position
	local center2 = box2.cframe.Position

	return (center1 - center2).Magnitude
end

local function needsUpdate(oldBox, newBox, threshold)
	-- Check if the box has moved significantly
	local distance = calculateDistance(oldBox, newBox)
	local sizeChange = (oldBox.size - newBox.size).Magnitude

	-- Update if position changed more than threshold or size changed significantly
	return distance > threshold or sizeChange > threshold
end

local function updateBVHNode(node, oldBoxes, newBoxes, threshold)
	if not node then return end

	-- Leaf node
	if node.part then
		local oldBox = {
			cframe = node.cframe,
			size = node.size,
			--volume = node.volume,
			part = node.part
		}

		-- Find corresponding new box
		local newBox
		for _, box in newBoxes do
			if box.part == node.part then
				newBox = box
				break
			end
		end

		-- If part found and needs update
		if newBox and needsUpdate(oldBox, newBox, threshold) then
			node.cframe = newBox.cframe
			node.size = newBox.size
			--node.volume = newBox.volume
			return true
		end
		return false
	end

	-- Internal node
	local leftUpdated = updateBVHNode(node.left, oldBoxes, newBoxes, threshold)
	local rightUpdated = updateBVHNode(node.right, oldBoxes, newBoxes, threshold)

	-- If either child updated, recalculate bounds
	if leftUpdated or rightUpdated then
		-- Get combined bounds of children
		local leftBounds = node.left and {
			cframe = node.left.cframe,
			size = node.left.size,
			--volume = node.left.volume
		}
		local rightBounds = node.right and {
			cframe = node.right.cframe,
			size = node.right.size,
			--volume = node.right.volume
		}

		if leftBounds and rightBounds then
			local leftPos = leftBounds.cframe.Position
			local rightPos = rightBounds.cframe.Position

			local minBounds = vector.create(
				math.min(leftPos.X - leftBounds.size.X/2, rightPos.X - rightBounds.size.X/2) // VOXEL_SIZE * VOXEL_SIZE,
				math.min(leftPos.Y - leftBounds.size.Y/2, rightPos.Y - rightBounds.size.Y/2) // VOXEL_SIZE * VOXEL_SIZE,
				math.min(leftPos.Z - leftBounds.size.Z/2, rightPos.Z - rightBounds.size.Z/2) // VOXEL_SIZE * VOXEL_SIZE
			)

			local maxBounds = vector.create(
				math.max(leftPos.X + leftBounds.size.X/2, rightPos.X + rightBounds.size.X/2) // VOXEL_SIZE * VOXEL_SIZE,
				math.max(leftPos.Y + leftBounds.size.Y/2, rightPos.Y + rightBounds.size.Y/2) // VOXEL_SIZE * VOXEL_SIZE,
				math.max(leftPos.Z + leftBounds.size.Z/2, rightPos.Z + rightBounds.size.Z/2) // VOXEL_SIZE * VOXEL_SIZE
			)

			local size = maxBounds - minBounds
			local center = (minBounds + maxBounds) / 2

			node.cframe = CFrame.new(center)
			node.size = size
			--node.volume = size.x * size.y * size.z
		elseif leftBounds then
			node.cframe = leftBounds.cframe
			node.size = leftBounds.size
			--node.volume = leftBounds.volume
		elseif rightBounds then
			node.cframe = rightBounds.cframe
			node.size = rightBounds.size
			--node.volume = rightBounds.volume
		end

		return true
	end

	return false
end

local function updateBVH(bvh, oldBoxes, newBoxes, threshold)
	threshold = threshold or 0.1

	local updated = updateBVHNode(bvh, oldBoxes, newBoxes, threshold)

	return updated
end

local function visualize(bvh)
	traverseBVH(bvh, function(box)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Transparency = 0.7
		part.CFrame = box.cframe
		part.Size = box.size
		part.Parent = workspace

		part.CanCollide = false
		part.CanQuery = false

		if not box.right and not box.left then
			part.Color = Color3.fromRGB(255, 0, 0)
		end

		return true
	end)
end

return {
	createBVH = createBVH,
	traverseBVH = traverseBVH,
	updateBVH = updateBVH,
	getBoundingBox = getBoundingBox,
	visualize = visualize,
	VoxelSize = VOXEL_SIZE,
}
