-- Connected Discord-GitHub

-- This is essentially For Honor's combat system.
--[[
	CombatClient
	Input, guard mode and presentation. Decides nothing about damage or state,
	it only sends requests to the server and renders replicated attributes.

	Controls (all remappable in ReplicatedStorage.CombatConfig):
		F            draw / sheath the weapon
		R or MMB     toggle guard mode (lock on)
		Tab          cycle lock on target
		mouse move   pick stance while in guard mode
		Z / X / C    force Left / Top / Right stance (1 / 2 / 3 also work for testing purposes, but
		             those are Roblox hotbar keys and can be eaten by the backpack)
		scroll       switch lock on target: up for left, down for right
		Q            sideways dash, side taken from your movement input
		             (guard is DOWN for the whole dash)
		G            grip a downed opponent, then press again to finish them

	A stance asked for mid swing is queued rather than dropped. Its marker shows
	greyed out until the swing ends, then turns white as it goes live.
		LMB          light attack
		RMB          heavy attack, and the parry input when timed against an
		             incoming attack in your stance
		blocking     automatic while the weapon is drawn and your stance matches
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CombatConfig"))
local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")

local StanceHUD = require(script:WaitForChild("StanceHUD"))
local EnemyTags = require(script:WaitForChild("EnemyTags"))
local GuardCamera = require(script:WaitForChild("GuardCamera"))
local DashVisuals = require(script:WaitForChild("DashVisuals"))

local SetStance = Remotes:WaitForChild("SetStance")
local RequestAttack = Remotes:WaitForChild("RequestAttack")
local ToggleWeapon = Remotes:WaitForChild("ToggleWeapon")
local SetLockTarget = Remotes:WaitForChild("SetLockTarget")
local RequestDash = Remotes:WaitForChild("RequestDash")
local RequestGrip = Remotes:WaitForChild("RequestGrip")
local CombatFX = Remotes:WaitForChild("CombatFX")

local A = Config.Attr
local player = Players.LocalPlayer

-- local state
local character: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil

local guarding = false
local stick = Vector2.zero
local guardHeld = false

-- what we've asked for, not what's live -- server owns the real value
local desiredStance = Config.DefaultStance
local lastStanceSend = 0
local stancePendingSince = 0
local lastSwitchAt = 0

local function matches(input: InputObject, binds: { any }): boolean
	for _, bind in ipairs(binds) do
		if typeof(bind) == "EnumItem" then
			if bind.EnumType == Enum.KeyCode then
				if input.KeyCode == bind then return true end
			elseif bind.EnumType == Enum.UserInputType then
				if input.UserInputType == bind then return true end
			end
		end
	end
	return false
end

-- stance selection / reconciliation with the server

local function serverStance(): string
	local s = character and character:GetAttribute(A.Stance)
	return Config.isStance(s) and s or Config.DefaultStance
end

--[[
	Server refuses stance changes mid swing and rate limits them, and a refusal
	doesn't touch the attribute -- so a fire-and-forget request could vanish
	silently and the client would think it switched when it didn't. Learned
	that one the hard way (flicking to a stance that never took, over and over).
]]
local function requestStance(newStance: string)
	if not Config.isStance(newStance) then return end
	if newStance == desiredStance and newStance == serverStance() then return end

	if newStance ~= desiredStance then
		stancePendingSince = os.clock()
	end
	desiredStance = newStance
	-- deliberately NOT setting the white marker here -- white means live
	lastStanceSend = 0 -- go out on the next reconcile without waiting
end

-- committed to a swing, so the guard can't move yet and a request just queues
local function stanceLockedLocally(): boolean
	local s = character and character:GetAttribute(A.State)
	return s == "Active" or s == "Recovery" or s == "Stunned" or s == "Parried"
end

-- pushes the stance request every frame until the server agrees, then gives up
local function reconcileStance()
	local actual = serverStance()
	if actual == desiredStance then
		StanceHUD.setQueued(nil)
		return
	end

	-- asked for but not live yet: show it greyed out until the server adopts it
	StanceHUD.setQueued(desiredStance)

	local t = os.clock()

	-- don't give up mid-swing -- the request is just queued, not lost, and a
	-- swing can easily outlast ConfirmTimeout
	if not stanceLockedLocally() and t - stancePendingSince > Config.Stance.ConfirmTimeout then
		desiredStance = actual
		StanceHUD.setQueued(nil)
		return
	end

	if t - lastStanceSend < Config.Stance.ResendInterval then return end
	lastStanceSend = t
	SetStance:FireServer(desiredStance)
end

-- mouse delta feeds a virtual stick; crossing the deadzone picks a stance
-- and resets it, so every flick is one decision

-- scroll wheel switches target instead of the mouse, since the mouse is
-- already busy being the stance input -- otherwise a fast stance change
-- could get misread as a target switch
local function switchTarget(screenSign: number)
	if not guarding or not GuardCamera.target or not root then return end
	if os.clock() - lastSwitchAt < Config.LockOn.SwitchCooldown then return end

	local nextTarget = GuardCamera.pickInDirection(root, Vector2.new(screenSign, 0))
	if not nextTarget then return end

	lastSwitchAt = os.clock()
	GuardCamera.target = nextTarget
	SetLockTarget:FireServer(nextTarget)
end

local SCROLL_ACTION = "CombatTargetScroll"

local function onScroll(_, state, input)
	-- sunk unconditionally while bound, so the default camera doesn't also
	-- zoom underneath the guard camera
	if state == Enum.UserInputState.Change and input.Position.Z ~= 0 then
		switchTarget(input.Position.Z > 0 and -1 or 1)
	end
	return Enum.ContextActionResult.Sink
end

local function stepStanceStick(dt: number)
	local delta = UserInputService:GetMouseDelta()

	-- only bleeds off while the mouse is resting, otherwise a slow drag never builds up
	if delta.Magnitude < Config.Stance.IdleThreshold then
		stick *= math.exp(-Config.Stance.Decay * dt)
	end

	stick += Vector2.new(delta.X, delta.Y) * Config.Stance.Sensitivity

	if stick.Magnitude > Config.Stance.MaxRadius then
		stick = stick.Unit * Config.Stance.MaxRadius
	end
	if stick.Magnitude < Config.Stance.Deadzone then return end

	-- screen space Y grows downward, so up is -Y
	local angle = math.deg(math.atan2(stick.X, -stick.Y))

	local picked
	if math.abs(angle) <= Config.Stance.TopWedge then
		picked = "Top"
	elseif angle > 0 then
		picked = "Right"
	else
		picked = "Left"
	end

	-- reset even landing back on the same stance, otherwise a reversal has to
	-- unwind the leftover charge first
	stick = Vector2.zero
	requestStance(picked)
end

-- guard mode (lock on)

local function isDrawn(): boolean
	return character ~= nil and character:GetAttribute(A.WeaponDrawn) == true
end

local function exitGuard()
	if not guarding then return end
	guarding = false
	stick = Vector2.zero
	GuardCamera.disable(humanoid)
	ContextActionService:UnbindAction(SCROLL_ACTION)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	StanceHUD.setLocked(false)
	SetLockTarget:FireServer(nil)
end

local function enterGuard(): boolean
	if guarding then return true end
	if not isDrawn() or not root then return false end

	local target = GuardCamera.acquire(root)
	if not target then return false end

	GuardCamera.target = target
	guarding = true
	stick = Vector2.zero
	GuardCamera.enable()
	StanceHUD.setLocked(true)
	ContextActionService:BindAction(SCROLL_ACTION, onScroll, false, Enum.UserInputType.MouseWheel)
	SetLockTarget:FireServer(target)
	return true
end

local function toggleGuard()
	if guarding then
		exitGuard()
	else
		enterGuard()
	end
end

----------------------------------------------------------------------
-- Input
----------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	local K = Config.Keys

	if matches(input, K.Equip) then
		ToggleWeapon:FireServer(nil)

	elseif matches(input, K.Guard) then
		guardHeld = true
		if Config.GuardStyle == "Hold" then
			enterGuard()
		else
			toggleGuard()
		end

	elseif matches(input, K.CycleTarget) then
		if guarding and root then
			local nextTarget = GuardCamera.cycle(root)
			if nextTarget then
				GuardCamera.target = nextTarget
				SetLockTarget:FireServer(nextTarget)
			end
		end

	elseif matches(input, K.Dash) then
		-- side comes from movement input in the character's own frame, so
		-- circling left while locked on still dashes left, not toward the camera
		if humanoid and root then
			local move = humanoid.MoveDirection
			local side = Config.Dash.NeutralDirection
			if move.Magnitude > 0.05 then
				local localMove = root.CFrame:VectorToObjectSpace(move)
				if math.abs(localMove.X) >= Config.Dash.InputThreshold then
					side = localMove.X > 0 and "Right" or "Left"
				end
			end
			RequestDash:FireServer(side)
		end


	elseif matches(input, K.Grip) then
		-- same key grips a downed body and finishes them once you're carrying one
		RequestGrip:FireServer()

	elseif matches(input, K.Light) then
		if isDrawn() then RequestAttack:FireServer("Light") end

	elseif matches(input, K.Heavy) then
		if isDrawn() then RequestAttack:FireServer("Heavy") end

	elseif matches(input, K.StanceLeft) then
		requestStance("Left")
	elseif matches(input, K.StanceTop) then
		requestStance("Top")
	elseif matches(input, K.StanceRight) then
		requestStance("Right")
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if matches(input, Config.Keys.Guard) then
		guardHeld = false
		if Config.GuardStyle == "Hold" then
			exitGuard()
		end
	end
end)

----------------------------------------------------------------------
-- Dash movement
--
-- Client-side, not server, because the owning client's physics writes are
-- the only ones that stick -- a server push on a player character gets
-- overwritten by the owner every frame. Velocity gets reasserted every frame
-- (not applied once) so the Humanoid controller can't brake it away mid-dash.
-- Y is left alone so gravity still works and you can dash off a ledge.
----------------------------------------------------------------------

RequestDash.OnClientEvent:Connect(function(dir: string)
	if not root or not humanoid then return end
	local cfg = Config.Dash
	local sign = (dir == "Right") and 1 or -1
	local finish = os.clock() + cfg.Duration

	task.spawn(function()
		while os.clock() < finish do
			if not root or not root.Parent or not humanoid or humanoid.Health <= 0 then return end
			-- getting hit during the vulnerable startup/tail cancels the dash
			local state = character and character:GetAttribute(A.State)
			if state == "Stunned" or state == "Parried" then return end
			local side = root.CFrame.RightVector * sign
			local flat = Vector3.new(side.X, 0, side.Z)
			if flat.Magnitude > 0.01 then
				flat = flat.Unit
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity =
					Vector3.new(flat.X * cfg.Speed, v.Y, flat.Z * cfg.Speed)
			end
			RunService.Heartbeat:Wait()
		end
	end)
end)

----------------------------------------------------------------------
-- Hit feedback
----------------------------------------------------------------------

local FX_COLORS = {
	Block = Config.UI.Colors.Block,
	Parry = Config.UI.Colors.Parry,
	Hit = Config.UI.Colors.Incoming,
	GotParried = Config.UI.Colors.Parry,
}

local VFXFolder = ReplicatedStorage:FindFirstChild(Config.VFX.Folder)
local SoundFolder = ReplicatedStorage:FindFirstChild(Config.Sound.Folder)

-- fresh Sound per hit instead of reusing one -- two clashes can overlap, and
-- restarting a shared Sound cuts the first one off. Pitch jitter matters more
-- than it sounds like it should; without it every hit is bit-identical and reads as a loop.
local function playSound(slot: string?, position: Vector3?)
	if not slot or not SoundFolder then return end
	local template = SoundFolder:FindFirstChild(slot)
	if not template or template.SoundId == "" then return end

	local holder
	if position then
		holder = Instance.new("Part")
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.Transparency = 1
		holder.Size = Vector3.one
		holder.CFrame = CFrame.new(position)
		holder.Parent = workspace
	else
		holder = SoundService
	end

	local sound = template:Clone()
	local mix = Config.Sound.Mix[slot]
	if mix and mix.PitchRange and mix.PitchRange > 0 then
		sound.PlaybackSpeed = (mix.Pitch or 1) + (math.random() * 2 - 1) * mix.PitchRange
	end
	sound.Parent = holder
	sound:Play()

	sound.Ended:Connect(function()
		if holder ~= SoundService then holder:Destroy() else sound:Destroy() end
	end)
	-- safety net in case Ended never fires (stream failure, moderated asset)
	Debris:AddItem(holder ~= SoundService and holder or sound, 6)
end

-- fires each emitter at its own steady-state count (Rate * Lifetime) instead
-- of a flat number -- a flat Emit makes the faint, many-particle layers
-- vanish while the opaque ones still show up fine. returns how long to keep it alive.
local function burstEmitters(root: Instance): number
	local longest = 0
	for _, e in ipairs(root:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			local avgLife = (e.Lifetime.Min + e.Lifetime.Max) / 2
			e:Emit(math.max(1, math.ceil(e.Rate * avgLife * Config.VFX.BurstMultiplier)))
			longest = math.max(longest, e.Lifetime.Max)
		elseif e:IsA("Beam") or e:IsA("Trail") then
			-- these have no Emit, so they're flashed on and off instead
			e.Enabled = true
			task.delay(0.12, function() e.Enabled = false end)
			longest = math.max(longest, 0.3)
		end
	end
	return longest
end

-- shrinks size, speed AND acceleration together -- size alone leaves the
-- particles travelling their original distance, so it'd read as a thin ring
local function scaleTemplate(template: Instance, scale: number)
	if scale == 1 then return end
	for _, e in ipairs(template:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			local keys = {}
			for _, k in ipairs(e.Size.Keypoints) do
				table.insert(keys, NumberSequenceKeypoint.new(k.Time, k.Value * scale, k.Envelope * scale))
			end
			e.Size = NumberSequence.new(keys)
			e.Speed = NumberRange.new(e.Speed.Min * scale, e.Speed.Max * scale)
			e.Acceleration = e.Acceleration * scale
		end
	end
end

local function normaliseTemplate(template: Instance)
	for _, d in ipairs(template:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			-- burstEmitters is the only thing that should produce particles
			d.Enabled = false
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		end
	end
	if template:IsA("BasePart") then
		template.Anchored = true
		template.CanCollide = false
		template.CanQuery = false
		template.CanTouch = false
	end
end

-- templates are prepared once, so the scaling cost isn't paid per hit
local preparedTemplates: { [string]: Instance } = {}
local function getTemplate(name: string): Instance?
	if preparedTemplates[name] ~= nil then
		return preparedTemplates[name] or nil
	end
	local source = VFXFolder and VFXFolder:FindFirstChild(name)
	if not source then
		preparedTemplates[name] = false
		return nil
	end
	local prepared = source:Clone()
	normaliseTemplate(prepared)
	scaleTemplate(prepared, Config.VFX.Scale[name] or 1)
	preparedTemplates[name] = prepared
	return prepared
end

-- returns true if a template existed and was played
local function playTemplate(kind: string, position: Vector3): boolean
	local name = Config.VFX.Templates[kind]
	if not name or name == "" or not VFXFolder then return false end

	local template = getTemplate(name)
	if not template then return false end

	local clone = template:Clone()
	if clone:IsA("BasePart") then
		clone.CFrame = CFrame.new(position)
	elseif clone:IsA("Model") then
		clone:PivotTo(CFrame.new(position))
	end
	clone.Parent = workspace

	local life = burstEmitters(clone)
	Debris:AddItem(clone, life + Config.VFX.CleanupPad)
	return true
end

local function spark(position: Vector3, color: Color3)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.6, 0.6, 0.6)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.1
	part.Parent = workspace

	TweenService:Create(
		part,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(4.5, 4.5, 4.5), Transparency = 1 }
	):Play()
	Debris:AddItem(part, 0.35)
end

CombatFX.OnClientEvent:Connect(function(fxCharacter: Model, kind: string, dir: string?, position: Vector3?)
	if not fxCharacter then return end

	if position then
		-- art if there is any for this kind, otherwise the built-in spark
		if not playTemplate(kind, position) and FX_COLORS[kind] then
			spark(position, FX_COLORS[kind])
		end
	end

	local slot = Config.SoundForFX[kind]
	if slot then
		-- impacts play at the contact point; equip/unequip play on the character since they carry no position
		local root = fxCharacter:FindFirstChild("HumanoidRootPart")
		playSound(slot, position or (root and root.Position))
	end

	if kind == "Dash" then
		-- pulsed along the path instead of emitted once, so it leaves a trail of puffs
		task.spawn(function()
			local cfg = Config.Dash
			local finish = os.clock() + cfg.Duration
			while os.clock() < finish and fxCharacter.Parent do
				-- bounding box bottom works for both R6 and R15; HipHeight doesn't
				local ok, cf, size = pcall(function()
					return fxCharacter:GetBoundingBox()
				end)
				if not ok then break end
				local feet = Vector3.new(
					cf.Position.X,
					cf.Position.Y - size.Y / 2 + cfg.VFXFootOffset,
					cf.Position.Z
				)
				playTemplate("Dash", feet)
				task.wait(cfg.VFXPulseInterval)
			end
		end)
	end

	if kind == "Swing" then
		-- separate from the hit sound so the whoosh lands on the swing, not the contact
		local atkType = fxCharacter:GetAttribute(A.AttackType)
		local root = fxCharacter:FindFirstChild("HumanoidRootPart")
		playSound(atkType == "Heavy" and "SwingHeavy" or "SwingLight", root and root.Position)
	end

	if dir and Config.isStance(dir) then
		local uiKind = (kind == "Block" and "Block")
			or (kind == "Parry" and "Parry")
			or (kind == "Hit" and "Incoming")
			or nil

		if uiKind then
			if fxCharacter == character then
				StanceHUD.pulse(dir, uiKind)
			else
				EnemyTags.pulse(fxCharacter, dir, uiKind)
			end
		end
	end

	if kind == "NoStamina" and fxCharacter == character then
		StanceHUD.pulse(serverStance(), "Incoming", 0.18)
	end

	-- server only fires "Dodge" when the i-frames actually ate a hit, never on a
	-- plain whiff -- so this is the one place the flash + trail come from
	if kind == "Dodge" then
		DashVisuals.dodge(fxCharacter)
		if fxCharacter == character then
			StanceHUD.pulse(serverStance(), "Block", 0.22)
		end
	end
end)

local function onCharacter(newCharacter: Model)
	exitGuard()

	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid") :: Humanoid
	root = newCharacter:WaitForChild("HumanoidRootPart") :: BasePart

	desiredStance = serverStance()
	stancePendingSince = 0
	lastStanceSend = 0
	stick = Vector2.zero

	-- StanceHUD.bind follows the replicated stance attribute directly
	StanceHUD.bind(newCharacter)

	-- sheathing always drops guard; drawing offers it
	newCharacter:GetAttributeChangedSignal(A.WeaponDrawn):Connect(function()
		if newCharacter:GetAttribute(A.WeaponDrawn) then
			enterGuard()
		else
			exitGuard()
		end
	end)

	humanoid.Died:Connect(exitGuard)
end

RunService.RenderStepped:Connect(function(dt)
	if not character or not character.Parent or not root or not humanoid then return end
	if humanoid.Health <= 0 then
		exitGuard()
		return
	end

	if guarding then
		if not isDrawn() then
			exitGuard()
		elseif not GuardCamera.validate(root) then
			-- target died or ran off, grab the next one or drop guard
			local nextTarget = GuardCamera.acquire(root)
			if nextTarget then
				GuardCamera.target = nextTarget
				SetLockTarget:FireServer(nextTarget)
			else
				exitGuard()
			end
		end
	end

	if guarding then
		-- Roblox resets MouseBehavior on its own, so reassert it each frame
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		UserInputService.MouseIconEnabled = false

		stepStanceStick(dt)
		GuardCamera.step(dt, character, root, humanoid)
	end

	reconcileStance() -- runs in and out of guard mode, since 1/2/3 work either way

	EnemyTags.update(GuardCamera.target)
end)

StanceHUD.init()
EnemyTags.init()

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	onCharacter(player.Character)
end

print("[Combat] CombatClient all good mud")
