-- =====================================================================
-- MATRIX LOGISTICS / server/logistics.lua
-- [K7-2/1] Lojistik botu paketleme kuyruğu (Matrix.Kitchen.PackageBatch
--          köprüsü, /sessizlik radio-silence guard'ı ile).
-- [K7-2/3] Bagaj / Envanter Ameliyatı: F10 Canlı Kadro'da bota atanan
--          karaborsa aracın bagajına trap house deposundan silah/mühimmat
--          asenkron yüklenir, oradan sokaktaki tetikçi ajanlara otonom
--          GiveItem kuryeliği yapılır.
--
-- Tüm depo operasyonları SetTimeout ile asenkron yürür (server thread
-- Wait ile bloklanmaz, 0.00ms resmon doktrini korunur) ve başarısızlıkta
-- tam iade (rollback) yapılır.
-- =====================================================================

Matrix = Matrix or {}
Matrix.Logistics = Matrix.Logistics or {}

local ipairs, pairs, type = ipairs, pairs, type
local math_min = math.min

local Inventory = Config.Core.Inventory

-- botId -> { plate, netId, trapHouseId, ownerId }
Matrix.Logistics.BotVehicles = Matrix.Logistics.BotVehicles or {}

-- ---------------------------------------------------------------------
-- Stash id helpers
-- ---------------------------------------------------------------------
local function trapStashId(trapHouseId)
    return ('%s%s'):format(Config.Logistics.TrapStashPrefix, tostring(trapHouseId))
end

local function trunkStashId(plate)
    return ('%s%s'):format(Config.Logistics.Trunk.StashPrefix, tostring(plate))
end

local function agentInventoryId(agentId)
    return ('dealer_%s'):format(tostring(agentId))
end

local function ensureTrapStash(trapHouseId)
    local id = trapStashId(trapHouseId)
    pcall(function()
        exports[Inventory]:RegisterStash(
            id,
            ('Trap Stash #%s'):format(tostring(trapHouseId)),
            Config.Logistics.TrapStashSlots,
            Config.Logistics.TrapStashMaxWeight,
            false,
            false
        )
    end)
    return id
end

local function ensureTrunkStash(plate)
    local id = trunkStashId(plate)
    pcall(function()
        exports[Inventory]:RegisterStash(
            id,
            ('Bot Trunk [%s]'):format(tostring(plate)),
            Config.Logistics.Trunk.Slots,
            Config.Logistics.Trunk.MaxWeight,
            false,
            false
        )
    end)
    return id
end

-- ---------------------------------------------------------------------
-- Generic inventory move primitives (defensive pcall wrappers, mirrors
-- server/kitchen.lua conventions)
-- ---------------------------------------------------------------------
local function removeFrom(inv, item, count, metadata)
    local ok, removed = pcall(function()
        return exports[Inventory]:RemoveItem(inv, item, count, metadata)
    end)
    return ok and removed
end

local function addTo(inv, item, count, metadata)
    local ok, added = pcall(function()
        return exports[Inventory]:AddItem(inv, item, count, metadata)
    end)
    return ok and added
end

local function listInventory(inv)
    local ok, items = pcall(function()
        return exports[Inventory]:Search(inv, 'slots')
    end)
    if not ok or not items then return {} end
    if items.name then items = { items } end
    return items
end

local function getStashItemCount(inv, item)
    local ok, count = pcall(function()
        return exports[Inventory]:GetItemCount(inv, item)
    end)
    if ok and type(count) == 'number' then return count end
    local total = 0
    for _, slot in ipairs(listInventory(inv)) do
        if slot.name == item then total = total + (slot.count or 0) end
    end
    return total
end

-- ---------------------------------------------------------------------
-- Bot vehicle registry (used by the F10 Canli Kadro menu to know which
-- trunk stash belongs to which bot)
-- ---------------------------------------------------------------------
function Matrix.Logistics.RegisterBotVehicle(botId, plate, netId, trapHouseId, ownerId)
    Matrix.Logistics.BotVehicles[botId] = {
        plate = plate,
        netId = netId,
        trapHouseId = trapHouseId,
        ownerId = ownerId,
    }
    ensureTrunkStash(plate)
    Matrix.Log('LOGISTICS', 'bot %s assigned vehicle plate=%s trap=%s', tostring(botId), tostring(plate), tostring(trapHouseId))
end

function Matrix.Logistics.GetBotVehicle(botId)
    return Matrix.Logistics.BotVehicles[botId]
end

-- ---------------------------------------------------------------------
-- Radio silence guard (cross-file hook into server/market.lua). If the
-- market module or the owner isn't in silence mode, dispatch proceeds.
-- A blocked dispatch IS the "breach attempt" the silence mode exists to
-- catch, so it reports itself back to market.lua to spike static noise
-- and the Bureau's decrypt coefficient.
-- ---------------------------------------------------------------------
function Matrix.Logistics.CanDispatch(ownerId, trapHouseId)
    if not (Matrix.Market and Matrix.Market.IsRadioSilent) then return true end
    local ok, silent = pcall(Matrix.Market.IsRadioSilent, ownerId)
    if ok and silent then
        if Matrix.Market.RegisterSilenceBreach then
            pcall(Matrix.Market.RegisterSilenceBreach, ownerId, trapHouseId)
        end
        return false
    end
    return true
end

-- ---------------------------------------------------------------------
-- [K7-2/1] Paketleme kuyruğu köprüsü
-- ---------------------------------------------------------------------
function Matrix.Logistics.QueuePackagingJob(trapHouseId, botId, ownerId, drugType, grams, callback)
    callback = callback or function() end

    if not Matrix.Logistics.CanDispatch(ownerId, trapHouseId) then
        callback(false, { reason = 'radio_silence' })
        return false
    end

    if not (Matrix.Kitchen and Matrix.Kitchen.PackageBatch) then
        callback(false, { reason = 'kitchen_module_unavailable' })
        return false
    end

    return Matrix.Kitchen.PackageBatch({
        trapHouseId = trapHouseId,
        drugType = drugType,
        grams = grams,
        executorRef = { isBot = true, botId = botId },
    }, callback)
end

-- ---------------------------------------------------------------------
-- [K7-2/3] Bagaj / Envanter Ameliyatı
-- ---------------------------------------------------------------------

-- Reads the trunk stash contents for the F10 menu's "Araç Bagajı /
-- Envanter Ameliyatı" tab.
function Matrix.Logistics.GetTrunkInventory(botId)
    local bot = Matrix.Logistics.BotVehicles[botId]
    if not bot then return {} end
    return listInventory(trunkStashId(bot.plate))
end

-- Moves `items` ({ {name, count, metadata}, ... }) from the trap house's
-- shared stash into the bot's assigned vehicle trunk. Each stack is
-- moved on its own tick (LoadMsPerStack) via Wait(), which yields this
-- call's own coroutine back to the scheduler between stacks instead of
-- blocking the resource (0.00ms resmon doctrine); a big weapons/ammo run
-- never spikes a single frame. Any stack that fails to move is skipped
-- and reported back (partial success is a valid outcome). Runs
-- synchronously from the caller's perspective (safe to call directly
-- from a lib.callback handler, a net event, or a command handler - all
-- of those already execute inside their own FiveM coroutine).
function Matrix.Logistics.LoadTrunk(botId, items)
    local bot = Matrix.Logistics.BotVehicles[botId]
    if not bot then return false, { reason = 'unknown_bot_vehicle' } end

    if not Matrix.Logistics.CanDispatch(bot.ownerId, bot.trapHouseId) then
        return false, { reason = 'radio_silence' }
    end

    local sourceStash = ensureTrapStash(bot.trapHouseId)
    local targetStash = ensureTrunkStash(bot.plate)
    local cfg = Config.Logistics.Trunk
    local moved, failed = {}, {}

    for _, entry in ipairs(items) do
        local available = getStashItemCount(sourceStash, entry.name)
        local count = math_min(entry.count or 0, available)

        if count > 0 and removeFrom(sourceStash, entry.name, count, entry.metadata) then
            if addTo(targetStash, entry.name, count, entry.metadata) then
                moved[#moved + 1] = { name = entry.name, count = count }
            else
                -- Trunk full/rejected: put it back in the trap stash.
                addTo(sourceStash, entry.name, count, entry.metadata)
                failed[#failed + 1] = { name = entry.name, reason = 'trunk_full' }
            end
        else
            failed[#failed + 1] = { name = entry.name, reason = 'insufficient_stock' }
        end

        Wait(cfg.LoadMsPerStack)
    end

    Matrix.Log('LOGISTICS', 'bot %s trunk load complete: %d moved, %d failed', tostring(botId), #moved, #failed)
    return #failed == 0, { moved = moved, failed = failed }
end

-- Autonomous courier delivery: bot carries an item out of its trunk and
-- hands it to a street "tetikçi" agent's inventory (dealer_<agentId>).
-- Same synchronous-from-caller / yielding-internally shape as LoadTrunk.
function Matrix.Logistics.DeliverToAgent(botId, agentId, itemName, count)
    local bot = Matrix.Logistics.BotVehicles[botId]
    if not bot then return false, { reason = 'unknown_bot_vehicle' } end

    if not Matrix.Logistics.CanDispatch(bot.ownerId, bot.trapHouseId) then
        return false, { reason = 'radio_silence' }
    end

    local trunk = ensureTrunkStash(bot.plate)
    local available = getStashItemCount(trunk, itemName)
    count = math_min(count or 0, available)
    if count < 1 then
        return false, { reason = 'insufficient_stock' }
    end

    if not removeFrom(trunk, itemName, count) then
        return false, { reason = 'remove_failed' }
    end

    Wait(Config.Logistics.Trunk.DeliverMsPerItem * count)

    local targetInv = agentInventoryId(agentId)
    if addTo(targetInv, itemName, count) then
        Matrix.Log('LOGISTICS', 'bot %s delivered %dx %s to agent %s', tostring(botId), count, itemName, tostring(agentId))
        return true, { delivered = count }
    end

    -- Agent inventory rejected the drop (full/unknown item): return to trunk.
    addTo(trunk, itemName, count)
    return false, { reason = 'agent_inventory_rejected' }
end

-- ---------------------------------------------------------------------
-- F10 Canlı Kadro callbacks (ox_lib server callbacks; guarded so the
-- module still loads if ox_lib's server callback registry isn't up yet)
-- ---------------------------------------------------------------------
if lib and lib.callback then
    lib.callback.register('matrix:server:logistics:getTrunkInventory', function(source, botId)
        return Matrix.Logistics.GetTrunkInventory(botId)
    end)

    -- lib.callback handlers run inside their own coroutine, so LoadTrunk's
    -- internal Wait()s yield cleanly here without blocking anything else.
    lib.callback.register('matrix:server:logistics:loadTrunk', function(source, botId, items)
        return Matrix.Logistics.LoadTrunk(botId, items)
    end)

    lib.callback.register('matrix:server:logistics:deliverToAgent', function(source, botId, agentId, itemName, count)
        return Matrix.Logistics.DeliverToAgent(botId, agentId, itemName, count)
    end)
end

Matrix.Log('LOGISTICS', 'server/logistics.lua loaded (Faz 2 - Bagaj Ameliyati + Paketleme Koprusu)')
