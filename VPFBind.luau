--!optimize 2
--!native

--[[
VPFBind v1.0.0 by @GulgPlayer

VPFBind allows you to display parts and models from Workspace in ViewportFrames with the maximum performance

Example usage:
	local VPFBind = require(script.VPFBind)

	local Camera = Instance.new("Camera")
	Camera.Parent = script.Parent
	script.Parent.CurrentCamera = Camera

	VPFBind(script.Parent, { Camera = workspace.CurrentCamera })
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local FLIP_CFRAME = CFrame.new(0, 0, 0, 1, 0, 0, 0, -1, 0, 0, 0, 1)
local SB_CFRAME = FLIP_CFRAME * CFrame.fromOrientation(math.pi, -math.pi / 2, 0)
local SBDN_CFRAME = FLIP_CFRAME * CFrame.fromOrientation(math.pi, math.pi / 2, 0)

local SKYBOX: { [string]: Enum.NormalId } = {
	SkyboxBk = Enum.NormalId.Right,
	SkyboxDn = Enum.NormalId.Bottom,
	SkyboxFt = Enum.NormalId.Left,
	SkyboxLf = Enum.NormalId.Back,
	SkyboxRt = Enum.NormalId.Front,
	SkyboxUp = Enum.NormalId.Top,
}

export type VPFBindOptions = {
	Camera: Camera?,
	WorldModel: ("WorldModel" | "Model")?,
	GCInterval: number?,
	ReplicateHighPriority: { [string]: {string} }?,
	ReplicateLowPriority: { [string]: {string} }?,
	ReplicateChildren: {string}?,
	CharacterFPS: number?,
	HighPriorityFPS: number?,
	LowPriorityFPS: number?,
	Skybox: boolean?,
	SkyboxCelestialBodies: boolean?
}

local function replicateChild(vpfPart: Instance, part: Instance, replicateTypes: {string}, child: Instance, static: boolean?): ()
	local shouldReplicate = false
	for _, childType in replicateTypes do
		if child:IsA(childType) then
			shouldReplicate = true
			break
		end
	end
	if not shouldReplicate then return end

	local vpfChild = Instance.fromExisting(child)
	vpfChild.Parent = vpfPart
	if not static then
		child.Changed:Connect(function(prop)
			(vpfChild :: any)[prop] = (child :: any)[prop]
		end)
	end
	part.ChildRemoved:Connect(function(removedChild)
		if removedChild == child then
			vpfChild:Destroy()
		end
	end)
end

local ReplicateModelChildren = { "Clothing", "Humanoid" }

local function assign(to: { [string]: any }, from: { [string]: any }?): ()
	if from then
		for k, v in from do
			to[k] = v
		end
	end
end

-- Unbind VPF from the Workspace and perform clean-up
local function VPFUnbind(): () end

-- Bind VPF to render a chunk of Workspace with specified camera
local function VPFBind(vpf: ViewportFrame, vpfBindOptions: VPFBindOptions?): typeof(VPFUnbind)
	local opts: any = {
		Camera = nil,
		WorldModel = "Model",
		GCInterval = 30,
		ReplicateHighPriority = { BasePart={ "CFrame" } },
		ReplicateLowPriority = { BasePart={ "Transparency", "LocalTransparencyModifier", "Color", "Size" } },
		ReplicateChildren = { "Decal", "WrapTarget", "DataModelMesh" },
		CharacterFPS = 60,
		HighPriorityFPS = 60,
		LowPriorityFPS = 24,
		Skybox = false,
		SkyboxCelestialBodies = Lighting.Sky.CelestialBodiesShown
	}
	assign(opts, vpfBindOptions)

	local id = `VPF-{HttpService:GenerateGUID(false)}`

	local gcElapsedTime = 0

	local characterSyncElapsedTime = 0
	local highPrioritySyncElapsedTime = 0
	local lowPrioritySyncElapsedTime = 0

	local partsFolder = Instance.new(opts.WorldModel)
	partsFolder.Name = "Workspace"
	partsFolder.Parent = vpf

	local skyboxModel = Instance.new("Model")
	skyboxModel.Name = "Skybox"

	

	local skybox = Instance.new("Part")
	skybox.Name = "Skybox"
	skybox.CFrame = SB_CFRAME
	skybox.Size = Vector3.one * 4096
	skybox.Transparency = 1
	skybox.Parent = skyboxModel

	local skyboxDn = Instance.new("Part")
	skyboxDn.Name = "SkyboxDn"
	skyboxDn.CFrame = SBDN_CFRAME
	skyboxDn.Size = Vector3.one * 4096
	skyboxDn.Transparency = 1
	skyboxDn.Parent = skyboxModel

	for side, face in SKYBOX do
		local decal = Instance.new("Decal")
		decal.Name = side;
		decal.Face = face
		decal.Texture = Lighting.Sky[side]
		decal.Parent = if side == "SkyboxDn" then skyboxDn else skybox
	end

	skyboxModel.Parent = vpf

	local renderSteppedConnection: RBXScriptConnection,
	destroyConnection: RBXScriptConnection,
	descendantRemovingConnection: RBXScriptConnection

	local connections: { [string]: {RBXScriptConnection} } = {}

	local function destroyVPFPart(vpfPart: any): ()
		local partId = vpfPart:GetAttribute("Id")
		if partId and connections[partId] then
			for _, connection in connections[partId] do
				connection:Disconnect()
			end
			connections[partId] = nil
		end
		local workspaceRef = vpfPart:FindFirstChild("WorkspaceRef")
		if workspaceRef and workspaceRef.Value then
			local ref = workspaceRef.Value:FindFirstChild(id)
			if ref then
				ref:Destroy()
			end
		end
		vpfPart:Destroy()
	end

	local function createVPFPart(parent: Instance, part: Instance): Instance
		local success, vpfPart = pcall(function()
			return Instance.fromExisting(part)
		end)
		if not success then
			warn("Failed to create VPF part for:", part:GetFullName())
			return nil
		end
		vpfPart:SetAttribute("Id", HttpService:GenerateGUID())
		local vpf2workspaceRef = Instance.new("ObjectValue")
		vpf2workspaceRef.Name = "WorkspaceRef"
		vpf2workspaceRef.Value = part
		vpf2workspaceRef.Parent = vpfPart
		vpfPart.Parent = parent
		local workspace2vpfRef = Instance.new("ObjectValue")
		workspace2vpfRef.Archivable = false
		workspace2vpfRef.Name = id
		workspace2vpfRef.Value = vpfPart
		workspace2vpfRef.Parent = part
		return vpfPart
	end

	local function render(deltaTime: number): ()
		if not vpf.CurrentCamera then return end

		if opts.Camera then
			vpf.CurrentCamera.CFrame = opts.Camera.CFrame
		end

		local camera: Camera = opts.Camera or vpf.CurrentCamera
		skybox.Position = camera.CFrame.Position
		skyboxDn.Position = camera.CFrame.Position

		gcElapsedTime += deltaTime
		characterSyncElapsedTime += deltaTime
		highPrioritySyncElapsedTime += deltaTime
		lowPrioritySyncElapsedTime += deltaTime

		local syncCharacters = characterSyncElapsedTime >= 1 / opts.CharacterFPS
		local syncHighPriority = highPrioritySyncElapsedTime >= 1 / opts.HighPriorityFPS
		local syncLowPriority = lowPrioritySyncElapsedTime >= 1 / opts.LowPriorityFPS

		if not syncCharacters and not syncHighPriority and not syncLowPriority then
			return
		end

		if syncCharacters then characterSyncElapsedTime -= 1 / opts.CharacterFPS end
		if syncHighPriority then highPrioritySyncElapsedTime -= 1 / opts.HighPriorityFPS end
		if syncLowPriority then lowPrioritySyncElapsedTime -= 1 / opts.LowPriorityFPS end

		local shouldSync = { syncLowPriority, syncHighPriority, syncCharacters }

		local gc = gcElapsedTime >= opts.GCInterval
		if gc then gcElapsedTime -= opts.GCInterval end

		local parts = workspace:GetDescendants()

		if gc then
			for _, vpfPart in partsFolder:GetChildren() do
				if not CollectionService:HasTag(vpfPart, `{id}-GC`) then
					CollectionService:AddTag(vpfPart, `{id}-GC`)
				end
			end
		end

		for _, part in parts do
			if not part:IsA("BasePart") or part:IsA("Terrain") or part.Name == "camPart" then continue end

			local partParent: Instance = partsFolder

			local syncPriority = if CollectionService:HasTag(part, "VPF-HighPriority") then 2 else 1

			-- Get the actual model, traversing through Accessory/Tool if needed
			local model = part.Parent
			local isAccessoryOrTool = model:IsA("Accessory") or model:IsA("Tool")
			if isAccessoryOrTool then
				model = model.Parent
			end

			-- Check if this is a character model
			if model and model:FindFirstChildWhichIsA("Humanoid") then
				local saved: ObjectValue? = model:FindFirstChild(id)
				if saved then
					partParent = saved.Value :: Instance
					-- Remove GC tag from the model
					CollectionService:RemoveTag(partParent, `{id}-GC`)
				else
					-- Create the character model in VPF
					local vpfModel = createVPFPart(partsFolder, model)
					partParent = vpfModel

					-- Replicate model children (Humanoid, Clothing, etc)
					for _, child in model:GetChildren() do
						replicateChild(vpfModel, model, ReplicateModelChildren, child, true)
					end
					model.ChildAdded:Connect(function(child)
						replicateChild(vpfModel, model, ReplicateModelChildren, child, true)
					end)
				end
				syncPriority = 3
			end

			if not shouldSync[syncPriority] then continue end

			local saved: ObjectValue? = part:FindFirstChild(id)
			if saved then
				-- Update existing part
				local vpfPart = saved.Value :: typeof(part)
				for partType, props in opts.ReplicateHighPriority do
					if part:IsA(partType) then
						for _, prop in props do
							(vpfPart :: any)[prop] = (part :: any)[prop]
						end
					end
				end
				CollectionService:RemoveTag(vpfPart, `{id}-GC`)
			else
				-- Create new part
				local vpfPart = createVPFPart(partParent, part)
				if not vpfPart then continue end
				local partConnections = {}

				-- Set up low priority property replication
				for partType, props in opts.ReplicateLowPriority do
					if part:IsA(partType) then
						for _, prop in props do
							table.insert(partConnections, part:GetPropertyChangedSignal(prop):Connect(function()
								(vpfPart :: any)[prop] = (part :: any)[prop]
							end))
						end
					end
				end
				connections[vpfPart:GetAttribute("Id")] = partConnections

				-- Replicate children (Decals, Meshes, etc)
				for _, child in part:GetChildren() do
					replicateChild(vpfPart, part, opts.ReplicateChildren, child)
				end
				part.ChildAdded:Connect(function(child)
					replicateChild(vpfPart, part, opts.ReplicateChildren, child)
				end)
			end
		end

		-- Garbage collection
		if gc then
			for _, vpfPart in CollectionService:GetTagged(`{id}-GC`) do
				if vpfPart:IsA("Model") then
					-- Destroy all BasePart children first
					for _, child in vpfPart:GetChildren() do
						if child:IsA("BasePart") then
							destroyVPFPart(child)
						end
					end
					-- Then destroy the model itself
					destroyVPFPart(vpfPart)
				else
					destroyVPFPart(vpfPart)
				end
				CollectionService:RemoveTag(vpfPart, `{id}-GC`)
			end
		end
	end

	renderSteppedConnection = RunService.RenderStepped:Connect(render)

	descendantRemovingConnection = workspace.DescendantRemoving:Connect(function(descendant)
		local ref = descendant:FindFirstChild(id)
		if ref then
			destroyVPFPart(ref.Value)
		end
	end)

	local function destroy()
		renderSteppedConnection:Disconnect()
		destroyConnection:Disconnect()
		descendantRemovingConnection:Disconnect()
		for _, vpfPart in partsFolder:GetChildren() do
			local workspaceRef = vpfPart:FindFirstChild("WorkspaceRef")
			if workspaceRef and workspaceRef.Value then
				local ref = workspaceRef.Value:FindFirstChild(id)
				if ref then
					ref:Destroy()
				end
			end
		end
		for _, partConnections in connections do
			for _, connection in partConnections do
				connection:Disconnect()
			end
		end
		partsFolder:Destroy()
		
		skyboxModel:Destroy()
	end
	destroyConnection = vpf.Destroying:Connect(destroy)

	return destroy
end

return VPFBind
