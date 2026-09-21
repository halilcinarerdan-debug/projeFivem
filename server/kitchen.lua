-- =====================================================================
-- MATRIX KITCHEN / server/kitchen.lua
-- [K7-2/1] Mutfak Paketleme Odası - Trap house'un kirli masasında ham
-- kütleyi (meth_batch / coke_batch, metadata.purity taşır) kesme
-- ajanlarıyla karıştırıp 10 gramlık kurye paketlerine (meth_bag /
-- coke_brick) dönüştürür. ox_inventory ile tam metadata senkronu,
-- asenkron lib.progressCircle (oyuncu) veya sessiz zamanlayıcı (bot).
--
-- Charge -> Deliver -> Log akışı korunur: ham madde + kesme ajanı ÖNCE
-- depodan düşülür, paket SetTimeout sonunda teslim edilir; iptal olursa
-- (oyuncu progressCircle'ı keserse) tam iade yapılır. Böylece server
-- thread'i hiçbir zaman Wait ile bloklanmaz (0.00ms resmon doktrini).
-- =====================================================================

Matrix = Matrix or {}
Matrix.Kitchen = Matrix.Kitchen or {}

local pairs, ipairs, type = pairs, ipairs, type
local math_floor, math_max, math_min = math.floor, math.max, math.min
local os_time = os.time
local GetPlayerPed = GetPlayerPed
local GetEntityCoords = GetEntityCoords

local Inventory = Config.Core.Inventory

local pendingJobs = {}
local jobSequence = 0

-- ---------------------------------------------------------------------
-- Deterministic integrity hash (no math.random) - reused by
-- server/forensics.lua to detect tampered / hand-edited purity metadata
-- on a drug package.
-- ---------------------------------------------------------------------
function Matrix.Kitchen.ComputeIntegrityHash(drugType, purity, packagedAt, batchId)
    local seed = ('%s|%d|%d|%s'):format(tostring(drugType), math_floor((purity or 0) * 100), packagedAt or 0, tostring(batchId))
    local hash = 5381
    for i = 1, #seed do
        hash = ((hash << 5) + hash + seed:byte(i)) & 0xFFFFFFFF
    end
    return ('%08x'):format(hash)
end

local function trapStashId(trapHouseId)
    return ('%s%s'):format(Config.Logistics.TrapStashPrefix, tostring(trapHouseId))
end

local function ensureTrapStash(trapHouseId)
    local id = trapStashId(trapHouseId)
    local ok = pcall(function()
        exports[Inventory]:RegisterStash(
            id,
            ('Trap Stash #%s'):format(tostring(trapHouseId)),
            Config.Logistics.TrapStashSlots,
            Config.Logistics.TrapStashMaxWeight,
            false,
            false
        )
    end)
    if not ok then
        Matrix.Log('KITCHEN', 'ensureTrapStash: RegisterStash export unavailable/failed for %s (assumed already registered)', id)
    end
    return id
end

local function getCitizenId(source)
    local ok, cid = pcall(function()
        local QBCore = exports[Config.Core.Resource]:GetCoreObject()
        local ply = QBCore.Functions.GetPlayer(source)
        return ply and ply.PlayerData and ply.PlayerData.citizenid
    end)
    if ok and cid then return cid end
    return ('src:%s'):format(tostring(source))
end

local function getTrapHouseCoords(trapHouseId)
    local override = Config.Kitchen.Packaging.RoomCoords and Config.Kitchen.Packaging.RoomCoords[trapHouseId]
    if override then return override end
    local th = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if th and th.coords then return th.coords end
    return nil
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---------------------------------------------------------------------
-- Stash inventory helpers (defensive: ox_inventory API wrapped in pcall,
-- fallback behaviour preserved per Matrix convention).
-- ---------------------------------------------------------------------
local function searchStashSlots(stashId, itemName)
    local ok, slots = pcall(function()
        return exports[Inventory]:Search(stashId, 'slots', itemName)
    end)
    if not ok or not slots then return {} end
    if slots.name then slots = { slots } end
    return slots
end

local function getStashItemCount(stashId, itemName)
    local ok, count = pcall(function()
        return exports[Inventory]:GetItemCount(stashId, itemName)
    end)
    if ok and type(count) == 'number' then return count end
    local total = 0
    for _, slot in ipairs(searchStashSlots(stashId, itemName)) do
        total = total + (slot.count or 0)
    end
    return total
end

local function removeFromStash(stashId, itemName, count, metadata)
    local ok, removed = pcall(function()
        return exports[Inventory]:RemoveItem(stashId, itemName, count, metadata)
    end)
    return ok and removed
end

local function addToStash(stashId, itemName, count, metadata)
    local ok, added = pcall(function()
        return exports[Inventory]:AddItem(stashId, itemName, count, metadata)
    end)
    return ok and added
end

-- Pulls `gramsNeeded` worth of the raw batch item out of the stash,
-- returning success, and the grams-weighted average purity consumed.
local function consumeRawGrams(stashId, rawItem, gramsNeeded)
    local slots = searchStashSlots(stashId, rawItem)
    if #slots == 0 then return false, 0 end

    local remaining = gramsNeeded
    local purityWeighted = 0
    local consumedTotal = 0
    local consumptionPlan = {}

    for _, slot in ipairs(slots) do
        if remaining <= 0 then break end
        local available = slot.count or 0
        local take = math_min(available, remaining)
        if take > 0 then
            local purity = (slot.metadata and slot.metadata.purity) or 0
            consumptionPlan[#consumptionPlan + 1] = { metadata = slot.metadata, count = take }
            purityWeighted = purityWeighted + (purity * take)
            consumedTotal = consumedTotal + take
            remaining = remaining - take
        end
    end

    if remaining > 0 then
        -- Not enough raw mass available; abort without touching the stash.
        return false, 0
    end

    for _, plan in ipairs(consumptionPlan) do
        local ok = removeFromStash(stashId, rawItem, plan.count, plan.metadata)
        if not ok then
            -- Partial failure mid-plan: refund whatever we already pulled.
            for _, refund in ipairs(consumptionPlan) do
                if refund == plan then break end
                addToStash(stashId, rawItem, refund.count, refund.metadata)
            end
            return false, 0
        end
    end

    return true, (consumedTotal > 0) and (purityWeighted / consumedTotal) or 0
end

-- ---------------------------------------------------------------------
-- Core export: Matrix.Kitchen.PackageBatch
-- opts = {
--   trapHouseId, drugType ('meth'|'coke'), grams,
--   source (number, optional - real player driving the progress bar),
--   executorRef (table, optional - { isBot = true, botId = ... }),
-- }
-- callback(ok, info) - info = { packages, purity, jobId } or { reason }
-- ---------------------------------------------------------------------
function Matrix.Kitchen.PackageBatch(opts, callback)
    callback = callback or function() end
    local cfg = Config.Kitchen.Packaging

    local rawItem = cfg.RawItem[opts.drugType]
    local packagedItem = cfg.PackagedItem[opts.drugType]
    if not rawItem or not packagedItem then
        callback(false, { reason = 'invalid_drug_type' })
        return false
    end

    if Matrix.Bureau and Matrix.Bureau.IsLockedDown then
        local ok, locked = pcall(Matrix.Bureau.IsLockedDown, opts.trapHouseId)
        if ok and locked then
            callback(false, { reason = 'bureau_lockdown' })
            return false
        end
    end

    local packageCount = math_floor((opts.grams or 0) / cfg.PackageGrams)
    packageCount = math_min(packageCount, cfg.MaxPackagesPerRun)
    if packageCount < 1 then
        callback(false, { reason = 'insufficient_grams' })
        return false
    end

    local rawNeeded = packageCount * cfg.PackageGrams
    local agentNeeded = packageCount * cfg.CuttingAgentGramsPerPackage

    local stashId = ensureTrapStash(opts.trapHouseId)

    if getStashItemCount(stashId, cfg.CuttingAgentItem) < agentNeeded then
        callback(false, { reason = 'insufficient_cutting_agent' })
        return false
    end

    -- Player path: validate they are physically at the packaging table.
    if opts.source then
        local coords = getTrapHouseCoords(opts.trapHouseId)
        if coords then
            local ped = GetPlayerPed(opts.source)
            local pos = GetEntityCoords(ped)
            if distance(pos, coords) > cfg.RoomRadius then
                callback(false, { reason = 'too_far' })
                return false
            end
        end
    end

    -- Charge: pull raw mass first, then the cutting agent. Refund raw on
    -- agent failure so the two resources move atomically as a pair.
    local rawOk, avgPurity = consumeRawGrams(stashId, rawItem, rawNeeded)
    if not rawOk then
        callback(false, { reason = 'insufficient_raw_mass' })
        return false
    end

    local agentOk = removeFromStash(stashId, cfg.CuttingAgentItem, agentNeeded)
    if not agentOk then
        addToStash(stashId, rawItem, rawNeeded, { purity = avgPurity })
        callback(false, { reason = 'insufficient_cutting_agent' })
        return false
    end

    jobSequence = jobSequence + 1
    local jobId = jobSequence
    local isBot = opts.executorRef and opts.executorRef.isBot
    local finalPurity = math_max(cfg.MinPurityFloor, avgPurity - (cfg.CuttingAgentGramsPerPackage * cfg.PurityDilutionPerCutGram))

    local job = {
        jobId = jobId,
        trapHouseId = opts.trapHouseId,
        stashId = stashId,
        rawItem = rawItem,
        packagedItem = packagedItem,
        rawGrams = rawNeeded,
        agentGrams = agentNeeded,
        avgPurity = avgPurity,
        packageCount = packageCount,
        cancelled = false,
        source = opts.source,
    }
    pendingJobs[jobId] = job

    local function finalize()
        local pending = pendingJobs[jobId]
        pendingJobs[jobId] = nil
        if not pending then return end

        if pending.cancelled then
            addToStash(pending.stashId, pending.rawItem, pending.rawGrams, { purity = pending.avgPurity })
            addToStash(pending.stashId, cfg.CuttingAgentItem, pending.agentGrams)
            if pending.source then
                TriggerClientEvent('matrix:client:kitchen:packagingResult', pending.source, false, { reason = 'cancelled' })
            end
            Matrix.Log('KITCHEN', 'packaging job #%d cancelled and refunded (trap=%s)', jobId, tostring(pending.trapHouseId))
            callback(false, { reason = 'cancelled' })
            return
        end

        local packagedAt = os_time()
        local batchId = ('%s-%d'):format(tostring(pending.trapHouseId), jobId)
        local checksum = Matrix.Kitchen.ComputeIntegrityHash(opts.drugType, finalPurity, packagedAt, batchId)

        local metadata = {
            purity = finalPurity,
            drugType = opts.drugType,
            batchId = batchId,
            packagedAt = packagedAt,
            checksum = checksum,
        }

        local delivered = addToStash(pending.stashId, pending.packagedItem, pending.packageCount, metadata)
        if not delivered then
            -- Inventory full/rejected: refund raw inputs, nothing lost.
            addToStash(pending.stashId, pending.rawItem, pending.rawGrams, { purity = pending.avgPurity })
            addToStash(pending.stashId, cfg.CuttingAgentItem, pending.agentGrams)
            if pending.source then
                TriggerClientEvent('matrix:client:kitchen:packagingResult', pending.source, false, { reason = 'stash_full' })
            end
            callback(false, { reason = 'stash_full' })
            return
        end

        Matrix.Log('KITCHEN', 'trap=%s drugType=%s packages=%d purity=%.1f citizen=%s',
            tostring(pending.trapHouseId), opts.drugType, pending.packageCount, finalPurity,
            pending.source and getCitizenId(pending.source) or (opts.executorRef and opts.executorRef.botId) or 'unknown')

        if pending.source then
            TriggerClientEvent('matrix:client:kitchen:packagingResult', pending.source, true, {
                packages = pending.packageCount,
                purity = finalPurity,
            })
        end

        callback(true, { packages = pending.packageCount, purity = finalPurity, jobId = jobId })
    end

    if opts.source then
        TriggerClientEvent('matrix:client:kitchen:startProgress', opts.source, jobId, cfg.ProgressMs, opts.drugType)
        SetTimeout(cfg.ProgressMs, finalize)
    elseif isBot then
        SetTimeout(cfg.BotProcessMs, finalize)
    else
        SetTimeout(cfg.ProgressMs, finalize)
    end

    return true, jobId
end

function Matrix.Kitchen.CancelPackaging(jobId, source)
    local job = pendingJobs[jobId]
    if not job then return false end
    if job.source and job.source ~= source then return false end
    job.cancelled = true
    return true
end

-- ---------------------------------------------------------------------
-- Player-facing events
-- ---------------------------------------------------------------------
RegisterNetEvent('matrix:server:kitchen:startPackaging', function(trapHouseId, drugType, grams)
    local source = source
    Matrix.Kitchen.PackageBatch({
        trapHouseId = trapHouseId,
        drugType = drugType,
        grams = tonumber(grams) or 0,
        source = source,
    })
end)

RegisterNetEvent('matrix:server:kitchen:cancelPackaging', function(jobId)
    local source = source
    Matrix.Kitchen.CancelPackaging(jobId, source)
end)

-- ---------------------------------------------------------------------
-- Admin / debug command
-- ---------------------------------------------------------------------
RegisterCommand('mutfakpaketle', function(source, args)
    local trapHouseId = args[1]
    local drugType = args[2]
    local grams = tonumber(args[3])
    if not trapHouseId or not drugType or not grams then
        if source ~= 0 then
            TriggerClientEvent('chat:addMessage', source, { args = { 'MATRIX', 'Kullanım: /mutfakpaketle [trapHouseId] [meth|coke] [gram]' } })
        end
        return
    end
    Matrix.Kitchen.PackageBatch({
        trapHouseId = trapHouseId,
        drugType = drugType,
        grams = grams,
        source = source ~= 0 and source or nil,
        executorRef = source == 0 and { isBot = true, botId = 'console' } or nil,
    })
end, false)

Matrix.Log('KITCHEN', 'server/kitchen.lua loaded (Faz 2 - Paketleme Odasi)')
