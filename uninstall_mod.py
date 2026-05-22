import argparse
import shutil
import sys
from pathlib import Path


MOD_PATHS = [
    "scripts/mods/ai_npc.lua",
    "Scripts/mods/ai_npc.lua",
    "Data/Scripts/mods/ai_npc.lua",
    "Data/Scripts/Utils/ai_npc_init.lua",
    "Data/Scripts/ai_npc",
    "Data/Libs/Config/ai_npc_actions.xml",
    "Localization/text__ai_npc.xml",
    "Localization/English_xml/text__ai_npc.xml",
    "Localization/Russian_xml/text__ai_npc.xml",
    "mods/ai_npc",
    "Bin/Win64MasterMasterSteamPGO/plugins/ai_npc",
    "Bin/Win64MasterMasterSteamPGO/version.dll",
    "Bin/Win64MasterMasterSteamPGO/kcd2_ainpc_plugin.log",
    "Bin/Win64MasterMasterGogPGO/plugins/ai_npc",
    "Bin/Win64MasterMasterGogPGO/version.dll",
    "Bin/Win64MasterMasterGogPGO/kcd2_ainpc_plugin.log",
]


def is_game_root(path: Path) -> bool:
    return (path / "Bin").is_dir() and (
        (path / "Bin" / "Win64MasterMasterSteamPGO" / "KingdomCome.exe").is_file()
        or (path / "Bin" / "Win64MasterMasterGogPGO" / "KingdomCome.exe").is_file()
    )


def remove_empty_parents(path: Path, stop_at: Path) -> None:
    current = path.parent
    stop_at = stop_at.resolve()
    while current != stop_at and stop_at in current.resolve().parents:
        try:
            current.rmdir()
        except OSError:
            break
        current = current.parent


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Remove KCD2 AI NPC mod files from a Kingdom Come Deliverance II game folder."
    )
    parser.add_argument(
        "game_root",
        nargs="?",
        help="Path to KCD2 game root, the folder that contains Bin\\.",
    )
    parser.add_argument("--yes", action="store_true", help="Do not ask for confirmation.")
    args = parser.parse_args()

    game_root = Path(args.game_root or input("KCD2 game root path: ").strip().strip('"')).expanduser().resolve()

    if not is_game_root(game_root):
        print("ERROR: this does not look like a KCD2 game root folder.")
        print(f"Given: {game_root}")
        return 2

    existing = [game_root / rel for rel in MOD_PATHS if (game_root / rel).exists()]
    if not existing:
        print("No KCD2 AI NPC mod files found.")
        return 0

    print(f"KCD2 game root: {game_root}")
    print("The following mod files/folders will be removed:")
    for item in existing:
        print(f"  - {item.relative_to(game_root)}")

    if not args.yes:
        answer = input("Remove these files? Type YES to continue: ").strip()
        if answer != "YES":
            print("Cancelled.")
            return 0

    removed = 0
    for item in sorted(existing, key=lambda p: len(p.parts), reverse=True):
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()
            remove_empty_parents(item, game_root)
        removed += 1

    print("Done.")
    print(f"Removed entries: {removed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
