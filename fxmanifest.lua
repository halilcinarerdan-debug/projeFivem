fx_version 'cerulean'
game 'gtav'

name        'matrix-layer5-ultimate'
description 'MATRIX — Katman 5 Ultimate Co-Op & SIGINT/COMINT Bali-Logistics Matrix (qbx_core / ox_lib / ox_inventory)'
author      'Matrix Systems Architecture'
version     '5.0.0'

lua54 'yes'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/forensics.lua',
    'server/market.lua',
    'server/logistics.lua',
    'server/blackmarket.lua'
}

client_scripts {
    'client/hud.lua'
}

dependencies {
    'qbx_core',
    'ox_lib',
    'ox_inventory',
    'oxmysql'
}
