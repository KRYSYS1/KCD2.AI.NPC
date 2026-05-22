import argparse
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
GAME_FILES = ROOT / "game_files"


def is_game_root(path: Path) -> bool:
    return (path / "Bin").is_dir() and (
        (path / "Bin" / "Win64MasterMasterSteamPGO" / "KingdomCome.exe").is_file()
        or (path / "Bin" / "Win64MasterMasterGogPGO" / "KingdomCome.exe").is_file()
    )


def detect_builds(path: Path) -> list[str]:
    builds = []
    if (path / "Bin" / "Win64MasterMasterSteamPGO" / "KingdomCome.exe").is_file():
        builds.append("Steam")
    if (path / "Bin" / "Win64MasterMasterGogPGO" / "KingdomCome.exe").is_file():
        builds.append("GOG")
    return builds


def copy_tree_contents(src: Path, dst: Path) -> tuple[int, int]:
    files = 0
    dirs = 0
    for item in src.rglob("*"):
        rel = item.relative_to(src)
        target = dst / rel
        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            dirs += 1
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, target)
            files += 1
    return files, dirs


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install KCD2 AI NPC mod files into a Kingdom Come Deliverance II game folder."
    )
    parser.add_argument(
        "game_root",
        nargs="?",
        help="Path to KCD2 game root, the folder that contains Bin\\. Example: C:\\SteamLibrary\\steamapps\\common\\KingdomComeDeliverance2",
    )
    args = parser.parse_args()

    if not GAME_FILES.is_dir():
        print(f"ERROR: game_files folder not found: {GAME_FILES}")
        return 1

    game_root = Path(args.game_root or input("KCD2 game root path: ").strip().strip('"')).expanduser()
    game_root = game_root.resolve()

    if not is_game_root(game_root):
        print("ERROR: this does not look like a KCD2 game root folder.")
        print("Expected one of:")
        print("  Bin\\Win64MasterMasterSteamPGO\\KingdomCome.exe")
        print("  Bin\\Win64MasterMasterGogPGO\\KingdomCome.exe")
        print(f"Given: {game_root}")
        return 2

    builds = detect_builds(game_root)
    print(f"Installing KCD2 AI NPC into: {game_root}")
    print(f"Detected build(s): {', '.join(builds)}")

    files, dirs = copy_tree_contents(GAME_FILES, game_root)

    print("Done.")
    print(f"Copied files: {files}")
    print(f"Ensured folders: {dirs}")
    print("Start/restart the game after installation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
