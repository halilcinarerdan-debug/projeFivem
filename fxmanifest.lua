fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'projeFivem'
description 'Katman 1-2-3-4-5 Birlesik Motor: Core Matrix, Adli Balistik, Recruitment, The Bureau, Mutfak & Psikoloji Simulasyonu, Programli Lojistik Sevk, Qbox Co-op Kartel Hiyerarsisi & Bolgesel Piyasa, Monokrom Taktik HUD'
version '1.2.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua'
}

client_scripts {
    'client/hud.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/forensics.lua',
    'server/recruitment.lua',
    'server/bureau.lua',
    'server/kitchen.lua',
    'server/logistics.lua',
    'server/market.lua'
}

dependencies {
    'qbx_core',
    'oxmysql',
    'ox_inventory'
}
