fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'projeFivem'
description 'Matrix - Layer 7 Automated Logistics & Cognitive Reasoning'
author 'halilcinarerdan-debug'
version '7.2.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/kitchen.lua',
    'server/logistics.lua',
    'server/market.lua',
    'server/forensics.lua',
}

client_scripts {
    'client/hud.lua',
}

dependencies {
    'ox_lib',
    'ox_inventory',
    'oxmysql',
}
