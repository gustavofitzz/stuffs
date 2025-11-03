--[[
	Copyright (c) 2025 @154090147
	Licensed under the BSD 3-Clause License. See LICENSE file for details.
--]]
--[[
	Module script to parallelize renders by buffers, works best with OSGL
	
	workerTemplate must have the following bindings:
		actor:BindToMessageParallel("Start", function(managerName: string, renderSizeX: number, renderSizeY: number, pixelScale: number)
			-- runs only once
			-- used for initialzing SharedTables and render resolution vairables
		end)
		actor:BindToMessageParallel("Update", function(yCoord: number, rowsToRender: number)
			-- runs continuously
			-- should update the output sharedtable
			-- SharedTable of `{managerName}.output[yCoord]` should be overwritten to trigger manager.RenderStepped
		end)
]]

local module = {}

-- Micro-optimization
local random = math.random
local abs = math.abs
local clamp = math.clamp
local createBuffer = buffer.create
local bufferReadu32 = buffer.readu32
local bufferWriteu32 = buffer.writeu32
local bufferFromString = buffer.fromstring
local bufferToString = buffer.tostring

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

-- Directories

local function req(id)
	local Source = game:GetObjects("rbxassetid://"..id)[1].Source
	local Function = loadstring(Source)
	local Module = Function()
	return Module
end
-- Dependencies
local OSGL = req(92758009507862)
local OSGLWindow = OSGL.Window

-- Module functions
function module.batch(image: EditableImage, managerParent: Instance, workerTemplate: BaseScript, workerAmount: number, width: number, height: number, pixelScale: number)
	-- Sanitize Inputs
	workerAmount = clamp(workerAmount, 1, height)

	-- Calculate Actor Row Distribution
	local rowsPerActor = height // workerAmount
	local leftOverRows = height % workerAmount

	-- Create Shared Output
	local renderOutput = SharedTable.new()

	-- Initialize Actors
	local actors = {}
	for i = 1, workerAmount do
		local actor = Instance.new("Actor")
		local clonedWorker = workerTemplate:Clone()
		clonedWorker.Parent = actor
		actor.Parent = managerParent
		actors[i] = actor
	end

	task.wait()
	for i, actor in actors do
		actor:SendMessage("SetImage", image)
		actor:SendMessage("Start", renderOutput, width, height, pixelScale)
	end

	-- Create Manager and Bindable Events
	local windowUpdateBE = Instance.new("BindableEvent")
	local applyMetadataBE = Instance.new("BindableEvent")
	local manager = {
		RenderStepped = windowUpdateBE.Event,
		ApplyMetadata = applyMetadataBE,
		output = renderOutput,
		renderSizeX = width,
		renderSizeY = height,
		pixelScale = pixelScale,
	}

	-- Metadata Application
	applyMetadataBE.Event:Connect(function(metadata)
		for i, actor in actors do
			actor:SendMessage("ApplyMetadata", metadata)
		end
	end)

	-- Periodic Update
	local previousClock = os.clock()
	RunService.PreRender:Connect(function()
		-- Update Actors with proper section distribution
		for i, actor in actors do
			local startRow, count
			if i <= leftOverRows then
				startRow = (i - 1) * (rowsPerActor + 1)
				count = rowsPerActor + 1
			else
				startRow = leftOverRows * (rowsPerActor + 1) + (i - leftOverRows - 1) * rowsPerActor
				count = rowsPerActor
			end
			actor:SendMessage("Update", startRow, count)
		end
		
		--[Sle_l] uncomment for full version of module, now the mainscript and workers "communicate directly".
		-- Collect and Process Output from the SharedTable
		--local outputString = ""
		--for i, v in renderOutput do
		--	outputString ..= v
		--end
		
		--if #outputString ~= width * height * 4 then
		--	--warn(`Output mismatch ({#outputString} ~= {width * height * 4})`)
		--	continue
		--end

		--manager.output = bufferFromString(outputString)
		windowUpdateBE:Fire(os.clock() - previousClock)
		previousClock = os.clock()
	end)

	-- Manager Methods
	function manager:Resize(newImage: EditableImage, newWidth: number, newHeight: number, newPixelScale: number)
		width, height, pixelScale = newWidth, newHeight, newPixelScale
		rowsPerActor = height // workerAmount
		leftOverRows = height % workerAmount
		renderOutput = SharedTable.new()
		image = newImage

		-- Restart Actors with the new settings
		for i, actor in actors do
			actor:SendMessage("Start", renderOutput, width, height, pixelScale)
			actor:SendMessage("SetImage", image)
		end
	end

	function manager:Destroy()
		for i, actor in actors do
			actor:Destroy()
		end
		windowUpdateBE:Destroy()
		applyMetadataBE:Destroy()
		manager.output = nil
		manager = nil
	end

	return manager
end

return module
