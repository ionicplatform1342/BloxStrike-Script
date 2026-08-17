--// OPPOSING TEAM CHAMS + STABLE FAST HEAD LOCK
--// OPTIMIZED CAMERA TRACKING VERSION
--// LARGE FOV + ACQUISITION BUFFER
--// MULTI-TARGET STABILITY
--// HEAD SUPPORTS PART / MESHPART
--// CHARACTER IS NEVER ROTATED
--// LocalScript -> StarterPlayerScripts

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Characters = Workspace:WaitForChild("Characters")

--==================================================
-- SETTINGS
--==================================================

local FOV_RADIUS = 300
local ACQUIRE_RADIUS = 330

-- Higher = faster camera response.
local CAMERA_SPEED = 55

-- Target search interval.
local TARGET_SCAN_TIME = 0.035

-- Visibility checks for the locked target.
local TARGET_VISIBILITY_TIME = 0.025

-- Chams update interval.
local CHAM_REFRESH_TIME = 0.30

-- How long a target can temporarily fail visibility.
local TARGET_TIMEOUT = 0.16

-- New target must be this much closer to center
-- before replacing the current target.
local SWITCH_MARGIN = 30

local RENDER_NAME = "StableHeadLock"

local TEAM_FOLDERS = {
	["Counter-Terrorists"] = true,
	["Terrorists"] = true
}

--==================================================
-- STATE
--==================================================

local DEAD = false

local LockedHead = nil
local LockedCharacter = nil

local LastTargetTime = 0
local LastTargetScan = 0
local LastLockedVisibility = 0

local LockedVisible = false

local MyTeam = nil

local TeamFolders = {}
local CharacterTeamCache = {}

local Connections = {}

local CameraScriptable = false
local SavedCameraType = nil
local SavedCameraSubject = nil

--==================================================
-- FOV GUI
--==================================================

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local OldFOV = PlayerGui:FindFirstChild("AimFOV")

if OldFOV then
	OldFOV:Destroy()
end

local FOVGui = Instance.new("ScreenGui")
FOVGui.Name = "AimFOV"
FOVGui.IgnoreGuiInset = true
FOVGui.ResetOnSpawn = false
FOVGui.DisplayOrder = 999
FOVGui.Parent = PlayerGui

local FOVCircle = Instance.new("Frame")
FOVCircle.Name = "FOVCircle"
FOVCircle.AnchorPoint = Vector2.new(0.5, 0.5)
FOVCircle.Position = UDim2.fromScale(0.5, 0.5)
FOVCircle.Size = UDim2.fromOffset(
	FOV_RADIUS * 2,
	FOV_RADIUS * 2
)
FOVCircle.BackgroundTransparency = 1
FOVCircle.BorderSizePixel = 0
FOVCircle.Parent = FOVGui

local FOVStroke = Instance.new("UIStroke")
FOVStroke.Thickness = 2
FOVStroke.Transparency = 0.05
FOVStroke.Parent = FOVCircle

local FOVCorner = Instance.new("UICorner")
FOVCorner.CornerRadius = UDim.new(1, 0)
FOVCorner.Parent = FOVCircle

--==================================================
-- CAMERA
--==================================================

local function getCamera()
	return Workspace.CurrentCamera
end

local function getCenter(camera)
	local viewport = camera.ViewportSize

	return Vector2.new(
		viewport.X * 0.5,
		viewport.Y * 0.5
	)
end

local function enterCameraControl()
	if CameraScriptable then
		return true
	end

	local camera = getCamera()

	if not camera then
		return false
	end

	SavedCameraType = camera.CameraType
	SavedCameraSubject = camera.CameraSubject

	camera.CameraType = Enum.CameraType.Scriptable

	CameraScriptable = true

	return true
end

local function restoreCamera()
	local camera = getCamera()

	if camera and CameraScriptable then
		local subject = SavedCameraSubject

		if not subject
			or not subject.Parent then

			local character = LocalPlayer.Character

			if character then
				subject =
					character:FindFirstChildOfClass(
						"Humanoid"
					)
			end
		end

		if subject then
			camera.CameraSubject = subject
		end

		camera.CameraType =
			SavedCameraType
			or Enum.CameraType.Custom
	end

	CameraScriptable = false
	SavedCameraType = nil
	SavedCameraSubject = nil
end

--==================================================
-- CAMERA TRACKING
--==================================================

local function trackHead(head, deltaTime)
	local camera = getCamera()

	if not camera
		or not head
		or not head:IsA("BasePart")
		or not head.Parent then

		return false
	end

	if not enterCameraControl() then
		return false
	end

	local cameraPosition = camera.CFrame.Position
	local direction = head.Position - cameraPosition

	if direction.Magnitude <= 0.001 then
		return false
	end

	direction = direction.Unit

	local currentLook = camera.CFrame.LookVector

	local alpha =
		1 - math.exp(
			-CAMERA_SPEED * deltaTime
		)

	alpha = math.clamp(alpha, 0, 1)

	-- Single smoothing stage.
	local newLook =
		currentLook:Lerp(
			direction,
			alpha
		)

	if newLook.Magnitude <= 0.001 then
		return false
	end

	newLook = newLook.Unit

	-- Use the current camera's up vector.
	-- This avoids the instability caused by forcing
	-- Vector3.yAxis when looking almost vertically.
	local up = camera.CFrame.UpVector

	local desired =
		CFrame.lookAt(
			cameraPosition,
			cameraPosition + newLook,
			up
		)

	camera.CFrame = desired

	return true
end

--==================================================
-- TEAM CACHE
--==================================================

local function rebuildTeamFolders()
	table.clear(TeamFolders)
	table.clear(CharacterTeamCache)

	MyTeam = nil

	for _, folder in ipairs(
		Characters:GetChildren()
	) do
		if TEAM_FOLDERS[folder.Name] then
			TeamFolders[folder] = true
		end
	end
end

rebuildTeamFolders()

table.insert(
	Connections,
	Characters.ChildAdded:Connect(
		function(child)

			if DEAD then
				return
			end

			if TEAM_FOLDERS[child.Name] then
				TeamFolders[child] = true

				table.clear(
					CharacterTeamCache
				)

				MyTeam = nil
			end
		end
	)
)

table.insert(
	Connections,
	Characters.ChildRemoved:Connect(
		function(child)

			TeamFolders[child] = nil

			if MyTeam == child then
				MyTeam = nil
			end

			table.clear(
				CharacterTeamCache
			)
		end
	)
)

--==================================================
-- TEAM DETECTION
--==================================================

local function getCharacterTeam(character)
	if not character
		or not character:IsA("Model") then

		return nil
	end

	local cached =
		CharacterTeamCache[character]

	if cached ~= nil then

		if cached
			and cached.Parent then

			return cached
		end

		if cached == false then
			return nil
		end
	end

	for folder in pairs(TeamFolders) do
		if folder.Parent
			and character:IsDescendantOf(folder) then

			CharacterTeamCache[character] =
				folder

			return folder
		end
	end

	CharacterTeamCache[character] = false

	return nil
end

local function getMyTeam()
	local character =
		LocalPlayer.Character

	if not character then
		MyTeam = nil
		return nil
	end

	if MyTeam
		and MyTeam.Parent
		and character:IsDescendantOf(MyTeam) then

		return MyTeam
	end

	MyTeam =
		getCharacterTeam(character)

	return MyTeam
end

local function isAlive(character)
	if not character
		or not character:IsA("Model") then

		return false
	end

	local humanoid =
		character:FindFirstChildOfClass(
			"Humanoid"
		)

	if humanoid then
		return humanoid.Health > 0
	end

	return true
end

local function isEnemy(character)
	if not character
		or not character:IsA("Model")
		or character == LocalPlayer.Character
		or not character:IsDescendantOf(Characters)
		or not isAlive(character) then

		return false
	end

	local myTeam =
		getMyTeam()

	if not myTeam then
		return false
	end

	local enemyTeam =
		getCharacterTeam(character)

	return enemyTeam ~= nil
		and enemyTeam ~= myTeam
end

--==================================================
-- HEAD
--==================================================

local function getHead(character)
	if not character
		or not character:IsA("Model") then

		return nil
	end

	local head =
		character:FindFirstChild("Head")

	if head and head:IsA("BasePart") then
		return head
	end

	for _, child in ipairs(
		character:GetChildren()
	) do

		if child:IsA("MeshPart")
			and child.Name:lower():find("head") then

			return child
		end
	end

	return nil
end

local function getCharacterFromHead(head)
	if not head
		or not head:IsA("BasePart") then

		return nil
	end

	local character =
		head:FindFirstAncestorOfClass("Model")

	if character
		and character:IsDescendantOf(Characters)
		and getHead(character) == head then

		return character
	end

	return nil
end

--==================================================
-- VISIBILITY
--==================================================

local VisibilityParams =
	RaycastParams.new()

VisibilityParams.FilterType =
	Enum.RaycastFilterType.Exclude

VisibilityParams.IgnoreWater = true

local function isVisible(head, character)
	local camera = getCamera()

	if not camera
		or not head
		or not head:IsA("BasePart")
		or not character
		or not character.Parent then

		return false
	end

	local ignore = {
		camera
	}

	if LocalPlayer.Character then
		ignore[#ignore + 1] =
			LocalPlayer.Character
	end

	-- IMPORTANT:
	-- Do NOT exclude the target character.
	-- The ray needs to be allowed to hit the target.
	VisibilityParams.FilterDescendantsInstances =
		ignore

	local origin =
		camera.CFrame.Position

	local direction =
		head.Position - origin

	if direction.Magnitude <= 0.001 then
		return true
	end

	local result =
		Workspace:Raycast(
			origin,
			direction,
			VisibilityParams
		)

	if not result then
		return true
	end

	return result.Instance:IsDescendantOf(
		character
	)
end

--==================================================
-- SCREEN DISTANCE
--==================================================

local function getScreenDistance(camera, head)
	if not camera
		or not head
		or not head.Parent then

		return nil
	end

	local position,
		onScreen =
		camera:WorldToViewportPoint(
			head.Position
		)

	if not onScreen
		or position.Z <= 0 then

		return nil
	end

	local point =
		Vector2.new(
			position.X,
			position.Y
		)

	return (
		point - getCenter(camera)
	).Magnitude
end

--==================================================
-- CHAMS
--==================================================

local function updateCham(character)
	if DEAD
		or not character
		or not character:IsA("Model")
		or character == LocalPlayer.Character then

		return
	end

	local cham =
		character:FindFirstChild(
			"EnemyChams"
		)

	if not isEnemy(character) then

		if cham then
			cham:Destroy()
		end

		return
	end

	if not cham then
		cham = Instance.new("Highlight")

		cham.Name =
			"EnemyChams"

		cham.Adornee =
			character

		cham.DepthMode =
			Enum.HighlightDepthMode.AlwaysOnTop

		cham.FillTransparency = 0.35
		cham.OutlineTransparency = 0

		cham.Parent =
			character
	end

	-- Chams don't need a raycast every refresh.
	-- Keep them stable and cheap.
	cham.FillColor =
		Color3.fromRGB(
			0,
			255,
			70
		)

	cham.OutlineColor =
		Color3.fromRGB(
			120,
			255,
			150
		)

	cham.FillTransparency = 0.20
end

local function updateAllChams()
	if DEAD then
		return
	end

	for folder in pairs(TeamFolders) do

		if folder.Parent then

			for _, character in ipairs(
				folder:GetChildren()
			) do

				if character:IsA("Model") then
					updateCham(character)
				end
			end
		end
	end
end

--==================================================
-- FIND BEST TARGET
--==================================================

local function findBestTarget()
	local camera =
		getCamera()

	if not camera then
		return nil
	end

	local myTeam =
		getMyTeam()

	if not myTeam then
		return nil
	end

	local bestHead = nil
	local bestCharacter = nil

	local bestDistance =
		ACQUIRE_RADIUS

	for folder in pairs(TeamFolders) do

		if folder.Parent
			and folder ~= myTeam then

			for _, character in ipairs(
				folder:GetChildren()
			) do

				if character:IsA("Model")
					and isEnemy(character) then

					local head =
						getHead(character)

					if head then

						local distance =
							getScreenDistance(
								camera,
								head
							)

						if distance
							and distance < bestDistance then

							-- Only raycast candidates
							-- that can actually beat
							-- the current best target.
							if isVisible(
								head,
								character
							) then

								bestDistance =
									distance

								bestHead =
									head

								bestCharacter =
									character
							end
						end
					end
				end
			end
		end
	end

	return bestHead, bestCharacter, bestDistance
end

--==================================================
-- TARGET VALIDATION
--==================================================

local function validateTarget()
	if not LockedHead
		or not LockedCharacter then

		return false, math.huge
	end

	if not LockedHead.Parent
		or not LockedCharacter.Parent then

		return false, math.huge
	end

	if getHead(LockedCharacter)
		~= LockedHead then

		return false, math.huge
	end

	if not isEnemy(LockedCharacter) then
		return false, math.huge
	end

	local camera =
		getCamera()

	if not camera then
		return false, math.huge
	end

	local distance =
		getScreenDistance(
			camera,
			LockedHead
		)

	if not distance
		or distance > ACQUIRE_RADIUS then

		return false, distance or math.huge
	end

	-- Visibility is checked on a timer,
	-- not every render frame.
	local now = os.clock()

	if now - LastLockedVisibility
		>= TARGET_VISIBILITY_TIME then

		LockedVisible =
			isVisible(
				LockedHead,
				LockedCharacter
			)

		LastLockedVisibility =
			now
	end

	return LockedVisible, distance
end

--==================================================
-- TARGET CLEAR
--==================================================

local function clearTarget()
	LockedHead = nil
	LockedCharacter = nil

	LastTargetTime = 0
	LastLockedVisibility = 0
	LockedVisible = false

	restoreCamera()
end

--==================================================
-- MAIN LOOP
--==================================================

pcall(function()
	RunService:UnbindFromRenderStep(
		RENDER_NAME
	)
end)

RunService:BindToRenderStep(
	RENDER_NAME,
	Enum.RenderPriority.Camera.Value + 1,
	function(deltaTime)

		if DEAD then
			return
		end

		local camera =
			getCamera()

		if not camera then
			return
		end

		local now =
			os.clock()

		--==================================================
		-- CURRENT TARGET
		--==================================================

		if LockedHead then

			local valid,
				currentDistance =
				validateTarget()

			if valid then

				LastTargetTime =
					now

				trackHead(
					LockedHead,
					deltaTime
				)

				-- Search for a better target only
				-- on a controlled interval.
				if now - LastTargetScan
					>= TARGET_SCAN_TIME then

					LastTargetScan =
						now

					local possibleHead,
						possibleCharacter,
						possibleDistance =
						findBestTarget()

					if possibleHead
						and possibleHead
							~= LockedHead
						and possibleCharacter
							~= LockedCharacter
						and possibleDistance
							< currentDistance
								- SWITCH_MARGIN then

						LockedHead =
							possibleHead

						LockedCharacter =
							possibleCharacter

						LastTargetTime =
							now

						LastLockedVisibility =
							now

						LockedVisible = true
					end
				end

				return
			end
		end

		--==================================================
		-- TARGET GRACE
		--==================================================

		if LockedHead
			and LockedCharacter
			and now - LastTargetTime
				<= TARGET_TIMEOUT then

			if LockedHead.Parent
				and LockedCharacter.Parent then

				trackHead(
					LockedHead,
					deltaTime
				)

				return
			end
		end

		--==================================================
		-- NEW TARGET SEARCH
		--==================================================

		if now - LastTargetScan
			>= TARGET_SCAN_TIME then

			LastTargetScan =
				now

			local newHead,
				newCharacter =
				findBestTarget()

			if newHead and newCharacter then

				LockedHead =
					newHead

				LockedCharacter =
					newCharacter

				LastTargetTime =
					now

				LastLockedVisibility =
					now

				LockedVisible = true

				trackHead(
					LockedHead,
					deltaTime
				)

				return
			end
		end

		--==================================================
		-- NO TARGET
		--==================================================

		if LockedHead
			and now - LastTargetTime
				> TARGET_TIMEOUT then

			clearTarget()
		end
	end
)

--==================================================
-- CLEANUP
--==================================================

local function killScript()
	if DEAD then
		return
	end

	DEAD = true

	pcall(function()
		RunService:UnbindFromRenderStep(
			RENDER_NAME
		)
	end)

	for _, connection in ipairs(
		Connections
	) do

		pcall(function()
			connection:Disconnect()
		end)
	end

	table.clear(Connections)

	LockedHead = nil
	LockedCharacter = nil

	table.clear(CharacterTeamCache)
	table.clear(TeamFolders)

	restoreCamera()

	for _, descendant in ipairs(
		Characters:GetDescendants()
	) do

		if descendant:IsA("Highlight")
			and descendant.Name
				== "EnemyChams" then

			descendant:Destroy()
		end
	end

	if FOVGui then
		FOVGui:Destroy()
		FOVGui = nil
	end
end

--==================================================
-- H = DISABLE EVERYTHING
--==================================================

table.insert(
	Connections,
	UserInputService.InputBegan:Connect(
		function(input, processed)

			if processed or DEAD then
				return
			end

			if input.KeyCode
				== Enum.KeyCode.H then

				killScript()
			end
		end
	)
)

--==================================================
-- CHARACTER ADDED
--==================================================

table.insert(
	Connections,
	Characters.DescendantAdded:Connect(
		function(instance)

			if DEAD then
				return
			end

			if instance:IsA("Model") then

				CharacterTeamCache[
					instance
				] = nil

				task.defer(function()

					if DEAD
						or not instance.Parent then
						return
					end

					updateCham(instance)
				end)
			end
		end
	)
)

--==================================================
-- CHARACTER REMOVED
--==================================================

table.insert(
	Connections,
	Characters.DescendantRemoving:Connect(
		function(instance)

			if instance:IsA("Model") then

				local cham =
					instance:FindFirstChild(
						"EnemyChams"
					)

				if cham then
					cham:Destroy()
				end

				CharacterTeamCache[
					instance
				] = nil

				if LockedCharacter
					== instance then

					clearTarget()
				end
			end
		end
	)
)

--==================================================
-- RESPAWN
--==================================================

table.insert(
	Connections,
	LocalPlayer.CharacterAdded:Connect(
		function()

			clearTarget()

			table.clear(
				CharacterTeamCache
			)

			MyTeam = nil

			if DEAD then
				return
			end

			task.wait(0.5)

			if DEAD then
				return
			end

			rebuildTeamFolders()
			updateAllChams()
		end
	)
)

--==================================================
-- CHAM REFRESH
--==================================================

task.spawn(function()

	while not DEAD do

		updateAllChams()

		task.wait(
			CHAM_REFRESH_TIME
		)
	end
end)

--==================================================
-- INITIALIZE
--==================================================

updateAllChams()