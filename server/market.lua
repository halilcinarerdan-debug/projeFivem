-- =====================================================================
-- MATRIX MARKET / server/market.lua
-- [K7-2/2] Sokakta Canlı NPC "Keş" Satış Döngüsü - elden teslimat takası,
--          saflık (purity) kontrolü, anında ihbar tetiği, bot'un elinde
--          "tehlikede" bekleyen kirli nakit (eve dönünce kasaya kilitlenir).
-- [K7-2/4] Telsiz Sessizliği (/sessizlik) - aktifken bota yeni rota/emir
--          verilmesi engellenir; ihlal denemesi statik parazit + Büro
--          traceLevel'ını üssel artırır.
--
-- Server tamamen otorite sahibidir: hangi paketin satılacağına, saflık
-- geçip geçmediğine ve ne kadar nakit verileceğine HER ZAMAN server karar
-- verir; client sadece "satış modu açık/kapalı" ve "bir keş geldi"
-- bilgisini taşır (server/../client/hud.lua tarafında NPC yürüyüşü
-- render edilir, ama transfer kararı asla client'a bırakılmaz).
-- =====================================================================

Matrix = Matrix or {}
Matrix.Market = Matrix.Market or {}

local pairs, ipairs, type = pairs, ipairs, type
local math_floor, math_min, math_max = math.floor, math.min, math.max
local os_time = os.time

local Inventory = Config.Core.Inventory

-- dealerKey -> { source, isBot, botId, ownerId, plate, coords, active, heldCash }
local ActiveDealers = {}

-- ownerId -> bool
local RadioSilence = {}
-- ownerId -> { noise = 0..1, breaches = n }
local SilenceState = {}

-- ---------------------------------------------------------------------
-- Inventory helpers (same defensive shape as server/kitchen.lua and
-- server/logistics.lua)
-- ---------------------------------------------------------------------
local function searchSlots(inv, itemName)
    local ok, slots = pcall(function()
        return exports[Inventory]:Search(inv, 'slots', itemName)
    end)
    if not ok or not slots then return {} end
    if slots.name then slots = { slots } end
    return slots
end

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

local function findAnyPackage(inv)
    local packaged = Config.Kitchen.Packaging.PackagedItem
    for _, itemName in pairs(packaged) do
        local slots = searchSlots(inv, itemName)
        if #slots > 0 then return slots[1] end
    end
    return nil
end

local function dealerInventoryId(dealer)
    if dealer.source then return dealer.source end
    if dealer.plate then
        return ('%s%s'):format(Config.Logistics.Trunk.StashPrefix, dealer.plate)
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Radio silence
-- ---------------------------------------------------------------------
function Matrix.Market.IsRadioSilent(ownerId)
    return RadioSilence[ownerId] == true
end

function Matrix.Market.SetRadioSilence(ownerId, active)
    RadioSilence[ownerId] = active and true or nil
    Matrix.Log('MARKET', 'radio silence for %s = %s', tostring(ownerId), tostring(active))
end

-- Called by server/logistics.lua whenever a dispatch was refused because
-- silence was active - i.e. someone tried to route a bot through the
-- silence. Escalates static noise and the Bureau's decrypt coefficient
-- exponentially with each repeated breach.
function Matrix.Market.RegisterSilenceBreach(ownerId, trapHouseId)
    local state = SilenceState[ownerId] or { noise = 0.0, breaches = 0 }
    state.breaches = state.breaches + 1
    state.noise = math_min(Config.Market.RadioSilenceStaticMax, state.noise + Config.Market.RadioSilenceStaticStep)
    SilenceState[ownerId] = state

    local traceBump = Config.Market.RadioSilenceTraceBase * (2 ^ (state.breaches - 1))

    if Matrix.Bureau and Matrix.Bureau.AdvanceDecryption and trapHouseId then
        pcall(Matrix.Bureau.AdvanceDecryption, trapHouseId, traceBump)
    end

    Matrix.Log('MARKET', 'SILENCE BREACH owner=%s noise=%.2f traceBump=%.2f', tostring(ownerId), state.noise, traceBump)
    return state.noise, traceBump
end

local function toggleSilenceForSource(source)
    local ownerId = tostring(source)
    local newState = not Matrix.Market.IsRadioSilent(ownerId)
    Matrix.Market.SetRadioSilence(ownerId, newState)
    TriggerClientEvent('matrix:client:hud:silenceState', source, newState)
end

RegisterNetEvent('matrix:server:market:toggleSilence', function()
    toggleSilenceForSource(source)
end)

RegisterCommand(Config.Market.RadioSilenceCommand, function(source)
    if source == 0 then return end
    toggleSilenceForSource(source)
end, false)

-- ---------------------------------------------------------------------
-- Vault (shared kasa) - dirty cash locks in only once a bot makes it
-- home safely. In-memory ledger with an oxmysql best-effort flush.
-- ---------------------------------------------------------------------
Matrix.Market.Vault = Matrix.Market.Vault or {}

function Matrix.Market.DepositToVault(ownerId, amount)
    if amount <= 0 then return end
    Matrix.Market.Vault[ownerId] = (Matrix.Market.Vault[ownerId] or 0) + amount
    pcall(function()
        exports.oxmysql:insert('INSERT INTO matrix_vault_ledger (owner_id, amount, created_at) VALUES (?, ?, ?)',
            { ownerId, amount, os_time() })
    end)
    Matrix.Log('MARKET', 'vault deposit owner=%s amount=%d total=%d', tostring(ownerId), amount, Matrix.Market.Vault[ownerId])
end

function Matrix.Market.GetVaultBalance(ownerId)
    return Matrix.Market.Vault[ownerId] or 0
end

-- ---------------------------------------------------------------------
-- Dealer lifecycle
-- ---------------------------------------------------------------------
local function dealerKeyForSource(source) return ('src:%d'):format(source) end
local function dealerKeyForBot(botId) return ('bot:%s'):format(tostring(botId)) end

function Matrix.Market.StartDealing(dealerKey, opts)
    ActiveDealers[dealerKey] = {
        source = opts.source,
        isBot = opts.isBot or false,
        botId = opts.botId,
        ownerId = opts.ownerId,
        plate = opts.plate,
        coords = opts.coords,
        trapHouseId = opts.trapHouseId,
        active = true,
        heldCash = 0,
    }
    Matrix.Log('MARKET', 'dealing mode ON for %s', dealerKey)
    return true
end

function Matrix.Market.StopDealing(dealerKey)
    local dealer = ActiveDealers[dealerKey]
    if dealer then dealer.active = false end
    Matrix.Log('MARKET', 'dealing mode OFF for %s', dealerKey)
end

function Matrix.Market.UpdateDealerCoords(dealerKey, coords)
    local dealer = ActiveDealers[dealerKey]
    if dealer then dealer.coords = coords end
end

-- ---------------------------------------------------------------------
-- Sale resolution - fully server authoritative.
-- ---------------------------------------------------------------------
function Matrix.Market.AttemptSale(dealerKey)
    local dealer = ActiveDealers[dealerKey]
    if not dealer or not dealer.active then
        return false, { reason = 'not_dealing' }
    end

    local inv = dealerInventoryId(dealer)
    if not inv then return false, { reason = 'no_inventory' } end

    local slot = findAnyPackage(inv)
    if not slot then return false, { reason = 'no_stock' } end

    local metadata = slot.metadata or {}
    local purity = tonumber(metadata.purity) or 0

    local tampered = false
    if Matrix.Kitchen and Matrix.Kitchen.ComputeIntegrityHash and metadata.checksum then
        local ok, expected = pcall(Matrix.Kitchen.ComputeIntegrityHash, metadata.drugType, purity, metadata.packagedAt, metadata.batchId)
        tampered = ok and expected ~= metadata.checksum
    end

    if tampered or purity < Config.Market.GourmetMinPurity then
        removeFrom(inv, slot.name, 1, metadata)

        if Matrix.Bureau and Matrix.Bureau.OnUnencryptedComms and dealer.coords then
            pcall(Matrix.Bureau.OnUnencryptedComms, dealerKey, dealer.coords)
        end
        Matrix.Log('MARKET', 'REJECTED sale by %s: purity=%.1f tampered=%s -> BUREAU TIP FIRED', dealerKey, purity, tostring(tampered))

        if dealer.source then
            TriggerClientEvent('matrix:client:hud:saleResult', dealer.source, false, { reason = tampered and 'tampered' or 'low_purity', purity = purity })
        end

        return false, { reason = tampered and 'tampered' or 'low_purity', purity = purity, tipped = true }
    end

    if not removeFrom(inv, slot.name, 1, metadata) then
        return false, { reason = 'remove_failed' }
    end

    local clampedPurity = math_max(0, math_min(100, purity))
    local cashAmount = math_floor(Config.Market.MinSaleCash + (Config.Market.MaxSaleCash - Config.Market.MinSaleCash) * (clampedPurity / 100))

    if dealer.isBot then
        dealer.heldCash = dealer.heldCash + cashAmount
    else
        addTo(dealer.source, Config.Core.MoneyItem, cashAmount)
    end

    Matrix.Log('MARKET', 'SALE by %s: purity=%.1f cash=%d (bot=%s)', dealerKey, purity, cashAmount, tostring(dealer.isBot))

    if dealer.source then
        TriggerClientEvent('matrix:client:hud:saleResult', dealer.source, true, { cash = cashAmount, purity = purity })
    end

    return true, { cash = cashAmount, purity = purity }
end

-- ---------------------------------------------------------------------
-- Bot custody: cash carried by a bot is at risk until it gets home.
-- ---------------------------------------------------------------------
function Matrix.Market.OnBotReturnedHome(botId)
    local dealer = ActiveDealers[dealerKeyForBot(botId)]
    if not dealer or dealer.heldCash <= 0 then return 0 end
    local amount = dealer.heldCash
    dealer.heldCash = 0
    Matrix.Market.DepositToVault(dealer.ownerId, amount)
    return amount
end

-- Called from server/forensics.lua when a bot gets busted while holding
-- provisional street cash: the money never reaches the vault.
function Matrix.Market.SeizeBotCash(botId)
    local dealer = ActiveDealers[dealerKeyForBot(botId)]
    if not dealer or dealer.heldCash <= 0 then return 0 end
    local seized = dealer.heldCash
    dealer.heldCash = 0
    Matrix.Log('MARKET', 'bot %s busted holding %d dirty cash - SEIZED, vault deposit cancelled', tostring(botId), seized)
    return seized
end

-- ---------------------------------------------------------------------
-- [K7-2/1 bridge] Headless bot dealing cycle: bots have no client, so
-- their street-corner loop runs entirely server side on a fixed
-- (non-random) interval, exactly mirroring the player-facing cadence
-- in Config.Market.NpcApproachIntervalMs.
-- ---------------------------------------------------------------------
local function botDealingLoop(dealerKey)
    local dealer = ActiveDealers[dealerKey]
    if not dealer or not dealer.active then return end

    Matrix.Market.AttemptSale(dealerKey)

    SetTimeout(Config.Market.NpcApproachIntervalMs, function()
        botDealingLoop(dealerKey)
    end)
end

function Matrix.Market.StartBotDealing(botId, ownerId, trapHouseId, plate, coords)
    local key = dealerKeyForBot(botId)
    Matrix.Market.StartDealing(key, {
        isBot = true,
        botId = botId,
        ownerId = ownerId,
        trapHouseId = trapHouseId,
        plate = plate,
        coords = coords,
    })
    SetTimeout(Config.Market.NpcApproachIntervalMs, function()
        botDealingLoop(key)
    end)
end

function Matrix.Market.StopBotDealing(botId)
    Matrix.Market.StopDealing(dealerKeyForBot(botId))
end

-- ---------------------------------------------------------------------
-- Player-facing events (client/hud.lua drives the visual NPC walk-up;
-- server only ever gets told "mode on/off" and "someone arrived")
-- ---------------------------------------------------------------------
RegisterNetEvent('matrix:server:market:setDealingMode', function(active, coords)
    local source = source
    local key = dealerKeyForSource(source)
    if active then
        Matrix.Market.StartDealing(key, { source = source, ownerId = tostring(source), coords = coords })
    else
        Matrix.Market.StopDealing(key)
    end
end)

RegisterNetEvent('matrix:server:market:updateCoords', function(coords)
    Matrix.Market.UpdateDealerCoords(dealerKeyForSource(source), coords)
end)

RegisterNetEvent('matrix:server:market:attemptSale', function()
    local source = source
    Matrix.Market.AttemptSale(dealerKeyForSource(source))
end)

RegisterCommand(Config.Market.DealingModeCommand, function(source)
    if source == 0 then return end
    local key = dealerKeyForSource(source)
    local isActive = ActiveDealers[key] and ActiveDealers[key].active
    local ped = GetPlayerPed(source)
    local coords = GetEntityCoords(ped)
    if isActive then
        Matrix.Market.StopDealing(key)
    else
        Matrix.Market.StartDealing(key, { source = source, ownerId = tostring(source), coords = coords })
    end
    TriggerClientEvent('matrix:client:hud:dealingModeState', source, not isActive)
end, false)

AddEventHandler('playerDropped', function()
    local source = source
    Matrix.Market.StopDealing(dealerKeyForSource(source))
end)

Matrix.Log('MARKET', 'server/market.lua loaded (Faz 2 - Sokak Satis Dongusu + Sessizlik)')
