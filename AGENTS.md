# Working on ios-fajita

- Read `NOTES.md` before starting; it contains the project architecture, OnePlus 6T (fajita / SDM845) hardware facts, memory maps, and debugging procedures.
- When continuing or handing off work between agents, update `NOTES.md` with commits, CI run IDs, boot outcomes, and newly verified subsystems.
- All kernel builds run via GitHub Actions (`.github/workflows/xnu.yml`) using `gh workflow run xnu.yml -f machine_config=FAJITA`.
- Test boots on hardware should use temporary `fastboot boot` images (`shim/out/shim-boot.img`) so that stock recovery and partitions are never corrupted.
- Preserve all device backups (`persist`, `modemst1`, `modemst2`, `fsg`, `fsc`, `boot`). Never flash to partition tables (GPT).
- Verify repository health at every milestone:
  ```sh
  python3 tools/validate-repo.py
  ```
