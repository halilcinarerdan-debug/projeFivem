-- =====================================================================
-- MATRIX HUD / client/hud.lua  (KATMAN 5 — ATMOSFERİK EVRİM SÜRÜMÜ)
-- Saf metin tabanlı, monokrom (yeşil/beyaz) Taktik Durum HUD'u.
--
-- ★ SERTLEŞTİRME (v1, korunuyor):
--   [S1] lib.inputDialog çıktıları, ExecuteCommand'a girmeden önce KATI
--        sanitizasyondan geçer: sayısal alanlar yalnızca tam sayı,
--        [1, Config.Hud.MaxBotIdInputValue]; plaka yalnızca [%w%-_%.] ve
--        Config.Hud.MaxPlateInputLength sınırında. Boşluk/quote/semicolon/
--        newline İÇEREN hiçbir girdi komuta ULAŞMAZ — ExecuteCommand
--        argüman-ayrıştırıcısına asla kirli string gitmez. Bu, sunucu
--        thread'inde mikrosaniyelik bile bir "parse + yetkisiz arg"
--        oluşmasını yapısal olarak engeller.
--   [S2] Gelen snapshot satırları `#lines <= Config.Hud.MaxHudLines` ile
--        sınırlandırılır (RAM-bomb savunması).
--   [S3] lib.notify varsa geçersiz girdi sessizce YUTULMAZ, kullanıcıya
--        görünür bir uyarı basılır (ama komut TETİKLENMEZ).
--
-- ★ KATMAN 5 EVRİM (bu sürüm):
--   [E1] SIFIR SAYI STANDARDI: Sunucudan gelen snapshot satırları artık
--        çiğ float TAŞIYABİLİR ({ metric=..., value=... } biçiminde) ama
--        bu float'lar EKRANA ASLA ÇİZİLMEZ. Snapshot alınır alınmaz (per
--        frame değil, tek seferde — 0 Resmon bütçesi) FormatBulletinLine
--        ile edebi/askeri bültene çevrilip hudLines'a öyle yazılır. Bilinmeyen
--        bir metrik gelirse satır GÜVENLİ ŞEKİLDE YUTULUR (çiğ sayı asla
--        sızmaz). Geliştirici Kokpiti İstisnası: bu dönüşüm yalnızca HUD ve
--        F10 menü arayüzlerini kapsar — sunucu konsolu (print/Matrix.Log)
--        ve /matrixdump ham float'ları olduğu gibi basmaya devam eder,
--        çünkü bu dosya o çıktı yollarına hiç dokunmaz.
--   [E2] MULTI-WAYPOINT TAKTİK ROTA MOTORU: F10 menüsüne "Rota Çiz" alt
--        menüsü eklendi. inputDialog üzerinden 3 ara uğrak + 1 final hedef
--        toplanır; her biri ya "x,y,z" (vector3) ya da bir Trap House ID
--        (tam sayı) olabilir. [S1] ile aynı sıkılıkta sanitize edilir:
--        yalnızca rakam/nokta/virgül/eksi işareti — boşluk/quote/semicolon
--        İÇEREN hiçbir girdi ExecuteCommand'a ulaşmaz. Sunucu tarafı
--        (server/main.lua: /rotaciz, Matrix.BeginRouteDispatch) format
--        çözümlemesini (trap house mı, koordinat mı) ve tüm fiziksel
--        güvenlik guard'larını (ışınlanma koruması, Co-Op Mutex) yürütür.
-- =====================================================================

local hudActive = false
local hudLines  = {}   -- { { text=..., header=true/false }, ... }

local COLOR_HEADER = { 235, 235, 235 }
local COLOR_VALUE  = { 110, 255, 140 }
local COLOR_DIM    = { 90, 140, 100 }

local MAX_HUD_LINES  = (Config.Hud and Config.Hud.MaxHudLines) or 64
local MAX_PLATE_LEN  = (Config.Hud and Config.Hud.MaxPlateInputLength) or 32
local MAX_BOT_ID     = (Config.Hud and Config.Hud.MaxBotIdInputValue) or 999999
local MAX_WAYPOINT_LEN = (Config.Hud and Config.Hud.MaxWaypointInputLength) or 64

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

-- ★ [S1] Sanitizasyon yardımcıları -------------------------------------

--- Sayısal string arg: tam sayı, [minVal, maxVal] aralığında. Aksi halde nil.
--- NaN/inf/+/- boşluk/karakter — hepsi reddedilir.
local function SanitizeNumericArg(v, minVal, maxVal)
    if v == nil then return nil end
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n)
    if n < (minVal or 1) or n > (maxVal or MAX_BOT_ID) then return nil end
    return tostring(n)
end

--- Plaka arg: yalnızca [%w%-_%.] karakterleri, <= MAX_PLATE_LEN. Boş string
--- GEÇERLİDİR (kalıcı araç/foot anlamına gelir). Boşluk/quote/semicolon/nil
--- → nil (reddedilir).
local function SanitizePlateArg(v)
    if v == nil then return '' end
    local s = tostring(v)
    if #s > MAX_PLATE_LEN then return nil end
    if s == '' then return '' end
    -- Boşluk, quote, ; , |, newline, tab: hepsi YASAK (ExecuteCommand parser'ı
    -- boşluktan böler; enjeksiyon vektörünü kapatıyoruz).
    if s:find('[^%w%-_%.]') then return nil end
    return s
end

--- Rank arg: whitelist. Client, sunucudaki Config'i görmez ama bu üç değer
--- sabit — yine de ExecuteCommand'a SADECE bu üç string'den biri geçer.
local VALID_RANK_ARGS = {
    Leader = true, Logistics_Officer = true, Chemist = true
}

local function SanitizeRankArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    if not VALID_RANK_ARGS[s] then return nil end
    return s
end

--- ★ [E2] Waypoint arg: "x,y,z" / "x, y, z" / "x y z" (/coords çıktısı
--- boşlukla gelir) vektörü YA DA salt tam sayı Trap House ID kabul eder.
--- Kabul edilen karakter kümesi yalnızca [rakam, nokta, virgül, eksi,
--- boşluk] — harf/quote/semicolon İÇEREN hiçbir girdi kabul edilmez.
--- ExecuteCommand tek bir argüman bekler (boşluk argümanı BÖLER), bu yüzden
--- kabul edilen boşluklar/virgüller BURADA tek bir "," ayracına normalize
--- edilir; döndürülen string ASLA boşluk içermez. Format çözümlemesi
--- (trap house mu, koordinat mı) sunucu tarafında yapılır; client yalnızca
--- karakter kümesini, uzunluğu ve normalize edilmiş biçimi doğrular.
local function SanitizeWaypointArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    s = s:match('^%s*(.-)%s*$') -- baş/son boşlukları kırp
    if s == '' then return nil end
    if #s > MAX_WAYPOINT_LEN then return nil end
    -- Yalnızca rakam/nokta/virgül/eksi/boşluk — başka HİÇBİR karakter kabul edilmez.
    if s:find('[^%d%.,%-%s]') then return nil end

    -- "x y z" / "x, y , z" gibi karışık ayraçları TEK "," ayracına indir.
    s = s:gsub('%s+', ','):gsub(',+', ',')
    s = s:match('^,*(.-),*$') -- baş/son ayraçları temizle

    if s == '' then return nil end
    if #s > MAX_WAYPOINT_LEN then return nil end
    return s
end

--- ★ [E3] DİNAMİK WAYPOINT ESNEKLİĞİ: ara uğrak alanları (1-3) artık
--- ZORUNLU DEĞİL. Boş bırakılan bir alan GEÇERLİDİR — sabit bir "atla"
--- placeholder'ı (ROUTE_WAYPOINT_SKIP) döner; ExecuteCommand tek argüman
--- beklediği için boş string GÖNDERİLEMEZ (pozisyonel argümanları kaydırır),
--- bu yüzden boş bırakma her zaman bu sabit, boşluksuz token ile temsil
--- edilir. DOLU bir alan yine [S1] ile aynı katı SanitizeWaypointArg
--- kontrolünden geçer — geçersizse (harf/quote/vb.) nil döner (komut iptal).
local ROUTE_WAYPOINT_SKIP = 'nil'

local function SanitizeOptionalWaypointArg(v)
    if v == nil then return ROUTE_WAYPOINT_SKIP end
    local trimmed = tostring(v):match('^%s*(.-)%s*$')
    if trimmed == '' then return ROUTE_WAYPOINT_SKIP end
    return SanitizeWaypointArg(trimmed)
end

--- ★ [E2] Araç tipi arg: whitelist Config.Logistics.VehicleTypes anahtarlarından
--- türetilir (paylaşımlı Config, client'ta da görünür) — sabit metin dışında
--- hiçbir şey ExecuteCommand'a geçmez.
local function SanitizeVehicleTypeArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    if not (Config.Logistics and Config.Logistics.VehicleTypes and Config.Logistics.VehicleTypes[s]) then
        return nil
    end
    return s
end

local function BuildVehicleTypeOptions()
    local options = {}
    for vtype in pairs(Config.Logistics and Config.Logistics.VehicleTypes or {}) do
        options[#options + 1] = { value = vtype, label = vtype }
    end
    table.sort(options, function(a, b) return a.value < b.value end)
    return options
end

local function NotifyInvalidInput(reason)
    if lib and lib.notify then
        lib.notify({
            title       = '[GECERSIZ GIRD]',
            description = reason or 'Komut icin gecersiz parametre.',
            type        = 'error'
        })
    else
        print(('[MATRIX:HUD] Gecersiz girdi: %s'):format(tostring(reason)))
    end
end

-- =====================================================================
-- ★ [E1] SIFIR SAYI STANDARDI — Bültene Çeviri Motoru
-- =====================================================================
local BULLETIN_CORTISOL   = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Cortisol)
    or { CalmMax = 0.20, AnxietyMax = 0.60 }
local BULLETIN_FATIGUE    = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Fatigue)
    or { FreshMax = 0.30, ChronicMax = 0.80 }
local BULLETIN_MECHANICAL = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Mechanical)
    or { PristineMin = 0.80, WornMin = 0.40 }

local function FormatCortisolBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value < BULLETIN_CORTISOL.CalmMax then
        return '[NABIZ: SOĞUKKANLI SUBAY]'
    elseif value <= BULLETIN_CORTISOL.AnxietyMax then
        return '[NABIZ: ANKSİYETE BAŞLANGICI — TETİKTE]'
    else
        return '[NABIZ: AKUT PANİK ATAK KRİZİ — ELLERİN TİTRİYOR]'
    end
end

local function FormatFatigueBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value < BULLETIN_FATIGUE.FreshMax then
        return '[KONDİSYON: DİNÇ]'
    elseif value <= BULLETIN_FATIGUE.ChronicMax then
        return '[KONDİSYON: KRONİK BİTKİNLİK — REFLEKSLER YAVAŞ]'
    else
        return '[KONDİSYON: NÖRON HASARI SINIRI — BEYİN SAKATLIĞI RİSKİ]'
    end
end

local function FormatMechanicalBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value > BULLETIN_MECHANICAL.PristineMin then
        return '[MEKANİK: KUSURSUZ CONDITION]'
    elseif value >= BULLETIN_MECHANICAL.WornMin then
        return '[MEKANİK: YİV-SET AŞINMASI — BALİSTİK MUTASYON AKTİF]'
    else
        return '[MEKANİK: KRİTİK YİV ERİMESİ — TUTUKLUK VE PERMADEATH RİSKİ]'
    end
end

--- Sunucudan gelen tek bir snapshot satırını (ham metrik veya düz metin)
--- nihai ekran metnine çevirir. Bilinmeyen/geçersiz metrik → nil (satır
--- ekrana hiç basılmaz; çiğ sayı asla sızmaz).
local function FormatBulletinLine(metric, value, label)
    label = label or ''
    if metric == 'cortisol_level' then
        local text = FormatCortisolBulletin(value)
        return text and (label .. text) or nil
    elseif metric == 'fatigue_level' then
        local text = FormatFatigueBulletin(value)
        return text and (label .. text) or nil
    elseif metric == 'durability' or metric == 'wear_level' then
        local text = FormatMechanicalBulletin(value)
        return text and (label .. text) or nil
    end
    return nil
end

-- =====================================================================
-- Toggle / snapshot
-- =====================================================================
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
    -- ★ [S2] RAM-bomb savunması: sunucu kontrollü de olsa, üst sınır koy.
    if #lines > MAX_HUD_LINES then return end

    -- ★ [E1] Dönüşüm TEK SEFERDE burada yapılır (per-frame değil) — 0 Resmon
    -- bütçesi korunur. Render thread'i yalnızca hazır metni çizer.
    local converted = {}
    for i = 1, #lines do
        local line = lines[i]
        if type(line) == 'table' then
            if line.metric ~= nil then
                local text = FormatBulletinLine(line.metric, line.value, line.label)
                if text then
                    converted[#converted + 1] = { text = text, header = line.header and true or false }
                end
            elseif type(line.text) == 'string' then
                converted[#converted + 1] = { text = line.text, header = line.header and true or false }
            end
        end
    end
    hudLines = converted
end)

RegisterCommand('hud', function()
    ToggleHud()
end, false)

RegisterKeyMapping('hud', 'Taktik HUD ac/kapat', 'keyboard', Config.Hud and Config.Hud.ToggleKey or 'F6')

AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    hudActive = false
    hudLines  = {}
end)

-- =====================================================================
-- TAKTİK KOMUTA MENÜSÜ (ox_lib Context Menu, F10) — MÜHÜRLÜ + EVRİM
-- =====================================================================
local function OpenSevketDialog()
    local input = lib.inputDialog('/sevket - Fiziksel Dealer Sevki', {
        {
            type = 'number', label = 'Bot ID',
            description = 'Sevk edilecek dealer botunun ID numarasi',
            required = true, min = 1, max = MAX_BOT_ID
        },
        {
            type = 'input', label = 'Plaka (bos = kalici arac/foot)',
            required = false, max = MAX_PLATE_LEN
        }
    })
    if not input then return end

    local botId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not botId then NotifyInvalidInput('Bot ID gecersiz.'); return end

    local plate = SanitizePlateArg(input[2])
    if plate == nil then
        NotifyInvalidInput('Plaka yalnizca harf/rakam/-/_/. icerebilir (max ' .. MAX_PLATE_LEN .. ').')
        return
    end

    ExecuteCommand(('sevket %s %s'):format(botId, plate))
end

local function OpenTrapHouseDurumDialog()
    local input = lib.inputDialog('/traphousedurum - Trap House Sorgusu', {
        { type = 'number', label = 'Trap House ID', required = true, min = 1, max = 2147483646 }
    })
    if not input then return end

    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end

    ExecuteCommand(('traphousedurum %s'):format(houseId))
end

local function OpenRutbeAtaDialog()
    local input = lib.inputDialog('/rutbeata - Hiyerarsi Rutbe Atamasi', {
        { type = 'number', label = 'Hedef Server ID', required = true, min = 1, max = 65535 },
        { type = 'select', label = 'Rutbe', required = true, options = {
            { value = 'Leader',            label = 'Leader (Baron)' },
            { value = 'Logistics_Officer', label = 'Logistics_Officer (Lojistik Subayi)' },
            { value = 'Chemist',           label = 'Chemist (Kimyager)' }
        } }
    })
    if not input then return end

    local targetSrc = SanitizeNumericArg(input[1], 1, 65535)
    if not targetSrc then NotifyInvalidInput('Hedef Server ID gecersiz.'); return end

    local rank = SanitizeRankArg(input[2])
    if not rank then NotifyInvalidInput('Rutbe secimi gecersiz.'); return end

    ExecuteCommand(('rutbeata %s %s'):format(targetSrc, rank))
end

--- ★ [E2][E3] "Rota Çiz" — Multi-Waypoint Taktik Rota Motoru diyaloğu.
--- 0-3 ara uğrak (ARTIK ZORUNLU DEĞİL, boş bırakılabilir) + 1 ZORUNLU final
--- hedef toplanır; her alan ya "x,y,z" vektörü ya da bir Trap House ID'sidir.
--- Dolu alanlar [S1] ile aynı sıkılıkta sanitize edilir; boş bırakılan ara
--- uğraklar ROUTE_WAYPOINT_SKIP placeholder'ı ile gönderilip sunucu
--- tarafında (server/main.lua: /rotaciz) rota zincirinden drop edilir.
--- Format çözümlemesi (koordinat mı, trap house mu) ve fiziksel güvenlik
--- guard'ları (ışınlanma koruması, Co-Op Mutex) da sunucu tarafında yürütülür.
local function OpenRotaCizDialog()
    local input = lib.inputDialog('/rotaciz - Multi-Waypoint Taktik Rota', {
        {
            type = 'number', label = 'Bot ID',
            description = 'Rota cizilecek dealer botunun ID numarasi',
            required = true, min = 1, max = MAX_BOT_ID
        },
        {
            type = 'input', label = '1. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" VEYA Trap House ID — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = '2. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" VEYA Trap House ID — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = '3. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" VEYA Trap House ID — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = 'Final Hedef (Ana Us) — ZORUNLU',
            description = '"x,y,z" veya "x y z" VEYA Trap House ID',
            required = true, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = 'Plaka (bos = kalici arac/foot)',
            required = false, max = MAX_PLATE_LEN
        },
        {
            type = 'select', label = 'Arac Tipi', required = true,
            options = BuildVehicleTypeOptions()
        }
    })
    if not input then return end

    local botId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not botId then NotifyInvalidInput('Bot ID gecersiz.'); return end

    -- ★ [E3] Ara uğraklar (1-3): boş bırakma GEÇERLİDİR (atlanır); DOLU
    -- olup da karakter kümesini ihlal eden bir girdi yine REDDEDİLİR.
    local waypointArgs = {}
    for i = 2, 4 do
        local wp = SanitizeOptionalWaypointArg(input[i])
        if not wp then
            NotifyInvalidInput(('Uğrak #%d geçersiz (boş bırakabilirsiniz; doluysa yalnızca rakam, ".", ",", "-", boşluk).'):format(i - 1))
            return
        end
        waypointArgs[#waypointArgs + 1] = wp
    end

    -- Final hedef HALA ZORUNLU — boş bırakılamaz.
    local finalWp = SanitizeWaypointArg(input[5])
    if not finalWp then
        NotifyInvalidInput('Final Hedef geçersiz veya boş bırakılamaz (yalnızca rakam, ".", ",", "-", boşluk).')
        return
    end

    local plate = SanitizePlateArg(input[6])
    if plate == nil then
        NotifyInvalidInput('Plaka yalnizca harf/rakam/-/_/. icerebilir (max ' .. MAX_PLATE_LEN .. ').')
        return
    end

    local vehicleType = SanitizeVehicleTypeArg(input[7])
    if not vehicleType then NotifyInvalidInput('Arac tipi gecersiz.'); return end

    ExecuteCommand(('rotaciz %s %s %s %s %s %s %s'):format(
        botId, waypointArgs[1], waypointArgs[2], waypointArgs[3], finalWp, plate, vehicleType))
end

local function OpenMatrixDump()
    ExecuteCommand('matrixdump')
end

--- ★ KATMAN 5 EK EMİR: "Canlı Kadro & Hiyerarşi Raporu".
--- Sunucudan lib.callback ile TEK SEFERLİK (menü açıldığı an) telemetri
--- çeker — sürekli bir polling thread'i YOKTUR, bu yüzden 0 Resmon bütçesi
--- HUD kapalıyken de açıkken de bozulmaz: rapor yalnızca oyuncu bu menüyü
--- AÇTIĞINDA hesaplanır, saf istek/cevap (callback) yapısıyla.
local function OpenCanliKadroRaporu()
    local lines = lib.callback.await('matrix:callback:getRosterReport', false)
    if type(lines) ~= 'table' or #lines == 0 then
        if lib and lib.notify then
            lib.notify({
                title       = '[KADRO RAPORU]',
                description = 'Aktif unsur bulunamadi (bot veya oyuncu yok).',
                type        = 'inform'
            })
        end
        return
    end

    local options = {}
    for i = 1, #lines do
        options[i] = { title = lines[i], disabled = true, icon = 'circle-dot' }
    end

    lib.registerContext({
        id    = 'matrix_roster_report',
        title = '=== CANLI KADRO & HIYERARSI RAPORU ===',
        menu  = 'matrix_tactical_menu',
        options = options
    })
    lib.showContext('matrix_roster_report')
end

-- =====================================================================
-- ★ KATMAN 5 EK EMİR: "OPERASYON NOT DEFTERİ" (Matrix Notepad)
-- Saf lib.inputDialog tabanlı, monokrom bir taktik not defteri. Notlar
-- YALNIZCA client RAM'inde (savedMatrixNotes) tutulur — sunucuya HİÇ
-- gönderilmez, bu yüzden ağ/enjeksiyon yüzeyi açmaz. Standart Ctrl+C/
-- Ctrl+V (Windows panosu) davranışı, alan zaten sıradan bir NUI metin
-- kutusu olduğundan NATİF olarak çalışır — bunun için ayrı bir özel NUI
-- köprüsü YAZILMASI GEREKMEZ (ve burada zaten böyle bir şey yok, o yüzden
-- "bozulacak" bir şey de yok). Aktif GPS işaretini (haritaya çift tıkla
-- konan mor waypoint) doğrudan oyun native'lerinden OKUYARAK panoya hiç
-- ihtiyaç duymadan not defterine otomatik ekler — daha güvenilir bir çözüm.
-- =====================================================================
local MAX_NOTEPAD_LENGTH = 4000 -- degenere/asiri buyume savunmasi (RAM-bomb)

local savedMatrixNotes = '' -- oturum boyunca (resource restart'a kadar) kalici RAM onbellegi

local OpenTacticalMenu -- ★ ileri bildirim: not defteri kapanınca F10'a dönmek için

--- Aktif GPS işaretini (haritaya çift tıklamayla konan mor waypoint) yakalar.
--- Waypoint blip'leri 2D'dir (Z taşımaz) — makul bir yaklaşım olarak
--- oyuncunun mevcut Z'si kullanılır.
local function CaptureActiveWaypointText()
    if not IsWaypointActive() then return nil end
    local waypointBlip = GetFirstBlipInfoId(8)
    if not DoesBlipExist(waypointBlip) then return nil end

    local wp  = GetBlipInfoIdCoord(waypointBlip)
    local ped = PlayerPedId()
    local pc  = GetEntityCoords(ped)
    return ('%.1f %.1f %.1f'):format(wp.x, wp.y, pc.z)
end

local function OpenMatrixNotepad()
    -- ★ Kalıcı önbellek: not defteri son kaydedilen haliyle açılır.
    local defaultValue = savedMatrixNotes
    local waypointHint = CaptureActiveWaypointText()
    if waypointHint and not defaultValue:find(waypointHint, 1, true) then
        defaultValue = (defaultValue ~= '' and (defaultValue .. '\n') or '') .. waypointHint
    end

    local input = lib.inputDialog('=== MATRIX NOTEPAD — OPERASYON NOT DEFTERI ===', {
        {
            type        = 'textarea',
            label       = 'Taktik Notlar / Koordinatlar',
            description = 'Ctrl+V ile Windows panosundan yapıştırabilirsiniz. Aktif GPS işareti varsa otomatik eklendi.',
            default     = defaultValue,
            required    = false
        }
    })

    if input then
        local text = tostring(input[1] or '')
        if #text > MAX_NOTEPAD_LENGTH then
            text = text:sub(#text - MAX_NOTEPAD_LENGTH + 1) -- en eski kismi kirp, son yazilani koru
        end
        savedMatrixNotes = text
    end

    -- ★ Kapanış yolundan BAĞIMSIZ (Kaydet ya da İptal/Esc) — oyuncu F10
    -- akışından kopmasın diye Taktik Komuta Menüsüne otomatik döner.
    Wait(50)
    OpenTacticalMenu()
end

OpenTacticalMenu = function()
    lib.registerContext({
        id = 'matrix_tactical_menu',
        title = '=== TAKTIK KOMUTA MENUSU ===',
        options = {
            {
                title       = 'OPERASYON NOT DEFTERI',
                description = 'Serbest metin taktik not defteri (Matrix Notepad) — RAM önbellekli',
                icon        = 'note-sticky',
                onSelect    = OpenMatrixNotepad
            },
            {
                title       = 'Canlı Kadro & Hiyerarşi Raporu',
                description = 'Tum aktif bot ve oyuncu unsurlarini anlik olarak listele',
                icon        = 'users-gear',
                onSelect    = OpenCanliKadroRaporu
            },
            {
                title       = '/sevket',
                description = 'Dealer botunu fiziksel sevke al (rutbe yetkisi gerekir)',
                icon        = 'route',
                onSelect    = OpenSevketDialog
            },
            {
                title       = '/rotaciz',
                description = 'Bota 3 ara ugrak + final hedeften olusan taktik kacis rotasi ata',
                icon        = 'map-location-dot',
                onSelect    = OpenRotaCizDialog
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
-- Wait(0) (DrawText'in gerektirdiği per-frame çağrı). Metin dönüşümü
-- render thread'inde YAPILMAZ (bkz. [E1]) — burada yalnızca hazır string
-- çizilir, bu yüzden HUD açıkken bile 0 Resmon bütçesi korunur.
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
