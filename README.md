# Dailies (3.3.5 port)

**Plan your dailies.** Dailies keeps track of your daily quests: what's left to do today, what you've already handed in, and which quest a random daily pool is offering today. It also shares that with your guild, so one person finding today's quest is enough for everyone.

This is a port of [Dailies](https://addons.wago.io/addons/dailies) by Cixi/Gaya @ Remulos to the **3.3.5a (Wrath of the Lich King)** client, as used on private servers. It is maintained separately from the original addon; see [Support](#support).

## Features

- **To Do list** of the dailies you can do today, which you can put in your own order.
- **Learns as you play.** Talk to a quest giver and the daily is recorded, with its quest giver, zone, description and rewards. Dailies already in your quest log are picked up at login.
- **Comes with the dailies of The Burning Crusade and Wrath of the Lich King.** These include Netherwing, Ogri'la, Sha'tari Skyguard, the Shattered Sun Offensive, Sons of Hodir, Frenzyheart and the Oracles, the Argent Crusade, the Kalu'ak, Wyrmrest, the Ebon Blade, and the cooking, fishing and jewelcrafting dailies. The Argent Tournament is covered both before and after its construction. Quest IDs, daily pools and reputation rewards were checked against [AzerothCore](https://github.com/azerothcore/azerothcore-wotlk)'s 3.3.5 data.
- **Random daily pools** (heroic and normal dungeon, cooking, fishing, Argent Tournament...): until today's quest is known, the To Do list shows an "Unknown ... Daily" line for the pool. Once it's known, the pool's other quests are greyed out.
- **Guild sharing:** at login (or with the Scan button) Dailies asks guildmates for today's dailies.
- **Reputation and gold:** each quest shows its reputation rewards. A summary line adds up the gold and reputation still to earn, and you can filter the list by reputation.
- **Ignore list** for dailies you never do.
- **Auto-accept and auto-complete** for quests on your To Do list (both off by default).
- **Quest information panel:** quest giver, zone, times completed and your fastest completion. If you use the Attune addon, the panel links to the matching attunement.
- **Statistics** for the character and the whole account: dailies completed, gold earned, most repeated daily, fastest completion.
- **Every character on the account:** the tooltip shows which of your other characters already did a quest today.
- **Faction aware**, including on servers where both factions can share a guild: Alliance and Horde versions of a quest are kept apart.
- **Update notice:** if a guildmate runs a newer version, you're told at login where to download it.

## Installation

1. Download the addon: on the [GitHub page](https://github.com/heyitsbench/Dailies-3.3.5), click **Code**, then **Download ZIP**.
2. Extract it into `World of Warcraft\Interface\AddOns\`.
3. **Rename the folder to `Dailies`.** GitHub names it `Dailies-3.3.5-main`, and the game won't load it under that name. You should end up with `Interface\AddOns\Dailies\Dailies.toc`.
4. Restart the game. A `/reload` isn't enough for a new addon.

To update, delete the old `Dailies` folder and repeat the steps. Your saved data is kept: it lives in the `WTF` folder, not in the addon folder.

## Using it

Open the window with `/dailies` or the minimap button. Right-click the minimap button for the options.

| Tab | Shows |
|---|---|
| To Do | Dailies you can still do today, in your order. Use the arrows to move them up or down. |
| Completed | Dailies this character handed in today. |
| Ignored | Dailies you've moved to the ignore list. |
| All Dailies | Every daily known to the addon, grouped by zone. |
| Statistics | Totals for this character and the whole account. |

The icon in front of each quest tells you where you stand:

- **Blue exclamation mark:** available to pick up.
- **Grey exclamation mark:** part of a random pool, but not today's quest (or today's isn't known yet). Hover over it to see which one is.
- **Orange arrow:** in your quest log.
- **Green arrow:** ready to turn in.
- **Green tick:** done today.
- **Red X:** on your Ignored list.

The red X at the end of each row moves a quest to the Ignored list, and the green tick in its place takes it off again. Click a quest's name to see its details in the panel below the list.

### Commands

- `/dailies`: open the window.
- `/dailies version`: list which version each guildmate with the addon runs.

## Options

In **Interface → AddOns → Dailies**, or right-click the minimap button:

- Show the minimap button.
- Scan the guild for today's dailies at login, or for all dailies.
- Tell me when guildmates have a newer version.
- Fallback daily reset hour (UTC), used only if the server doesn't report its reset time.
- Show incoming messages about today's dailies.
- Show the gold and reputation totals, and the quest information panel.
- Only show profession dailies for professions this character has.
- Auto-accept and auto-complete quests on your To Do list.
- Choose which dailies to show: The Burning Crusade, Wrath of the Lich King, seasonal events, Wrath dungeon dailies, the Argent Tournament.

## Sharing with your guild

Guildmates who also run Dailies swap what they know about daily quests, mainly which quest each random pool is offering today. Only quest information is sent (title, description, quest giver, zone, rewards, and whether it's today's), plus the addon version. Nothing about your characters' progress is shared.

On servers where both factions can share a guild, quests that belong to the other faction are ignored. Neutral dailies, like Sons of Hodir, are still shared.

## Things to know on 3.3.5

- **Hand-ins are tracked as they happen.** The 3.3.5 server doesn't tell addons which dailies you've already done today. Quests handed in before you installed the addon, or while it was turned off, won't show as completed until the next reset.
- **Today's pool quest has to be seen first.** The addon finds out which quest a random pool offers when you, or a guildmate, see it at the quest giver.
- **Zones fill in as you go.** A daily first seen in the quest log shows the quest log's heading as its zone until you next visit its quest giver.
- **Wrath dungeon dailies** were removed in patch 3.3, so they're hidden by default. Turn them on if your server still has them.

## Support

Report bugs, suggestions and questions about this version on the [Issues page](https://github.com/heyitsbench/Dailies-3.3.5/issues).

This port is maintained separately. Please don't contact the original author, or the authors of ports to other game versions, about it: they don't maintain this code.

## Credits

- **Dailies** was created by Cixi/Gaya @ Remulos (Antoine Desmarets) for WoW Classic. Copyright (c) 2019-2021 Antoine Desmarets.
- **3.3.5 port** by [heyitsbench](https://github.com/heyitsbench).
- Built with [Ace3](https://www.wowace.com/projects/ace3), LibDataBroker-1.1 and LibDBIcon-1.0.
