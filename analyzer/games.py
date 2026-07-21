"""Curated game -> genre labels. Fed to the classifier as ground truth so the
model can learn what an FPS 'sounds like' vs a racing game vs an RPG.

Genres are intentionally coarse; refine once the label list stabilizes:
  fps, battle-royale, moba, rpg, action-adventure, sports, racing, strategy,
  simulation, platformer, fighting, horror, puzzle, rhythm, party, mmo,
  survival, roguelike, stealth, sandbox, kart-racer, sports-arcade, shooter-arena
"""
from __future__ import annotations


GENRE_LABELS: dict[str, str] = {
    # ---- FPS ----
    "callofduty": "fps",
    "cod": "fps",
    "modernwarfare": "fps",
    "blackops": "fps",
    "battlefield": "fps",
    "bf": "fps",
    "counterstrike": "fps",
    "csgo": "fps",
    "cs2": "fps",
    "valorant": "fps",
    "overwatch": "fps",
    "titanfall": "fps",
    "halo": "fps",
    "doom": "fps",
    "doometernal": "fps",
    "quake": "fps",
    "rainbowsix": "fps",
    "r6siege": "fps",
    "siege": "fps",
    "escapefromtarkov": "fps",
    "tarkov": "fps",
    "insurgency": "fps",
    "borderlands": "fps",
    "destiny": "fps",
    "destiny2": "fps",
    "wolfenstein": "fps",
    "farcry": "fps",
    "bioshock": "fps",
    "halflife": "fps",
    "hlalyx": "fps",

    # ---- Battle royale ----
    "fortnite": "battle-royale",
    "apex": "battle-royale",
    "apexlegends": "battle-royale",
    "pubg": "battle-royale",
    "warzone": "battle-royale",
    "warzone2": "battle-royale",

    # ---- MOBA / arena ----
    "leagueoflegends": "moba",
    "lol": "moba",
    "dota2": "moba",
    "dota": "moba",
    "heroesofthestorm": "moba",
    "smite": "moba",

    # ---- RPG / ARPG ----
    "skyrim": "rpg",
    "elderscrolls": "rpg",
    "morrowind": "rpg",
    "oblivion": "rpg",
    "fallout": "rpg",
    "fallout4": "rpg",
    "falloutnv": "rpg",
    "witcher": "rpg",
    "witcher3": "rpg",
    "cyberpunk": "rpg",
    "cyberpunk2077": "rpg",
    "baldursgate": "rpg",
    "bg3": "rpg",
    "dragonage": "rpg",
    "divinity": "rpg",
    "masseffect": "rpg",
    "diablo": "rpg",
    "diablo3": "rpg",
    "diablo4": "rpg",
    "pathofexile": "rpg",
    "eldenring": "rpg",
    "darksouls": "rpg",
    "bloodborne": "rpg",
    "sekiro": "rpg",
    "persona": "rpg",
    "finalfantasy": "rpg",
    "kingdomhearts": "rpg",
    "monsterhunter": "rpg",

    # ---- MMO ----
    "worldofwarcraft": "mmo",
    "wow": "mmo",
    "finalfantasyxiv": "mmo",
    "ffxiv": "mmo",
    "guildwars": "mmo",
    "guildwars2": "mmo",
    "eve": "mmo",
    "eveonline": "mmo",
    "esoonline": "mmo",

    # ---- Action-adventure ----
    "gta": "action-adventure",
    "gtav": "action-adventure",
    "grandtheftauto": "action-adventure",
    "reddeadredemption": "action-adventure",
    "rdr2": "action-adventure",
    "assassinscreed": "action-adventure",
    "ac": "action-adventure",
    "zelda": "action-adventure",
    "botw": "action-adventure",
    "totk": "action-adventure",
    "uncharted": "action-adventure",
    "horizon": "action-adventure",
    "horizonzerodawn": "action-adventure",
    "tombraider": "action-adventure",
    "spiderman": "action-adventure",
    "godofwar": "action-adventure",
    "ghostoftsushima": "action-adventure",
    "hellblade": "action-adventure",
    "batmanarkham": "action-adventure",

    # ---- Sports ----
    "fifa": "sports",
    "eafc": "sports",
    "nba2k": "sports",
    "madden": "sports",
    "nhl": "sports",
    "mlbtheshow": "sports",
    "pga2k": "sports",

    # ---- Racing ----
    "forza": "racing",
    "forzahorizon": "racing",
    "forzamotorsport": "racing",
    "granturismo": "racing",
    "gt7": "racing",
    "needforspeed": "racing",
    "nfs": "racing",
    "f1": "racing",
    "dirt": "racing",
    "wrc": "racing",
    "trackmania": "racing",
    "assettocorsa": "racing",

    # ---- Kart / arcade racer ----
    "mariokart": "kart-racer",
    "crashteamracing": "kart-racer",
    "rocketleague": "sports-arcade",

    # ---- Strategy ----
    "starcraft": "strategy",
    "starcraft2": "strategy",
    "civilization": "strategy",
    "civ": "strategy",
    "civ6": "strategy",
    "totalwar": "strategy",
    "xcom": "strategy",
    "ageofempires": "strategy",
    "aoe": "strategy",
    "aoe4": "strategy",
    "companyofheroes": "strategy",
    "warcraft3": "strategy",

    # ---- Simulation ----
    "sims": "simulation",
    "sims4": "simulation",
    "citiesskylines": "simulation",
    "msfs": "simulation",
    "flightsimulator": "simulation",
    "eurotrucksim": "simulation",
    "farmingsim": "simulation",
    "kerbal": "simulation",

    # ---- Platformer ----
    "mario": "platformer",
    "supermario": "platformer",
    "smb": "platformer",
    "sonic": "platformer",
    "rayman": "platformer",
    "crashbandicoot": "platformer",
    "spyro": "platformer",
    "celeste": "platformer",
    "hollowknight": "platformer",
    "ori": "platformer",

    # ---- Fighting ----
    "streetfighter": "fighting",
    "sf6": "fighting",
    "tekken": "fighting",
    "mortalkombat": "fighting",
    "mk1": "fighting",
    "smashbros": "fighting",
    "supersmashbros": "fighting",
    "guiltygear": "fighting",
    "dbfz": "fighting",

    # ---- Horror / survival horror ----
    "residentevil": "horror",
    "silenthill": "horror",
    "amnesia": "horror",
    "outlast": "horror",
    "phasmophobia": "horror",
    "deadspace": "horror",
    "aliensisolation": "horror",

    # ---- Puzzle ----
    "portal": "puzzle",
    "portal2": "puzzle",
    "tetris": "puzzle",
    "baba": "puzzle",
    "thewitness": "puzzle",

    # ---- Rhythm ----
    "beatsaber": "rhythm",
    "guitarhero": "rhythm",
    "rockband": "rhythm",
    "ddr": "rhythm",
    "osu": "rhythm",

    # ---- Party ----
    "fallguys": "party",
    "amongus": "party",
    "jackbox": "party",
    "mariokartparty": "party",
    "marioparty": "party",

    # ---- Survival / sandbox ----
    "minecraft": "sandbox",
    "terraria": "sandbox",
    "valheim": "survival",
    "rust": "survival",
    "dayz": "survival",
    "green_hell": "survival",
    "thelongdark": "survival",
    "subnautica": "survival",
    "raft": "survival",

    # ---- Stealth ----
    "hitman": "stealth",
    "hitman3": "stealth",
    "dishonored": "stealth",
    "splintercell": "stealth",
    "metalgear": "stealth",
    "mgs": "stealth",
    "mgsv": "stealth",

    # ---- Roguelike / rogue-lite ----
    "hades": "roguelike",
    "hades2": "roguelike",
    "deadcells": "roguelike",
    "binding": "roguelike",
    "isaac": "roguelike",
    "risk_of_rain": "roguelike",
    "returnal": "roguelike",
    "enterthegungeon": "roguelike",
}


def normalize(name: str) -> str:
    """Lowercase, strip punctuation and digits-suffix noise for matching."""
    return "".join(c.lower() for c in name if c.isalnum())


def lookup_genre(folder_name: str) -> str | None:
    key = normalize(folder_name)
    if not key:
        return None
    if key in GENRE_LABELS:
        return GENRE_LABELS[key]
    # Longest known-token wins so 'forzahorizon' beats 'horizon'.
    candidates = sorted(
        (k for k in GENRE_LABELS if len(k) >= 5 and (k in key or key in k)),
        key=len,
        reverse=True,
    )
    return GENRE_LABELS[candidates[0]] if candidates else None
