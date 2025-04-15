return function<T...>(cases: {[any | "_"]: (T...) -> any})
	return function(value, ...)
		local case = cases[value] or cases["_"]
		if not case then return end
		
		return case(...)
	end
end
