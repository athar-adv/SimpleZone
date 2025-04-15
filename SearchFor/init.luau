local function splitRecursiveProperty(name: string)
	local instanceSplit = name:split("_")
	
	name = instanceSplit[1]
	
	return name, #instanceSplit > 1 and table.concat(instanceSplit, "_", 2, #instanceSplit)
end

local function propertyChecker(part, mode, checkCondition, properties)
	for name, value in properties do
		local name, recursiveProperty = splitRecursiveProperty(name)

		-- If a part contains a parent of the same name, it will recursively search that part until the last property is found (example, Foo_Parent_Parent_Name = "Bar")
		if name == "Parent" and recursiveProperty then
			local parts = SearchFor({part.Parent}, {[recursiveProperty] = value}, mode)
			checkCondition(parts[part.Parent])
			continue
		end
		-- If a part contains a child of the same name, it will recursively search that part until the last property is found (example, Foo_Bar_Baz_Name = "Bar")
		if part:FindFirstChild(name) and recursiveProperty then
			local parts = SearchFor({part:FindFirstChild(name)}, {[recursiveProperty] = value}, mode)
			checkCondition(parts[part.Parent])
			continue
		end
		-- If a key contains _IsTag or Tag_ then the value will be considered as a tag name.
		if value == "Tag" then
			checkCondition(part:HasTag(name))
			continue
		end
		-- If a key contains Attribute_ then the value will be considered as an attribute value
		if name:match("Attribute_") then
			local attName = name:split("_")[2]

			local condition = part:GetAttribute(attName) == value

			checkCondition(condition)
			continue
		end

		checkCondition(part[name] == value)
	end
end

function SearchFor(tableToSort, properties: {[string]: any}, mode: "And" | "Or")
	assert(mode ~= nil and (mode == "Or" or mode == "And"), "Bad mode argument.")
	
	local qualifiedParts = {}

	for i, part: BasePart in tableToSort do
		local doesNotMatch = false
		
		local function checkCondition(condition: any)
			if condition and mode == "Or" then
				table.insert(qualifiedParts, part)
			elseif not condition and mode == "And" then
				doesNotMatch = true
			end
		end
		
		propertyChecker(part, mode, checkCondition, properties)

		if not doesNotMatch and mode == "And" then
			table.insert(qualifiedParts, part)
		end
	end
	return qualifiedParts
end

return SearchFor
