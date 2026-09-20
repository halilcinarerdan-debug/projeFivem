-- =====================================================================
-- MATRIX HUD / client/hud.lua  (KATMAN 5)
-- Saf metin tabanlı, monokrom (yeşil/beyaz) Taktik Durum HUD'u.
--
-- MİMARİ / PERFORMANS KİLİDİ:
--   • HTML/CSS tabanlı NUI YOKTUR. Bu dosya SendNUIMessage HİÇ ÇAĞIRMAZ.
--     Tüm görselleştirme native DrawText ile yapılır (askeri/terminal
--     estetiği — bu projedeki ASCII rapor/waveform'larla AYNI dil).
--   • Veri server'dan PUSH edilir (bkz. market.lua Matrix.Hud.PushSnapshots,
--     main.lua master ticker (5). adım) — client HİÇBİR ŞEY POLL ETMEZ.
--   • HUD KAPALIYKEN: render thread'i Wait(500) ile neredeyse tamamen
--     uykudadır (0.00ms'ye yakın). HUD AÇIKKEN: DrawText'in FiveM API
--     sözleşmesi gereği HER FRAME yeniden çağrılması gerekir (native bir
--     "her tick tek satır çiz" çağrısıdır — tek seferlik çağrı bir sonraki
--     frame'de kaybolur); bu yüzden Wait(0) o SIRADA aktiftir. Bu, "sürekli
--     ekranda çizim yapan hantal thread" değildir — sadece birkaç DrawText
--     çağrısıdır (standart FiveM idiomudur, NUI/HTML render'ından KATLARCA
--     ucuzdur) VE toggle kapatılınca ANINDA Wait(500)'e döner.
-- =====================================================================

local hudActive = false
local hudLines  = {}   -- { { text=..., header=true/false }, ... }

-- ---------- Renkler (monokrom: yeşil değer, beyaz başlık) ----------
local COLOR_HEADER = { 235, 235, 235 }
local COLOR_VALUE  = { 110, 255, 140 }
local COLOR_DIM    = { 90, 140, 100 }

local function DrawMonoLine(x, y, text, r, g, b, scale)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, 235)
    SetTextDropshadow(1, 0, 0, 0, 200)
    SetTextEdge(1, 0, 0, 0, 180)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(x, y)
end

local function ToggleHud(forceState)
    local newState = (forceState ~= nil) and forceState or (not hudActive)
    if newState == hudActive then return end

    hudActive = newState
    if not hudActive then
        hudLines = {}
    end
    TriggerServerEvent('matrix:server:hudToggled', hudActive)
end

RegisterNetEvent('matrix:client:hudSnapshot', function(lines)
    if not hudActive then return end
    if type(lines) ~= 'table' then return end
    hudLines = lines
end)

RegisterCommand('hud', function()
    ToggleHud()
end, false)

RegisterKeyMapping('hud', 'Taktik HUD ac/kapat', 'keyboard', Config.Hud and Config.Hud.ToggleKey or 'F6')

-- Kaynak yeniden başlarsa/durursa server tarafı HudViewers setini
-- kendiliğinden temizler (playerDropped); burada ekstra bir şey gerekmez.
-- Ama kaynak client-side yeniden yüklenirse (resmon/restart) local state'i
-- de sıfırlarız ki "hayalet" bir hudActive=true kalmasın.
AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    hudActive = false
    hudLines  = {}
end)

-- =====================================================================
-- TAKTİK KOMUTA MENÜSÜ (ox_lib Context Menu, F10) — KATMAN 5
--
-- Amaç: chat'e komut yazma zorunluluğunu bitirmek. Sık kullanılan 4 komut
-- (/sevket, /traphousedurum, /rutbeata, /matrixdump) tek tıkla, saf metin
-- tabanlı ox_lib context menu üzerinden tetiklenir.
--
-- MİMARİ: Bu menü YENİ hiçbir server event'i EKLEMEZ; sadece ExecuteCommand
-- ile mevcut RegisterCommand komutlarını (bkz. server/logistics.lua,
-- bureau.lua, market.lua, main.lua) AYNEN tetikler — yetki kontrolleri
-- (HasCommandAuthority vb.) komutun kendi içinde zaten çalıştığından bu
-- menü hiçbir yetkilendirmeyi BYPASS ETMEZ; sadece bir "hızlı yazma"
-- kısayolu, 0 Resmon (ekstra thread/tick yok, sadece tıklama-anı çağrısı).
-- =====================================================================
local function OpenSevketDialog()
    local input = lib.inputDialog('/sevket - Fiziksel Dealer Sevki', {
        { type = 'number', label = 'Bot ID', description = 'Sevk edilecek dealer botunun ID numarasi', required = true },
        { type = 'input',  label = 'Plaka (bos = kalici arac/foot)', required = false }
    })
    if not input or not input[1] then return end

    local vehicleRef = (input[2] and tostring(input[2]) ~= '') and tostring(input[2]) or ''
    ExecuteCommand(('sevket %s %s'):format(tostring(input[1]), vehicleRef))
end

local function OpenTrapHouseDurumDialog()
    local input = lib.inputDialog('/traphousedurum - Trap House Sorgusu', {
        { type = 'number', label = 'Trap House ID', required = true }
    })
    if not input or not input[1] then return end

    ExecuteCommand(('traphousedurum %s'):format(tostring(input[1])))
end

local function OpenRutbeAtaDialog()
    local input = lib.inputDialog('/rutbeata - Hiyerarsi Rutbe Atamasi', {
        { type = 'number', label = 'Hedef Server ID', required = true },
        { type = 'select', label = 'Rutbe', required = true, options = {
            { value = 'Leader',            label = 'Leader (Baron)' },
            { value = 'Logistics_Officer', label = 'Logistics_Officer (Lojistik Subayi)' },
            { value = 'Chemist',           label = 'Chemist (Kimyager)' }
        } }
    })
    if not input or not input[1] or not input[2] then return end

    ExecuteCommand(('rutbeata %s %s'):format(tostring(input[1]), tostring(input[2])))
end

local function OpenMatrixDump()
    ExecuteCommand('matrixdump')
end

local function OpenTacticalMenu()
    lib.registerContext({
        id = 'matrix_tactical_menu',
        title = '=== TAKTIK KOMUTA MENUSU ===',
        options = {
            {
                title       = '/sevket',
                description = 'Dealer botunu fiziksel sevke al (rutbe yetkisi gerekir)',
                icon        = 'route',
                onSelect    = OpenSevketDialog
            },
            {
                title       = '/traphousedurum',
                description = 'Trap house desifre/heat/duzenlilik durumunu sorgula',
                icon        = 'house-signal',
                onSelect    = OpenTrapHouseDurumDialog
            },
            {
                title       = '/rutbeata',
                description = 'Bir oyuncuya hiyerarsi rutbesi ata (rutbe yetkisi gerekir)',
                icon        = 'user-shield',
                onSelect    = OpenRutbeAtaDialog
            },
            {
                title       = '/matrixdump',
                description = 'Tum bot matrisini (biyoloji/psikoloji) dokum et',
                icon        = 'terminal',
                onSelect    = OpenMatrixDump
            }
        }
    })
    lib.showContext('matrix_tactical_menu')
end

RegisterCommand('taktikmenu', function()
    OpenTacticalMenu()
end, false)

RegisterKeyMapping('taktikmenu', 'Taktik Komuta Menusunu Ac', 'keyboard', 'F10')

-- =====================================================================
-- RENDER THREAD — HUD kapalıyken Wait(500) (neredeyse 0ms), açıkken
-- Wait(0) (DrawText'in gerektirdiği per-frame çağrı).
-- =====================================================================
CreateThread(function()
    while true do
        if hudActive then
            local x, y = 0.014, 0.045
            DrawMonoLine(x, y, '=== MATRIX TAKTIK HUD ===', COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], 0.30)
            y = y + 0.026

            if #hudLines == 0 then
                DrawMonoLine(x, y, '...veri bekleniyor...', COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], 0.28)
            else
                for _, line in ipairs(hudLines) do
                    local color = line.header and COLOR_HEADER or COLOR_VALUE
                    DrawMonoLine(x, y, line.text or '', color[1], color[2], color[3], line.header and 0.30 or 0.28)
                    y = y + 0.021
                end
            end

            Wait(0)
        else
            Wait(500)
        end
    end
end)
