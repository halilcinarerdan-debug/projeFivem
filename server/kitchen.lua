Matrix.Kitchen = {}

-- Hangi aktivite hangi beceriyi pratikle organik olarak büyütür (RNG yok).
local ACTIVITY_SKILL_MAP = {
    cooking      = 'skill_chemistry',
    distribution = 'skill_logistics',
    cyber_ops    = 'skill_cyber'
}

local function ApplyOrganicSkillGrowth(bot)
    local skillKey = ACTIVITY_SKILL_MAP[bot.state.activity]
    if not skillKey then return end

    local current = bot.psychology[skillKey] or 0.0
    -- Asymptotik öğrenme eğrisi: 1.0'a yaklaştıkça büyüme yavaşlar, tavanı asla aşmaz.
    bot.psychology[skillKey] = Matrix.Clamp(
        current + ((1.0 - current) * Config.Kitchen.SkillGrowthRate),
        0.0, 1.0
    )
end

local function ApplyCortisolDeviation(bot)
    if not bot.state.coords then return end

    local hash = 0
    for i = 1, #bot.dna_id do
        hash = (hash + bot.dna_id:byte(i) + bot.state.elapsed_seconds) % 360
    end

    local angleRad = math.rad(hash)
    local offsetX = math.cos(angleRad) * Config.Kitchen.CortisolDeviationDistance
    local offsetY = math.sin(angleRad) * Config.Kitchen.CortisolDeviationDistance

    bot.state.coords = vector3(
        bot.state.coords.x + offsetX,
        bot.state.coords.y + offsetY,
        bot.state.coords.z
    )

    Matrix.Log('KITCHEN', '[KORTIZOL SAPMASI] Bot #%d lojistik koordinatı %.0fm saptırıldı.', bot.id, Config.Kitchen.CortisolDeviationDistance)
end

function Matrix.Kitchen.ProcessMinuteCycle(bot)
    local workFactor = Config.Kitchen.WorkFactor[bot.state.activity] or Config.Kitchen.WorkFactor.idle

    ApplyOrganicSkillGrowth(bot)

    bot.biology.fatigue_level = Matrix.Clamp(
        bot.biology.fatigue_level + (workFactor * (2.0 - bot.psychology.cognitive_shifter)),
        0.0, 1.0
    )

    if bot.biology.fatigue_level > Config.Kitchen.FatigueWarningThreshold then
        bot.biology.cortisol_level = Matrix.Clamp(bot.biology.cortisol_level + Config.Kitchen.FatigueCortisolBleed, 0.0, 1.0)
    end

    if bot.biology.fatigue_level > Config.Kitchen.FatigueCriticalThreshold then
        if not bot.biology.fatigue_critical_since then
            bot.biology.fatigue_critical_since = Matrix.Now()
        elseif not bot.biology.burned_this_episode
            and (Matrix.Now() - bot.biology.fatigue_critical_since) >= Config.Kitchen.FatigueCriticalDurationSeconds then
            bot.psychology.resilience = Matrix.Clamp(bot.psychology.resilience - Config.Kitchen.BurnoutResilienceLoss, 0.0, 1.0)
            bot.biology.base_cortisol_recovery_rate = math.max(
                bot.biology.base_cortisol_recovery_rate * (1.0 - Config.Kitchen.BurnoutRecoveryRatePenalty),
                Config.Kitchen.BurnoutRecoveryRateFloor
            )
            bot.biology.burned_this_episode = true
            Matrix.Log(
                'KITCHEN',
                '[TÜKENMİŞLİK] Bot #%d 60dk kritik yorgunluk eşiğini aştı. Direnç -%.2f, kortizol toparlanma oranı sabote edildi (%.4f).',
                bot.id, Config.Kitchen.BurnoutResilienceLoss, bot.biology.base_cortisol_recovery_rate
            )
        end
    else
        bot.biology.fatigue_critical_since = nil
        bot.biology.burned_this_episode = false
    end

    bot.biology.cortisol_level = Matrix.Clamp(
        bot.biology.cortisol_level - (bot.biology.base_cortisol_recovery_rate * bot.psychology.resilience),
        0.0, 1.0
    )

    if bot.biology.cortisol_level > Config.Kitchen.CortisolDeviationThreshold then
        ApplyCortisolDeviation(bot)
    end

    Matrix.PersistBot(bot)
end

function Matrix.Kitchen.ProcessHourCycle(bot)
    if bot.biology.addiction_level > 0.0 then
        bot.biology.withdrawal_index = math.min(
            1.0, bot.biology.withdrawal_index + (bot.biology.addiction_level * Config.Kitchen.WithdrawalGainPerAddictionPoint)
        )
        Matrix.Log('KITCHEN', 'Bot #%d yoksunluk endeksi: %.2f', bot.id, bot.biology.withdrawal_index)
    end
end

function Matrix.Kitchen.GetEffectiveSkill(actor, skillKey)
    local baseSkill = (actor.psychology and actor.psychology[skillKey]) or 0.0
    local withdrawalIndex = (actor.biology and actor.biology.withdrawal_index) or 0.0

    if withdrawalIndex > Config.Kitchen.WithdrawalSkillPenaltyThreshold then
        return baseSkill * Config.Kitchen.WithdrawalSkillPenaltyMultiplier
    end

    return baseSkill
end

function Matrix.Kitchen.AdjustCortisol(actorRef, spikeType)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor or not actor.biology then return end

    local delta = 0.0
    if spikeType == 'gunshot' then
        delta = Config.Kitchen.CortisolSpike.Gunshot
    elseif spikeType == 'bureau_vehicle' then
        delta = Config.Kitchen.CortisolSpike.BureauVehicle
    end

    actor.biology.cortisol_level = Matrix.Clamp(actor.biology.cortisol_level + delta, 0.0, 1.0)
    Matrix.Log('KITCHEN', 'Kortizol sıçraması (%s): %s -> %.2f', spikeType, actor.dna_id, actor.biology.cortisol_level)
end

-- Bot İçi İhbar: bağımlı bir bot mutfaktan çalarken, aynı trap house'ta
-- duran ("temiz", addiction_level<=0) en düşük ID'li bot merkeze telsiz
-- cızırtısıyla iç ihbar geçer (deterministik seçim, RNG yok).
local function FindCleanBotAtTrapHouse(trapHouseId, excludeBotId)
    local foundId, foundBot = nil, nil
    for id, b in pairs(Matrix.Bots) do
        if id ~= excludeBotId and b.status == 'active' and b.state.trap_house_id == trapHouseId
            and (b.biology.addiction_level or 0.0) <= 0.0 then
            if not foundId or id < foundId then
                foundId, foundBot = id, b
            end
        end
    end
    return foundId, foundBot
end

local function BroadcastCleanBotTip(trapHouseId, thiefDnaId, excludeBotId)
    local cleanId, cleanBot = FindCleanBotAtTrapHouse(trapHouseId, excludeBotId)
    if not cleanBot then return end

    Matrix.Log('KITCHEN', '[BZZZT] Merkez, %s\'in elleri titriyordu, tartı sapmalı. (Bildiren: Bot #%d %s)',
        thiefDnaId, cleanId, cleanBot.name)
end

function Matrix.Kitchen.ProcessCook(actorRef, trapHouseId, rawWeight, rawPurity, agentWeight)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end

    local skillChemistry = Matrix.Kitchen.GetEffectiveSkill(actor, 'skill_chemistry')
    local fatigueLevel = (actor.biology and actor.biology.fatigue_level) or 0.0
    local cortisolLevel = (actor.biology and actor.biology.cortisol_level) or 0.0
    local withdrawalIndex = (actor.biology and actor.biology.withdrawal_index) or 0.0
    local addictionLevel = (actor.biology and actor.biology.addiction_level) or 0.0

    local theoreticalPurity = (rawWeight * rawPurity) / (rawWeight + agentWeight)
    local errorCoefficient = ((1.0 - skillChemistry) * 0.5) + (fatigueLevel * 0.3) + (cortisolLevel * 0.2)
    local outputPurity = theoreticalPurity * (1.0 - errorCoefficient)
    local wasteVolume = agentWeight * errorCoefficient * 0.2

    local theftAmount = 0.0
    if withdrawalIndex >= Config.Kitchen.TheftWithdrawalThreshold then
        theftAmount = addictionLevel * Config.Kitchen.TheftGramsPerAddictionPoint
        Matrix.Log(
            'KITCHEN',
            '[SİSTEMİK ANOMALİ: LABORATUVAR HASSAS TARTI SAPMASI] %s, %.1fg mal çaldı.',
            actor.dna_id, theftAmount
        )
        BroadcastCleanBotTip(trapHouseId, actor.dna_id, actor.id)
    end

    local finalWeight = math.max((rawWeight + agentWeight) - wasteVolume - theftAmount, 0.0)
    local rivalInfiltration = outputPurity < Config.Kitchen.RivalInfiltrationPurityThreshold

    MySQL.query.await([[
        INSERT INTO matrix_kitchen_batches (
            trap_house_id, actor_identifier, raw_weight, raw_purity, agent_weight,
            theoretical_purity, error_coefficient, output_purity, waste_volume,
            theft_amount, rival_infiltration_triggered, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]], {
        trapHouseId, actor.dna_id, rawWeight, rawPurity, agentWeight,
        theoreticalPurity, errorCoefficient, outputPurity, wasteVolume,
        theftAmount, rivalInfiltration and 1 or 0
    })

    if rivalInfiltration then
        Matrix.Log('KITCHEN', '[RAKİP SIZMA TETİKLEYİCİSİ] Trap house #%d saflık %.2f ile kritik eşiğin altında.', trapHouseId, outputPurity)
    end

    return {
        theoretical_purity = theoreticalPurity,
        error_coefficient = errorCoefficient,
        output_purity = outputPurity,
        waste_volume = wasteVolume,
        theft_amount = theftAmount,
        final_weight = finalWeight,
        rival_infiltration = rivalInfiltration
    }
end

function Matrix.Kitchen.ComputeSnitchIndex(bot)
    return (bot.psychology.snitch_tendency * 0.3)
        + (bot.psychology.economic_pressure * 0.3)
        + (bot.biology.cortisol_level * 0.2)
        + (bot.psychology.fear_factor * 0.2)
        - (bot.psychology.resilience * 0.2)
end

function Matrix.Kitchen.OnCaptured(botId, trapHouseId)
    local bot = Matrix.Bots[botId]
    if not bot then return nil end

    local snitchIndex = Matrix.Clamp(Matrix.Kitchen.ComputeSnitchIndex(bot), -1.0, 1.0)
    local didSnitch = snitchIndex >= Config.Kitchen.SnitchThreshold

    MySQL.query.await([[
        INSERT INTO matrix_snitch_events (bot_id, trap_house_id, snitch_index, lied, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { botId, trapHouseId, snitchIndex, didSnitch and 0 or 1 })

    if didSnitch then
        Matrix.Log(
            'KITCHEN', 'Bot #%d yakalandı ve Büro ile trap house #%d verilerini paylaştı (I_snitch %.2f)',
            botId, trapHouseId, snitchIndex
        )
        Matrix.Bureau.ReceiveSnitchLeak(trapHouseId)
    else
        Matrix.Log(
            'KITCHEN', '[UYARI: TELSİZ FREKANSI SES ANALİZİ - %%%.0f SAPMA] Bot #%d sorguda yalan söyledi.',
            bot.biology.cortisol_level * 100, botId
        )
    end

    return snitchIndex, didSnitch
end

RegisterNetEvent('matrix:server:reportCookAction', function(trapHouseId, rawWeight, rawPurity, agentWeight)
    local src = source
    Matrix.Kitchen.ProcessCook({ kind = 'player', source = src }, trapHouseId, rawWeight, rawPurity, agentWeight)
end)

RegisterNetEvent('matrix:server:reportBotCaptured', function(botId, trapHouseId)
    Matrix.Kitchen.OnCaptured(botId, trapHouseId)
end)

RegisterNetEvent('matrix:server:reportCortisolTrigger', function(spikeType)
    local src = source
    Matrix.Kitchen.AdjustCortisol({ kind = 'player', source = src }, spikeType)
end)
