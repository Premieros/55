# Johns Local Print Service (Windows)

This service lets the browser POS route kitchen tickets to different Windows printers without showing the browser print dialog.

## What it does

- Runs only on `127.0.0.1:17654`.
- Reads printers installed in Windows.
- Stores printer names locally in `printer-config.json` on this terminal only.
- Routes each KDS station code to a Windows printer.
- The POS keeps the normal browser print as a fallback if the local service is unavailable or a station is not configured.

## Branch setup

1. Install both thermal printers in Windows and confirm a Windows test page prints from each one.
2. Install Node.js LTS on the cashier PC if it is not already installed.
3. Run `start.cmd` from this folder.
4. The configuration page opens at `http://127.0.0.1:17654/`.
5. Map stations for the current Johns production data:
   - `drinks` -> the barista/drinks printer.
   - `main` -> the kitchen/food printer.
6. Use **Test Print** on both mappings before the first real order.
7. In Johns, drink categories must be assigned to the `drinks` kitchen station; food categories stay on `main`. The server, not the browser, decides each item's station.

## Important

Do not store physical Windows printer names in Supabase. They belong to this PC and can differ between terminals.

The print agent must be running while the browser POS is open. If it is not running, Johns falls back to the existing browser kitchen print flow rather than silently dropping the ticket.
