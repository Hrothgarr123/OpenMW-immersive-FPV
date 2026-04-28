local camera = require('openmw.camera')
local input = require('openmw.input')
local util = require('openmw.util')
local self = require('openmw.self')
local nearby = require('openmw.nearby')
local storage = require('openmw.storage')
local I = require('openmw.interfaces')
local types = require('openmw.types')

local Actor = types.Actor

local active = false
local lastKnownRace = nil
local isInitialized = false

local cachedSpeed = 40
local lastSpeedUpdate = 0
local SPEED_UPDATE_INTERVAL = 0.5
local EYE_HEIGHT = 120  
local FORWARD_OFFSET = 17.0  
local STANDING_COEFFICIENT = 0.08
local WALKING_COEFFICIENT = 4.9
local RUN_COEFFICIENT = 5.1

local RACE_EYE_HEIGHTS = {
    ["Argonian"] = 115,
    ["Breton"] = 120,
    ["Dark Elf"] = 120,
    ["High Elf"] = 130,
    ["Imperial"] = 120,
    ["Khajiit"] = 118,
    ["Nord"] = 128,
    ["Orc"] = 130,
    ["Redguard"] = 124,
    ["Wood Elf"] = 110
}

local FORWARD_OFFSETS = {
    ["Argonian"] = 19.0,
    ["Breton"] = 18.0,
    ["Dark Elf"] = 17.0,
    ["High Elf"] = 17.0,
    ["Imperial"] = 19.0,
    ["Khajiit"] = 19.0,
    ["Nord"] = 21.0,
    ["Orc"] = 19.0,
    ["Redguard"] = 19.0,
    ["Wood Elf"] = 17.0
}

local RUN_Y_OFFSET = 50.0
local RUN_EYE_DROP = 15.0
local WEAP_Y_OFFSET = 15.0
local WEAP_EYE_DROP = 20.0
local SPELL_Y_OFFSET = 15.0  
local SPELL_EYE_DROP = 15.0  

local SENSITIVITY_PROFILES = {
    Vanilla = {
        STANDING = 0.75,
        MOVING = 0.5,
        RUNNING = 0.35,
		WEAPON = 0.35,
		SPELL = 0.35
    },
    Medium = {
        STANDING = 0.5,  
        MOVING = 0.35,
        RUNNING = 0.25,
		WEAPON = 0.25,
		SPELL = 0.25
    },
    Sensitive = {
        STANDING = 0.20,
        MOVING = 0.14,
        RUNNING = 0.18,
		WEAPON = 0.20,
		SPELL = 0.20
    }
}

local lastValidCameraState = {
    yaw = 0,
    pitch = 0,
    position = util.vector3(0, 0, 0)
}

local lastYaw = 0

local stateChangeTimer = 0
local STATE_CONFIRMATION_TIME = 0.1

local TURN_SMOOTHNESS = 8.0
local yawInertia = 0
local pitchInertia = 0

local pendingFPVActivation = false
local activationDelay = 0

local savedDistance = 192
local savedOffsetX = 0
local savedOffsetY = 0
local savedCollision = nil
local savedMode = nil

local smoothedMovementState = "standing"
local confirmationFrames = 0

local PITCH_MAX_STANDING = math.rad(90)
local PITCH_MAX_WALKING = math.rad(90)
local PITCH_MAX_RUNNING = math.rad(70)

local PITCH_MIN = math.rad(-80)
local PITCH_MIN_RUNNING = math.rad(-70)

local PITCH_SENSITIVITY_MULTIPLIERS = {
    standing = { MIN = 1.0, MAX = 1.0 },  
    walking = { MIN = 1.0, MAX = 1.5 },   
    running = {
		MIN = 1.0,
		MAX_UP = 2.3,    
		MAX_DOWN = 3.5    
	},
    weapon_drawn = { MIN = 1.0, MAX = 1.0 }, 
    casting_spell = { MIN = 1.0, MAX = 1.0 }  
}

local PITCH_SENSITIVITY_THRESHOLD_UP = math.rad(30)   
local PITCH_SENSITIVITY_THRESHOLD_DOWN = math.rad(-30) 


local settingsGroup = storage.playerSection('Settings_tt_FPVBody')

local lastPos = nil
local frameSpeed = 0

local lastSyncYaw = 0
local getMovementState = nil

local function getPlayerStanceState()
    local stance = types.Actor.getStance(self)
    local carriedRight = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)

    if stance == types.Actor.STANCE.Weapon and
       carriedRight and
       carriedRight.type == types.Weapon then
        return "weapon_drawn"
    end

    if stance == types.Actor.STANCE.Spell then
        return "casting_spell"
    end

    return "normal"  
end

local function getAdaptiveSensitivity(baseSensitivity, pitch, movementState)

    local multipliers = PITCH_SENSITIVITY_MULTIPLIERS[movementState] or PITCH_SENSITIVITY_MULTIPLIERS.standing

    local minMultiplier = multipliers.MIN
    local maxMultiplier

    if movementState == "running" then
        if pitch > 0 then
            maxMultiplier = multipliers.MAX_UP
        else
            maxMultiplier = multipliers.MAX_DOWN
        end
    else
        maxMultiplier = multipliers.MAX
    end

    if pitch >= PITCH_SENSITIVITY_THRESHOLD_DOWN and pitch <= PITCH_SENSITIVITY_THRESHOLD_UP then
        return baseSensitivity
    end

    local deviation
    if pitch > 0 then
        deviation = pitch - PITCH_SENSITIVITY_THRESHOLD_UP
    else
        deviation = math.abs(pitch) - math.abs(PITCH_SENSITIVITY_THRESHOLD_DOWN)
    end

    local maxDeviation = math.max(
        PITCH_MAX_STANDING - PITCH_SENSITIVITY_THRESHOLD_UP,
        math.abs(PITCH_MIN) - math.abs(PITCH_SENSITIVITY_THRESHOLD_DOWN)
    )

    local normalized = math.min(1.0, deviation / maxDeviation)

    local multiplier = minMultiplier + normalized * (maxMultiplier - minMultiplier)

    return baseSensitivity * multiplier
end


local function getCurrentSensitivity()
    local sensitivityProfile = settingsGroup:get("ChooseSensitivity") or "Vanilla"
    return SENSITIVITY_PROFILES[sensitivityProfile] or SENSITIVITY_PROFILES.Vanilla
end

local function getEyeHeightForRace()
    local race = settingsGroup:get("ChooseRace") or "Dark Elf"
    return RACE_EYE_HEIGHTS[race] or 120
end

local function getForwardOffsetForRace()
    local race = settingsGroup:get("ChooseRace") or "Dark Elf"
    return FORWARD_OFFSETS[race] or 17.0
end

local function updateEyeHeightIfRaceChanged()
    local currentRace = settingsGroup:get("ChooseRace") or "Dark Elf"
    if currentRace ~= lastKnownRace then
        lastKnownRace = currentRace
        EYE_HEIGHT = getEyeHeightForRace()
        FORWARD_OFFSET = getForwardOffsetForRace()
    end
end

local function calculateCameraPosition(pos, yaw, pitch, movementState)
    local currentForwardOffset = getForwardOffsetForRace()
    local forwardOffset = util.vector3(
        math.sin(yaw) * currentForwardOffset,
        math.cos(yaw) * currentForwardOffset,
        0
    )

    local additionalOffset = util.vector3(0, 0, 0)

    if movementState == "running" then
        local effectiveOffset = RUN_Y_OFFSET * math.cos(pitch)
        additionalOffset = util.vector3(
            math.sin(yaw) * effectiveOffset,
            math.cos(yaw) * effectiveOffset,
            -RUN_EYE_DROP
        )
    elseif movementState == "weapon_drawn" then
        local effectiveOffset = WEAP_Y_OFFSET * math.cos(pitch)
        additionalOffset = util.vector3(
            math.sin(yaw) * effectiveOffset,
            math.cos(yaw) * effectiveOffset,
            -WEAP_EYE_DROP
        )
    elseif movementState == "casting_spell" then
        local effectiveOffset = SPELL_Y_OFFSET * math.cos(pitch)
        additionalOffset = util.vector3(
            math.sin(yaw) * effectiveOffset,
            math.cos(yaw) * effectiveOffset,
            -SPELL_EYE_DROP
        )
    end

    local eyePosX = pos.x + forwardOffset.x + additionalOffset.x
    local eyePosY = pos.y + forwardOffset.y + additionalOffset.y
    local eyePosZ = pos.z + EYE_HEIGHT + forwardOffset.z + additionalOffset.z

    return util.vector3(eyePosX, eyePosY, eyePosZ)
end


local function getCurrentSpeed(dt)
    lastSpeedUpdate = lastSpeedUpdate + (dt or 0)
    if lastSpeedUpdate < SPEED_UPDATE_INTERVAL then
        return cachedSpeed
    end

    lastSpeedUpdate = 0
    local actor = self.actor
    if not actor then return cachedSpeed end

    local speedAttribute = actor:getAttribute(Actor.ATTRIBUTE.Speed)
    if speedAttribute and speedAttribute.value then
        cachedSpeed = speedAttribute.value
    end

    return cachedSpeed
end

local function getMovementState(dt)
    print(string.format("DEBUG_MOVEMENT_STATE: dt=%.4f, frameSpeed=%.2f", dt or 0, frameSpeed))

    local currentSpeedValue = getCurrentSpeed(dt)

    local stanceState = getPlayerStanceState()

    if stanceState == "weapon_drawn" then
        print("DEBUG_MOVEMENT_STATE: Weapon drawn, returning 'weapon_drawn'")
        return "weapon_drawn"
    elseif stanceState == "casting_spell" then
        print("DEBUG_MOVEMENT_STATE: Casting spell, returning 'casting_spell'")
        return "casting_spell"
    end

    local standingThreshold = currentSpeedValue * STANDING_COEFFICIENT
    local walkingThreshold = currentSpeedValue * WALKING_COEFFICIENT
    local runThreshold = currentSpeedValue * RUN_COEFFICIENT

    if frameSpeed > runThreshold then
        print("DEBUG_MOVEMENT_STATE: Running (frameSpeed=%.2f > runThreshold=%.2f)", frameSpeed, runThreshold)
        return "running"
    elseif frameSpeed > standingThreshold then
        print("DEBUG_MOVEMENT_STATE: Walking (frameSpeed=%.2f > standingThreshold=%.2f)", frameSpeed, standingThreshold)
        return "walking"
    else
        print("DEBUG_MOVEMENT_STATE: Standing (frameSpeed=%.2f <= standingThreshold=%.2f)", frameSpeed, standingThreshold)
        return "standing"
    end
end

local function saveCameraState()
    lastValidCameraState.yaw = camera.getYaw() or 0
    lastValidCameraState.pitch = camera.getPitch() or 0
    lastValidCameraState.position = self.position or util.vector3(0, 0, 0)
end

local function restoreCameraState()
    if active and camera.getMode() == camera.MODE.Static then
        camera.setYaw(lastValidCameraState.yaw)
        camera.setPitch(lastValidCameraState.pitch)
        camera.setStaticPosition(lastValidCameraState.position)
        print("DEBUG_CAMERA_RESTORED: Camera state restored from last valid position")
    end
end

local function forceUpdateCameraPosition()
    if not active then return end

    local pos = self.position
    if not pos or not pos.x or not pos.y or not pos.z then
        print("ERROR: Invalid self.position during force update, using last valid position")
        pos = lastValidPosition
        if not pos then return end
    end

    local yaw = camera.getYaw() or 0
    local pitch = camera.getPitch() or 0
    local movementState = getMovementState()

    local eyePos = calculateCameraPosition(pos, yaw, pitch, movementState)
    camera.setStaticPosition(eyePos)
    print(string.format("DEBUG_FORCE_CAMERA_UPDATE: Position updated to (%.2f, %.2f, %.2f)", eyePos.x, eyePos.y, eyePos.z))

    saveCameraState()
end

local function syncCharacterWithCamera(cameraYaw, cameraPitch)
    local actor = self.actor
    if not actor then return end

    local currentYaw = actor:getOrientation().yaw or 0

    local maxTurnSpeed = 1.0  -- рад/сек
    local diff = cameraYaw - currentYaw

    diff = math.fmod(diff, 2 * math.pi)
    if diff > math.pi then
        diff = diff - 2 * math.pi
    elseif diff < -math.pi then
        diff = diff + 2 * math.pi
    end

    local turnAmount = math.max(-maxTurnSpeed * dt, math.min(maxTurnSpeed * dt, diff))
    local targetYaw = currentYaw + turnAmount

    actor:setOrientation(targetYaw, 0, 0)

    local maxPitchRad = math.rad(80)
    local minPitchRad = math.rad(-60)
    local limitedPitch = math.max(minPitchRad, math.min(cameraPitch, maxPitchRad))

    local cosYaw = math.cos(cameraYaw)
    local sinYaw = math.sin(cameraYaw)
    local cosPitch = math.cos(limitedPitch)
    local sinPitch = math.sin(limitedPitch)

    local headDirection = util.vector3(
        sinYaw * cosPitch,
        cosYaw * cosPitch,
        sinPitch
    )

    local length = math.sqrt(headDirection.x^2 + headDirection.y^2 + headDirection.z^2)
    if length > 0 then
        headDirection = util.vector3(
            headDirection.x / length,
            headDirection.y / length,
            headDirection.z / length
        )
    else
        headDirection = util.vector3(0, 1, 0)
    end

    local gain = 1.2
    headDirection = util.vector3(
        headDirection.x * gain,
        headDirection.y * gain,
        headDirection.z * gain
    )

    actor:setAnimationVariable("head_tracking_enabled", 0)
    actor:setHeadTracking(headDirection)
    actor:setAnimationVariable("head_tracking_enabled", 1)
end

local function smoothTurn(current, target, dt, smoothness, inertiaVar)
    local diff = target - current

    if math.abs(diff) < 0.001 then
        inertiaVar = 0
    else
        local inertiaFactor = math.exp(-smoothness * dt)
        inertiaVar = inertiaVar * inertiaFactor + diff * (1 - inertiaFactor)
    end

    local newAngle = current + inertiaVar * dt
    return newAngle, inertiaVar
end

local lastValidPosition = nil 

local function updateFrameSpeed(dt)
    local pos = self.position

    if not pos then
        print("WARNING: self.position is nil, using last valid position")
        pos = lastValidPosition
        if not pos then
            frameSpeed = 0
            return
        end
    else
        lastValidPosition = pos
    end

    if not lastPos then
        lastPos = {
            x = pos.x,
            y = pos.y,
            z = pos.z
        }
        frameSpeed = 0
        return
    end

    local dx = pos.x - lastPos.x
    local dy = pos.y - lastPos.y
    local dz = pos.z - lastPos.z

    lastPos = {
        x = pos.x,
        y = pos.y,
        z = pos.z
    }

    if dt < 0.001 then
        dt = 0.001  
        print("WARNING: dt too small, clamped to 0.001")
    end

    local newSpeed = math.sqrt(dx * dx + dy * dy + dz * dz) / dt

    local maxSpeed = 300  
    newSpeed = math.min(newSpeed, maxSpeed)

    if newSpeed < 1.0 then
        frameSpeed = 0
        print("DEBUG_SPEED_RESET: Resetting frameSpeed to 0 due to low newSpeed (newSpeed=%.2f)", newSpeed)
        return  
    end

    local alpha = 1 - math.exp(-5 * dt)

    frameSpeed = frameSpeed * (1 - alpha) + newSpeed * alpha

    frameSpeed = math.min(frameSpeed, maxSpeed)

    if frameSpeed > 1000 or frameSpeed < -1000 then
        print(string.format("WARNING: frameSpeed out of bounds (%.2f), resetting to 0", frameSpeed))
        frameSpeed = 0
    end

    print(string.format("DEBUG_SPEED_UPDATE: dt=%.4f, newSpeed=%.2f, frameSpeed=%.2f", dt, newSpeed, frameSpeed))
end

local function getToggleKey()
    return settingsGroup:get('FPVview') or input.KEY.Z
end

local function enterFPV()
    active = true

    savedDistance = camera.getThirdPersonDistance()
    local curOffset = camera.getFocalPreferredOffset()
    savedOffsetX = curOffset.x
    savedOffsetY = curOffset.y
    savedCollision = camera.getCollisionType()
    savedMode = camera.getMode()

    I.Camera.disableZoom('fpvbody')
    I.Camera.disableModeControl('fpvbody')
    I.Camera.disableStandingPreview('fpvbody')

    camera.setMode(camera.MODE.Static)
    camera.instantTransition()

    saveCameraState()
end

local function exitFPV()
    active = false

    I.Camera.enableZoom('fpvbody')
    I.Camera.enableModeControl('fpvbody')
    I.Camera.enableStandingPreview('fpvbody')

    camera.setMode(camera.MODE.ThirdPerson)
    camera.setPreferredThirdPersonDistance(savedDistance)
    camera.setFocalPreferredOffset(util.vector2(savedOffsetX, savedOffsetY))

    if savedCollision then
        camera.setCollisionType(savedCollision)
    end

    camera.instantTransition()
end

local wasPressed = false
local syncTimer = 0

local function onUpdate(dt)
    if dt == 0 then return end

    updateEyeHeightIfRaceChanged()
    syncTimer = syncTimer + dt

    if syncTimer >= 1.0 then
        syncTimer = 0
    end

    local toggleKey = getToggleKey()
    local pressed = input.isKeyPressed(toggleKey)
    if pressed and not wasPressed then
        if active then
            exitFPV()
        else
            camera.setMode(camera.MODE.FirstPerson)
            camera.instantTransition()
            pendingFPVActivation = true
        end
    end
    wasPressed = pressed

    if pendingFPVActivation then
        activationDelay = activationDelay + dt
        if activationDelay >= 0.1 then
            pendingFPVActivation = false
            activationDelay = 0
            enterFPV()
        end
    end

    if not active then return end
    if camera.getMode() ~= camera.MODE.Static then return end

    local currentYaw = camera.getYaw() or 0
    local yawDiff = math.abs(currentYaw - lastYaw)

    if yawDiff > math.pi - 0.17 then 
        print("WARNING: Detected abnormal camera rotation (" .. yawDiff .. " rad), restoring state")
        restoreCameraState()
        lastYaw = currentYaw  
        return  
    else
        lastYaw = currentYaw
    end

    updateFrameSpeed(dt)
    local movementState = getMovementState(dt)
    print("DEBUG_MOVEMENT_STATE_RESULT: " .. movementState)

    if movementState ~= smoothedMovementState then
        stateChangeTimer = stateChangeTimer + dt
        if stateChangeTimer >= STATE_CONFIRMATION_TIME then
            smoothedMovementState = movementState
            stateChangeTimer = 0
        end
    else
        stateChangeTimer = 0
    end
    movementState = smoothedMovementState

	local currentMaxPitch = PITCH_MAX_STANDING
	local currentMinPitch = PITCH_MIN

	if movementState == "running" then
		currentMaxPitch = PITCH_MAX_RUNNING
		currentMinPitch = PITCH_MIN_RUNNING
	elseif movementState == "weapon_drawn" and frameSpeed > RUN_COEFFICIENT * getCurrentSpeed(0) then
		currentMaxPitch = PITCH_MAX_RUNNING
		currentMinPitch = PITCH_MIN_RUNNING
	elseif movementState == "casting_spell" and frameSpeed > RUN_COEFFICIENT * getCurrentSpeed(0) then
		currentMaxPitch = PITCH_MAX_RUNNING
		currentMinPitch = PITCH_MIN_RUNNING
	elseif movementState == "walking" then
		currentMaxPitch = PITCH_MAX_WALKING
		currentMinPitch = PITCH_MIN  
	elseif movementState == "weapon_drawn" then
		currentMaxPitch = math.rad(80)
		currentMinPitch = PITCH_MIN  
	elseif movementState == "casting_spell" then
		currentMaxPitch = math.rad(75)
		currentMinPitch = PITCH_MIN  
	end


    local pos = self.position
    if not pos or not pos.x or not pos.y or not pos.z then return end

    local yaw = camera.getYaw() or 0
    local pitch = camera.getPitch() or 0

    local eyePos = calculateCameraPosition(pos, yaw, pitch, movementState)
    camera.setStaticPosition(eyePos)

	local currentSensitivity = getCurrentSensitivity()
	local baseSensitivity = currentSensitivity.STANDING

	if movementState == "walking" then
		baseSensitivity = currentSensitivity.MOVING
	elseif movementState == "running" then
		baseSensitivity = currentSensitivity.RUNNING
	elseif movementState == "weapon_drawn" then
		baseSensitivity = currentSensitivity.WEAPON
	elseif movementState == "casting_spell" then
		baseSensitivity = currentSensitivity.SPELL
	end

	local adaptiveSensitivity = getAdaptiveSensitivity(baseSensitivity, pitch, movementState)

    local mouseMoveY = input.getMouseMoveY() or 0
	if math.abs(mouseMoveY) > 0.001 then
		local newPitch = pitch + mouseMoveY * getAdaptiveSensitivity(baseSensitivity, pitch, movementState)
		local updatedPitch, newInertia = smoothTurn(pitch, newPitch, dt, TURN_SMOOTHNESS, pitchInertia)

		updatedPitch = math.max(currentMinPitch, math.min(currentMaxPitch, updatedPitch))

		camera.setPitch(updatedPitch)
		pitchInertia = newInertia
		syncCharacterWithCamera(yaw, updatedPitch)
	else
		pitchInertia = pitchInertia * math.exp(-15 * dt)
		if math.abs(pitchInertia) < 0.0001 then pitchInertia = 0 end
	end



	local mouseMoveX = input.getMouseMoveX() or 0
	if math.abs(mouseMoveX) > 0.001 then
		local yawSensitivity = getAdaptiveSensitivity(baseSensitivity, pitch, movementState)
		local newYaw = yaw + mouseMoveX * yawSensitivity

        local updatedYaw, newInertia = smoothTurn(yaw, newYaw, dt, TURN_SMOOTHNESS, yawInertia)
        camera.setYaw(updatedYaw)
        yawInertia = newInertia
        syncCharacterWithCamera(updatedYaw, pitch)
    else
        yawInertia = yawInertia * math.exp(-15 * dt)
        if math.abs(yawInertia) < 0.0001 then yawInertia = 0 end
    end
    saveCameraState()
end

local function onSave()
    return {
        active = active,
        savedDistance = savedDistance,
        savedOffsetX = savedOffsetX,
        savedOffsetY = savedOffsetY,
        savedCollision = savedCollision
    }
end

local function onLoad(data)
    if data and data.active then
        savedDistance = data.savedDistance or 192
        savedOffsetX = data.savedOffsetX or 0
        savedOffsetY = data.savedOffsetY or 0
        savedCollision = data.savedCollision
        enterFPV()
        camera.setMode(camera.MODE.Static)
        saveCameraState()  
    end

    lastKnownRace = nil
    updateEyeHeightIfRaceChanged()
    FORWARD_OFFSET = getForwardOffsetForRace()
    local initialSensitivity = settingsGroup:get("ChooseSensitivity") or "Vanilla"
    print("DEBUG_LOAD: Initial sensitivity profile set to " .. initialSensitivity)
end

local function onInputAction(id)
    if not active then return end
    if id == input.ACTION.TogglePOV
       or id == input.ACTION.ZoomIn
       or id == input.ACTION.ZoomOut then
        return true  
    end
end

local function onSettingsChanged(key, value)
    if key == "ChooseRace" then
        updateEyeHeightIfRaceChanged()
        FORWARD_OFFSET = getForwardOffsetForRace()

        if active then
            print("DEBUG_SETTINGS: Race changed, forcing camera and character sync")
            forceUpdateCameraPosition()
            local yaw = camera.getYaw() or 0
            local pitch = camera.getPitch() or 0
            syncCharacterWithCamera(yaw, pitch)
        end
    elseif key == "ChooseSensitivity" then
        print("DEBUG_SETTINGS: Camera sensitivity profile changed to " .. (value or "Vanilla"))
        if active then
            forceUpdateCameraPosition()  
            local yaw = camera.getYaw() or 0
            local pitch = camera.getPitch() or 0
            syncCharacterWithCamera(yaw, pitch)
        end
    end
end

if storage.onSettingsChanged then
    storage.onSettingsChanged(onSettingsChanged)
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
        onInputAction = onInputAction,
        onSettingsChanged = onSettingsChanged
    }
}
