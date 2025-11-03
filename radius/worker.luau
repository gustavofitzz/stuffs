--!optimize 2
--!native

-- Actor stuff
local actor = script:GetActor()
if actor == nil then return end

-- Micro-optimization
local random = math.random
local abs = math.abs
local clamp = math.clamp
local createBuffer = buffer.create
local bufferReadu32 = buffer.readu32
local bufferWriteu32 = buffer.writeu32
local bufferFromString = buffer.fromstring
local bufferToString = buffer.tostring

-- Constants
local BLANK = Vector3.zero

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

-- Directories
local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

local src = ReplicatedStorage:WaitForChild("src")

-- Dependencies
local function req(id)
	local Source = game:GetObjects("rbxassetid://"..id)[1].Source
	local Function = loadstring(Source)
	local Module = Function()
	return Module
end
--local src = ReplicatedStorage:WaitForChild("src")
local OSGL = req(92758009507862)
local OSGLcolor = OSGL.color
local OSGLWindow = OSGL.Window
local OSGLtypes = OSGL.types

local radius = req(110654915088025)
local deps = game:GetObjects("rbxassetid://139461040258753")[1]
local covec = loadstring(deps.covec)()
local tonemap = loadstring(deps.tonemap)()

-- Variables initialized by manager
local renderSizeX, renderSizeY, pixelScale = nil, nil, nil
local accumulation = true
local image: EditableImage
local output: SharedTable = nil

-- Variables that can be overwritten; these are just defaults.
local maxSamples = 128
local raySetting = radius.setting()

-- Run-time variables
local doneSamples = 0
local accumRender = {}

-- OSGL Functions
local function readPixel(bfr: buffer, bufferWidth: number, x: number, y: number): buffer
	return bufferReadu32(bfr, (y * bufferWidth + x) * 4)
end
local function writePixel(bfr: buffer, bufferWidth: number, x: number, y: number, color)
	bufferWriteu32(bfr, (y * bufferWidth + x) * 4, color)
end

-- Functions
local function frag(x: number, y: number, pixelScale: number): OSGLtypes.Color
	local unitRay = camera:ScreenPointToRay(x * pixelScale, y * pixelScale)
	local tracedColor = radius.pathtrace(unitRay.Origin, unitRay.Direction)
	
	accumRender[x][y] += tracedColor
	
	return covec.toOSGL((if doneSamples >= maxSamples then tonemap.aces_fitted else tonemap.aces_approx)(accumRender[x][y] / doneSamples))
end

local function resetAccumRender()
	for x = 0, renderSizeX - 1 do
		local row = accumRender[x]
		for y = 0, renderSizeY - 1 do
			row[y] = BLANK
		end
	end
end

local lastCameraPos = camera.CFrame.Position
local function didCameraMove()
	return (lastCameraPos - camera.CFrame.Position).Magnitude >= 0.01
end

-- Parallelized connections
actor:BindToMessageParallel("SetImage", function(editableImage: EditableImage)
	image = editableImage
end)
actor:BindToMessageParallel("Start", function(argOutput: SharedTable, argRenderSizeX: number, argRenderSizeY: number, argPixelScale: number)
	-- Set variables
	renderSizeX, renderSizeY, pixelScale = argRenderSizeX, argRenderSizeY, argPixelScale
	output = argOutput
	doneSamples = 0
	
	-- Create accumulated render table
	accumRender = table.create(renderSizeX)
	for x = 0, renderSizeX - 1 do
		accumRender[x] = table.create(renderSizeY)
		for y = 0, renderSizeY - 1 do
			accumRender[x][y] = BLANK
		end
	end
end)
actor:BindToMessageParallel("Update", function(yCoord: number, rowsToRender: number)
	if didCameraMove() or (not accumulation) then
		lastCameraPos = camera.CFrame.Position
		doneSamples = 0
		resetAccumRender()
	end
	if doneSamples > maxSamples then
		return
	end
	doneSamples += 1
	
	local bfr = createBuffer(renderSizeX * rowsToRender * 4)
	for yActorRow = 0, rowsToRender - 1 do
		for xCoord = 0, renderSizeX - 1 do
			local color = frag(xCoord, (yCoord + yActorRow), pixelScale)
			writePixel(bfr, renderSizeX, xCoord, yActorRow, color)
		end
	end
	
	--output[yCoord] = bufferToString(bfr) --[Sle_l] removed because the master script now reads the EI directly, and now workers write to EI directly.
	task.synchronize()
	image:WritePixelsBuffer(Vector2.new(0, yCoord), Vector2.new(renderSizeX, rowsToRender), bfr)
end)
actor:BindToMessageParallel("ApplyMetadata", function(metadata: {})
	if type(metadata.accumulation) == "boolean" then
		accumulation = metadata.accumulation
	end
	if type(metadata.maxSamples) == "number" then
		maxSamples = metadata.maxSamples
	end
	
	raySetting = radius.setting(metadata.raySetting)
end)
