-----------------------
-- Spine is 2d skeletal animation system by Esoteric Software
-- http://www.esotericsoftware.com
-- 
-- This flower extension is an unofficial Spine runtime for Moai SDK
-- 
-- @author Vavius
-- @release V1.0
-----------------------

local M = {}

-- imports
local json   = MOAIJsonParser
local flower = require "flower"

local class         = flower.class
local table         = flower.table
local Group         = flower.Group
local DisplayObject = flower.DisplayObject
local Image         = flower.Image
local Resources     = flower.Resources
local DeckMgr       = flower.DeckMgr
local Event         = flower.Event

-- forward declarations
local AttachmentLoader
local AtlasAttachmentLoader
local AnimStateData

-- Classes
local Bone
local Slot
local Attachment
local Skeleton
local Timeline
local Animation
local SpineEvent

local MOAITransformInterface    = MOAITransform.getInterfaceTable()
local MOAIAnimInterface         = MOAIAnim.getInterfaceTable()
local MOAIActionInterface       = MOAIAction.getInterfaceTable()
local MOAIColorInterface        = MOAIColor.getInterfaceTable()

---
-- Internal helper functions
---
local function _wrapAngle(angle)
    while angle > 180 do
        angle = angle - 360
    end
    while angle < -180 do
        angle = angle + 360
    end
    return angle
end

local function genBezierKeys(numkeys, cx1, cy1, cx2, cy2)
    local subdiv_step = 1 / numkeys
    local subdiv_step2 = subdiv_step * subdiv_step
    local subdiv_step3 = subdiv_step2 * subdiv_step
    local pre1 = 3 * subdiv_step
    local pre2 = 3 * subdiv_step2
    local pre4 = 6 * subdiv_step2
    local pre5 = 6 * subdiv_step3
    local tmp1x = -cx1 * 2 + cx2
    local tmp1y = -cy1 * 2 + cy2
    local tmp2x = (cx1 - cx2) * 3 + 1
    local tmp2y = (cy1 - cy2) * 3 + 1
    local curves = {}
    dfx = cx1 * pre1 + tmp1x * pre2 + tmp2x * subdiv_step3
    dfy = cy1 * pre1 + tmp1y * pre2 + tmp2y * subdiv_step3
    ddfx = tmp1x * pre4 + tmp2x * pre5
    ddfy = tmp1y * pre4 + tmp2y * pre5
    dddfx = tmp2x * pre5
    dddfy = tmp2y * pre5

    local res = {}

    local x = dfx
    local y = dfy

    res[1] = {0, 0}
    for i = 2, numkeys-1 do
        res[i] = {x, y}

        dfx = dfx + ddfx
        dfy = dfy + ddfy
        ddfx = ddfx + dddfx
        ddfy = ddfy + dddfy
        x = x + dfx
        y = y + dfy
    end
    res[numkeys] = {1, 1}

    return res
end

local function hexToRGBA(color)
    local a = tonumber(color:sub(7, 8), 16) / 255
    return  a * tonumber(color:sub(1, 2), 16) / 255,
            a * tonumber(color:sub(3, 4), 16) / 255,
            a * tonumber(color:sub(5, 6), 16) / 255,
            a
end

--[[
   table.bininsert( table, value [, comp] )
   
   Inserts a given value through BinaryInsert into the table sorted by [, comp].
   
   If 'comp' is given, then it must be a function that receives
   two table elements, and returns true when the first is less
   than the second, e.g. comp = function(a, b) return a > b end,
   will give a sorted table, with the biggest value on position 1.
   [, comp] behaves as in table.sort(table, value [, comp])
   returns the index where 'value' was inserted
]]--
local fcomp_default = function( a,b ) return a < b end
function table.bininsert(t, value, fcomp)
    -- Initialise compare function
    local fcomp = fcomp or fcomp_default
    --  Initialise numbers
    local iStart,iEnd,iMid,iState = 1,#t,1,0
    -- Get insert position
    while iStart <= iEnd do
        -- calculate middle
        iMid = math.floor( (iStart+iEnd)/2 )
        -- compare
        if fcomp( value,t[iMid] ) then
            iEnd,iState = iMid - 1,0
        else
            iStart,iState = iMid + 1,1
        end
    end
    table.insert( t,(iMid+iState),value )
    return (iMid+iState)
end

--
-- @type Bone
-- 
-- Skeleton bone. Inherited from MOAITransform
Bone = class()
Bone.__index = MOAITransformInterface
Bone.__moai_class = MOAITransform

Bone.ROOT = 'root'

---
-- Constructor. 
-- @param boneData bone parameters table. Fields: (name, x, y, scaleX, scaleY, rotation, length, parent)
-- @param skeleton skeleton object
function Bone:init(boneData, skeleton)
    self._data = boneData
    self.skeleton = skeleton

    self:setParent(skeleton.bones[boneData.parent])
    self:setToBindPose()
end

---
-- Set transform to initial position and rotation
function Bone:setToBindPose()
    local boneData = self._data
    local skeleton = self.skeleton

    if boneData and skeleton then
        self:setLoc((boneData.x or 0) * skeleton.scaleX, (boneData.y or 0) * skeleton.scaleY, 0)
        self:setRot(0, 0, (boneData.rotation or 0) * skeleton.scaleZrot)
        self:setScl(boneData.scaleX or 1, boneData.scaleY or 1, 1)
    end
end

---
-- Attach this bone to new parent
-- @param parent parent bone object reference
function Bone:setParent(parent)
    if parent then
        self:clearAttrLink(MOAITransform.INHERIT_TRANSFORM)
        self:setAttrLink(MOAITransform.INHERIT_TRANSFORM, parent, MOAITransform.TRANSFORM_TRAIT)
    end
end

---
-- @type Slot
-- 
-- DisplayObject that will be bound to bones. 
Slot = class(DisplayObject)

---
-- The constructor. 
-- @param slotData slot parameters table. Fields: (name, bone, color, attachment)
-- @param skeleton skeleton object
function Slot:init(slotData, skeleton)
    DisplayObject.init(self)
    self._data = slotData
    self.skeleton = skeleton

    local bone = skeleton.bones[slotData.bone]
    assert(bone, "Slot " .. slotData.name .. ": bone " .. slotData.bone .. " not found")

    self:setBone(bone)
    self:setToBindPose()
end

---
-- Attach slot to a bone
-- @param bone bone object
function Slot:setBone(bone)
    if bone then
        self:clearAttrLink(MOAITransform.INHERIT_TRANSFORM)
        self:setAttrLink(MOAITransform.INHERIT_TRANSFORM, bone, MOAITransform.TRANSFORM_TRAIT)
    end
end

---
-- Set attachment for a slot
-- @param attachment attachment object
function Slot:setAttachment(attachment)
    if not attachment then
        return
    end

    self:setDeck(attachment:getDeck())
    self:setIndex(attachment:getDeckIndex())
    self:setTexture(attachment:getTexture())

    self:setLoc(attachment:getLoc())
    self:setRot(attachment:getRot())
    self:setScl(attachment:getScl())

    local w, h = self:getSize()
    self:setPiv(w / 2, h / 2)
end

---
-- Reset slot data to initial values
function Slot:setToBindPose()
    local attachment = self._data.attachment
    local color = self._data.color or "ffffffff"

    if attachment then
        self:setAttachment(self.skeleton:getAttachment(attachment, self._data.name))
    end

    self:setColor(hexToRGBA(color))
end

---
-- @type Attachment
-- 
-- Attachment is a visual representation of the slot. 
-- It contains information about deck, deckIndex, texture and own transform. 
-- This transform is used to offset attachment from the bone. 
Attachment = class()
M.Attachment = Attachment

---
-- The constructor.
-- @param attachmentData attachments parameters table. 
-- Fields: (x, y, rotation, width, height, name) 
-- @param attachmentName name of the attachment
-- @param skeleton skeleton object
function Attachment:init(attachmentData, attachmentName, skeleton)
    self._data = attachmentData
    self.skeleton = skeleton
    self.name = attachmentName

    self:initRegionAttachment()
end

function Attachment:initRegionAttachment()
    local skeleton = self.skeleton
    local attachmentData = self._data
    local actualName = attachmentData.name or self.name

    self:setDeck(DeckMgr:getImageDeck(attachmentData.width, attachmentData.height))
    self:setDeckIndex(1)
    self:setTexture(flower.getTexture(self.skeleton.attachmentsFolder .. actualName .. ".png"))
end

function Attachment:setDeck(deck)
    self.deck = deck
end

function Attachment:setDeckIndex(index)
    self.deckIndex = index
end

function Attachment:setTexture(texture)
    self.texture = texture
end

function Attachment:getDeck()
    return self.deck
end

function Attachment:getDeckIndex()
    return self.deckIndex
end

function Attachment:getTexture()
    return self.texture
end

function Attachment:getRot()
    return 0, 0, (self._data.rotation or 0) * self.skeleton.scaleZrot
end

function Attachment:getLoc()
    return (self._data.x or 0) * self.skeleton.scaleX, (self._data.y or 0) * self.skeleton.scaleY, 0
end

function Attachment:getScl()
    return self._data.scaleX or 1, self._data.scaleY or 1, 1
end

---
-- @type Event
-- 
-- Custom events, that can be trigerred from animations. 
-- Add event listeners to the skeleton. Event type is event name in spine. 
SpineEvent = class(Event)
M.SpineEvent = SpineEvent

---
-- Initializes event with spine data
-- @param name event name
-- @param eventData parameters table. Fields: (int, float, string)
function SpineEvent:init(name, eventData)
    Event.init(self, name)

    self.name = name
    self._data = eventData
end

---
-- @type Skeleton
-- 
-- Skeleton object that can be created from Spine json files
-- It is basically a DisplayObject that acts like a container for inner slots
---
Skeleton = class(DisplayObject)
M.Skeleton = Skeleton

Skeleton.DEFAULT_SKIN = 'default'

-----------------------------
-- Create skeleton from json file 
-- 
-- Flower by default have inverted Y axis (0 at top). Also, z rotation growth is clockwise. 
-- Spine uses the folowing coordinate conventions: Y is growing from bottom to top, 
-- rotation direction is counter-clockwise 
-- scaleX, scaleY and scaleZrot can be used for coordinate translation from spine to current project. 
-- 
-- @param path skeleton json path 
-- @param attachmentsFolder (option) path to attachment images
-- @param scaleX (option) x scale of the skeleton. Can be used to scale skeleton for different resolutions
-- @param scaleY (option) x scale of the skeleton
-- @param scaleZrot (option) rotation scale
-----------------------------
function Skeleton:init(path, attachmentsFolder, scaleX, scaleY, scaleZrot)
    DisplayObject.init(self)
    local filepath = Resources.getResourceFilePath(path)
    local jsonData = Resources.readFile(filepath)
    self._data = json.decode(jsonData)

    assert(self._data, "skeleton json could not be loaded: " .. path)

    self.scaleX = scaleX or 1
    self.scaleY = scaleY or -1
    self.scaleZrot = scaleZrot or -1
    self.attachmentsFolder = attachmentsFolder or ""

    self:_initBones()
    self:_initAttachments()
    self:_initSlots()
    self:_initAnimations()
    self:_initEvents()
end

---
-- Initialize bone objects from inner data
function Skeleton:_initBones()
    self.bones = {}

    local bonesTable = self._data.bones
    for i, boneData in ipairs(bonesTable) do
        local bone = Bone(boneData, self)
        self.bones[boneData.name] = bone
    end

    local rootBone = self.bones[Bone.ROOT]
    if rootBone then
        rootBone:clearAttrLink(MOAITransform.INHERIT_TRANSFORM)
        rootBone:setAttrLink(MOAITransform.INHERIT_TRANSFORM, self, MOAITransform.TRANSFORM_TRAIT)
    end
end

---
-- Initialize slot objects from inner data
function Skeleton:_initSlots()
    self.slots = {}

    local slotsTable = self._data.slots
    if not slotsTable then
        return
    end

    for i, slotData in ipairs(slotsTable) do
        local slot = Slot(slotData, self)
        slot:setPriority(i)
        self.slots[slotData.name] = slot
        if self.layer then
            slot:setLayer(self.layer)
        end
    end
end

---
-- Initialize attachment objects from inner data
function Skeleton:_initAttachments()
    self.skins = {}
    self.currentSkin = Skeleton.DEFAULT_SKIN

    local skinsTable = self._data.skins
    if not skinsTable then
        return
    end
    
    for skinName, skinData in pairs(skinsTable) do
        self.skins[skinName] = {}
        for slotName, attachmentsTable in pairs(skinData) do 
            local slotAttachments = {}
            self.skins[skinName][slotName] = slotAttachments
            
            for attachmentName, attachmentData in pairs(attachmentsTable) do
                local attachment = Attachment(attachmentData, attachmentName, self)
                slotAttachments[attachmentName] = attachment
            end
        end
    end
end

---
-- Initialize animation objects from inner data
function Skeleton:_initAnimations()
    self.animations = {}

    local animationsTable = self._data.animations
    if not animationsTable then
        return
    end

    for animName, animData in pairs(animationsTable) do
        self.animations[animName] = Animation(animData, self)
    end
end

---
-- Initialize custom events from inner data
function Skeleton:_initEvents()
    self.events = {}

    local eventsTable = self._data.events
    if not eventsTable then
        return
    end
    
    for eventName, eventData in pairs(eventsTable) do
        self.events[eventName] = SpineEvent(eventName, eventData)
    end
end

---
-- Returns attachment object for slot
-- @param attachmentName name of the attachment
-- @param slotName name of the slot for that attachment
function Skeleton:getAttachment(attachmentName, slotName)
    local curSkinAttachment = self.skins[self.currentSkin][slotName][attachmentName]
    local defaultAttachment = self.skins[Skeleton.DEFAULT_SKIN][slotName][attachmentName]

    return curSkinAttachment or defaultAttachment
end

---
-- Set layer for the skeleton
-- Inserts all child slots props to the given layer
-- @param layer layer
function Skeleton:setLayer(layer)
    if self.layer == layer then
        return
    end

    if self.layer then
        for slotName, slot in pairs(self.slots) do
            if slot.setLayer then
                slot:setLayer(nil)
            else
                self.layer:removeProp(slot)
            end
        end
    end

    self.layer = layer

    if self.layer then
        for slotName, slot in pairs(self.slots) do
            if slot.setLayer then
                slot:setLayer(self.layer)
            else
                self.layer:insertProp(slot)
            end
        end
    end
end

---
-- Set new skin to use
-- @param skinName skin name
function Skeleton:setSkin(skinName)
    local skin = self.skins[skinName]

    for slotName, slot in pairs(self.slots) do
        local attachment = skin[slotName][slot.data.attachment]
        slot:setAttachment(attachment)
    end
    self.currentSkin = skinName
end

---
-- Reset skeleton to initial pose
function Skeleton:setToBindPose()
    for k, bone in pairs(self.bones) do
        bone:setToBindPose()
    end

    for k, slot in pairs(self.slots) do
        slot:setToBindPose()
    end
end

---
-- Play animation
-- @param animationName animation name
function Skeleton:playAnimation(animationName)
    local anim = self.animations[animationName]

    if anim then
        anim:start()
        self.curAnim = animationName
    end
end

---
-- Stop current animation
function Skeleton:stopAnimation()
    if self.curAnim then
        self.animations[self.curAnim]:stop()
    end
    self.curAnim = nil
end


---
-- @type Animation
-- 
-- Animation object. Inherited from MOAIAnim
Animation = class()
Animation.__index = MOAIAnimInterface
Animation.__moai_class = MOAIAnim
M.Animation = Animation

Animation.BEZIER_SUBDIVS = 10

-- Codes for MOAITimer events
Animation.EVENT_ATTACHMENT = 1
Animation.EVENT_CUSTOM = 2

---
-- The constructor
-- 
-- @param animationData animation table. Look spine json specs for format
-- @param skeleton skeleton object
function Animation:init(animationData, skeleton)
    self._data = animationData
    self.skeleton = skeleton

    self.scaleX = skeleton.scaleX
    self.scaleY = skeleton.scaleY
    self.scaleZrot = skeleton.scaleZrot

    local linksFactory = {}
    linksFactory['rotate']        = self.createRotateLinks
    linksFactory['translate']     = self.createTranslateLinks
    linksFactory['scale']         = self.createScaleLinks
    linksFactory['attachment']    = self.createAttachmentLinks
    linksFactory['color']         = self.createColorLinks

    self:reserveLinks(self:countLinks())
    self.nextLinkId = 1
    self.eventKeyframes = {}

    local bonesAnim = animationData['bones']
    if bonesAnim then
        for boneName, timelineData in pairs(bonesAnim) do
            for k, keys in pairs(timelineData) do
                linksFactory[k] (self, keys, skeleton.bones[boneName])
            end
        end
    end

    local slotsAnim = animationData['slots']
    if slotsAnim then
        for slotName, timelineData in pairs(slotsAnim) do
            for k, keys in pairs(timelineData) do
                linksFactory[k] (self, keys, skeleton.slots[slotName])
            end
        end
    end

    if animationData['events'] then
        self:createEventLinks(animationData['events'])
    end

    self:createEventCallbacks()

    self:setMode(MOAITimer.LOOP)
end

function Animation:countLinks()
    local totalLinks = 0
    
    local boneAnimations = self._data['bones']
    if boneAnimations then
        for boneName, timelineData in pairs(boneAnimations) do
            for k, v in pairs(timelineData) do
                if k == 'scale' then
                    totalLinks = totalLinks + 2
                elseif k == 'rotate' then
                    totalLinks = totalLinks + 1
                else
                    totalLinks = totalLinks + 1
                end
            end
        end
    end

    local slotAnimations = self._data["slots"]
    if slotAnimations then        
        for slotName, timelineData in pairs(slotAnimations) do
            for k, v in pairs(timelineData) do
                if k == 'color' then
                    totalLinks = totalLinks + 4
                end
            end
        end
    end

    return totalLinks
end

function Animation:countKeys(keysData)
    totalKeys = 0
    for i, key in ipairs(keysData) do
        if key.curve and type(key.curve) == 'table' then
            totalKeys = totalKeys + Animation.BEZIER_SUBDIVS
        else
            totalKeys = totalKeys + 1
        end
    end

    return totalKeys
end

function Animation:createBezierKeys(curve, bezierData, startIndex, startTime, endTime, startValues, endValues)
    local keys = genBezierKeys(Animation.BEZIER_SUBDIVS + 1, bezierData[1], bezierData[2], bezierData[3], bezierData[4])
    local timeDiff = endTime - startTime

    local valuesDiff = {}
    for i, v in ipairs(startValues) do
        valuesDiff[i] = endValues[i] - startValues[i]
    end

    local args = { }

    for i = 1, #keys - 1 do 
        k = keys[i]
        args[1] = startIndex + i - 1
        args[2] = startTime + k[1] * timeDiff
        for j, v in ipairs(startValues) do
            args[2 + j] = v + k[2] * valuesDiff[j]
        end
        args[#startValues + 3] = MOAIEaseType.LINEAR
        curve:setKey(unpack(args))
    end
end

function Animation:createRotateLinks(keysData, target)
    local m_r = self.scaleZrot

    local curve = MOAIAnimCurve.new()
    curve:reserveKeys(self:countKeys(keysData))

    local angle = (target._data.rotation or 0) * m_r
    local lastAngle = angle
    local bezierIndexOffset = 0

    for i, key in ipairs(keysData) do
        local val = _wrapAngle(angle + key.angle * m_r - lastAngle)
        lastAngle = lastAngle + val
        
        local easeType = key.curve == "stepped" and MOAIEaseType.FLAT or MOAIEaseType.LINEAR
        
        if type(key.curve) == 'table' then
            local nextAngle = _wrapAngle(angle + keysData[i + 1].angle * m_r - lastAngle)
            nextAngle = nextAngle + lastAngle
            self:createBezierKeys(curve, key.curve, i + bezierIndexOffset, key.time, keysData[i + 1].time, {lastAngle}, {nextAngle})
            bezierIndexOffset = bezierIndexOffset + Animation.BEZIER_SUBDIVS - 1

        else
            curve:setKey(i + bezierIndexOffset, key.time, lastAngle, easeType)
        end
    end

    self:setLink(self.nextLinkId, curve, target, MOAITransform.ATTR_Z_ROT)
    self.nextLinkId = self.nextLinkId + 1
end

function Animation:createScaleLinks(keysData, target)
    local curveX = MOAIAnimCurve.new()
    local curveY = MOAIAnimCurve.new()

    local numKeys = self:countKeys(keysData)
    curveX:reserveKeys(numKeys)
    curveY:reserveKeys(numKeys)
    
    local scX, scY = target._data.scaleX or 1, target._data.scaleY or 1
    local bezierIndexOffset = 0

    for i, key in ipairs(keysData) do
        local easeType = key.curve == "stepped" and MOAIEaseType.FLAT or MOAIEaseType.LINEAR
        
        if type(key.curve) == 'table' then
            local nextValX = keysData[i + 1].x * scX
            local nextValY = keysData[i + 1].y * scY
            
            self:createBezierKeys(curveX, key.curve, i + bezierIndexOffset, key.time, keysData[i + 1].time, {scX * key.x}, {nextValX})
            self:createBezierKeys(curveY, key.curve, i + bezierIndexOffset, key.time, keysData[i + 1].time, {scY * key.y}, {nextValY})
            
            bezierIndexOffset = bezierIndexOffset + Animation.BEZIER_SUBDIVS - 1

        else
            curveX:setKey(i + bezierIndexOffset, key.time, scX * key.x, easeType)
            curveY:setKey(i + bezierIndexOffset, key.time, scY * key.y, easeType)
        end
    end

    self:setLink(self.nextLinkId, curveX, target, MOAITransform.ATTR_X_SCL)
    self:setLink(self.nextLinkId + 1, curveY, target, MOAITransform.ATTR_Y_SCL)
    self.nextLinkId = self.nextLinkId + 2
end

function Animation:createTranslateLinks(keysData, target)
    local m_x = self.scaleX
    local m_y = self.scaleY

    local curve = MOAIAnimCurveVec.new()
    curve:reserveKeys(self:countKeys(keysData))

    local x, y = (target._data.x or 0) * m_x, (target._data.y or 0) * m_y
    local bezierIndexOffset = 0

    for i, key in ipairs(keysData) do
        local easeType = key.curve == "stepped" and MOAIEaseType.FLAT or MOAIEaseType.LINEAR
        
        if type(key.curve) == 'table' then
            local curVal = {x + key.x * m_x, y + key.y * m_y, 0}
            local nextVal = {x + keysData[i + 1].x * m_x, y + keysData[i + 1].y * m_y, 0}
            self:createBezierKeys(curve, key.curve, i + bezierIndexOffset, key.time, keysData[i + 1].time, curVal, nextVal)
            bezierIndexOffset = bezierIndexOffset + Animation.BEZIER_SUBDIVS - 1

        else
            curve:setKey(i + bezierIndexOffset, key.time, x + key.x * m_x, y + key.y * m_y, 0, easeType)
        end
    end

    self:setLink(self.nextLinkId, curve, target, MOAITransform.ATTR_TRANSLATE)
    self.nextLinkId = self.nextLinkId + 1
end

function Animation:createColorLinks(keysData, target)
    assert((target.__class == Slot), "Animation: color animation can be applied only to slot objects")

    local curveR = MOAIAnimCurve.new()
    local curveG = MOAIAnimCurve.new()
    local curveB = MOAIAnimCurve.new()
    local curveA = MOAIAnimCurve.new()
    curveR:reserveKeys(self:countKeys(keysData))
    curveG:reserveKeys(self:countKeys(keysData))
    curveB:reserveKeys(self:countKeys(keysData))
    curveA:reserveKeys(self:countKeys(keysData))
    local bezierIndexOffset = 0

    for i, key in ipairs(keysData) do
        local r, g, b, a = hexToRGBA(key.color)
        local easeType = key.curve == "stepped" and MOAIEaseType.FLAT or MOAIEaseType.LINEAR
        
        if type(key.curve) == 'table' then
            local r2, g2, b2, a2 = hexToRGBA(keysData[i + 1].color)
            
            self:createBezierKeys(curveR, key.curve, i + bezierIndexOffset, key.time, keysData[i + 1].time, r, r2)
            self:createBezierKeys(curveG, key.curve, i + bezierIndexOffset, key.time, keysData[i + 1].time, g, g2)
            self:createBezierKeys(curveB, key.curve, i + bezierIndexOffset, key.time, keysData[i + 1].time, b, b2)
            self:createBezierKeys(curveA, key.curve, i + bezierIndexOffset, key.time, keysData[i + 1].time, a, a2)

            bezierIndexOffset = bezierIndexOffset + Animation.BEZIER_SUBDIVS - 1
        else
            curveR:setKey(i + bezierIndexOffset, key.time, r, easeType)
            curveG:setKey(i + bezierIndexOffset, key.time, g, easeType)
            curveB:setKey(i + bezierIndexOffset, key.time, b, easeType)
            curveA:setKey(i + bezierIndexOffset, key.time, a, easeType)
        end
    end

    self:setLink(self.nextLinkId,     curveR, target, MOAIColor.ATTR_R_COL)
    self:setLink(self.nextLinkId + 1, curveG, target, MOAIColor.ATTR_G_COL)
    self:setLink(self.nextLinkId + 2, curveB, target, MOAIColor.ATTR_B_COL)
    self:setLink(self.nextLinkId + 3, curveA, target, MOAIColor.ATTR_A_COL)
    
    self.nextLinkId = self.nextLinkId + 4
end

function Animation:createAttachmentLinks(keysData, target)
    assert((target.__class == Slot), "Animation: attachment animation can be applied only to slot objects")

    local eventKeysTable = self.eventKeyframes
    local comp = function(key1, key2)
        return key1.time < key2.time
    end

    for i, key in ipairs(keysData) do
        key._type = Animation.EVENT_ATTACHMENT
        key._target = target
        table.bininsert(eventKeysTable, key, comp)
    end
end

function Animation:createEventLinks(keysData)
    local eventKeyframes = self.eventKeyframes
    local comp = function(key1, key2)
        return key1.time < key2.time
    end

    for i, key in ipairs(keysData) do
        key._type = Animation.EVENT_CUSTOM
        table.bininsert(eventKeyframes, key, comp)
    end
end

function Animation:createEventCallbacks()
    local eventKeyframes = self.eventKeyframes
    local eventCurve = MOAIAnimCurve.new()

    eventCurve:reserveKeys(#eventKeyframes)
    
    for i, key in ipairs(eventKeyframes) do
        eventCurve:setKey(i, key.time, key._type, MOAIEaseType.FLAT)

        if key._type == Animation.EVENT_ATTACHMENT then
            eventKeyframes[i] = {
                name = key.name,
                target = key._target,
            }

        elseif key._type == Animation.EVENT_CUSTOM then
            eventKeyframes[i] = {
                name = key.name,
                int = key.int,
                float = key.float,
                string = key.string,
            }
        end
    end

    self:setListener(MOAITimer.EVENT_TIMER_KEYFRAME, self.timerEventCallback)
    self:setCurve(eventCurve)
end

function Animation:timerEventCallback(keyframe, timesExecuted, time, value)
    local skeleton = self.skeleton

    if value == Animation.EVENT_ATTACHMENT then
        local attachment = self.eventKeyframes[keyframe]
        local target = attachment.target

        target:setAttachment( skeleton:getAttachment(attachment.name, target._data.name) )

    elseif value == Animation.EVENT_CUSTOM then
        local event = self.eventKeyframes[keyframe]
        local poseEvent = skeleton.events[event.name]
        local eventData = {
            int = event.int or poseEvent.int,
            float = event.float or poseEvent.float,
            string = event.string or poseEvent.string,
        }

        skeleton:dispatchEvent(poseEvent, eventData)
    end
end

return M