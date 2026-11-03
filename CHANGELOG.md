# Changelog

## 1.0.0 — 2026-11-04

The first public release.

- Menu and hidden commands: full processing, preparation only, comparison only, a queue of dictionaries, merge, split.
- One pass from the input to the result: preparation → `sort -u` → `comm -13` with each reference, no intermediate files.
- Preparation: UTF-16 → UTF-8; automatic Windows-1251, KOI8-R and CP866 detection, mixed files converted line by line; CRLF and BOM (also U+FEFF inside lines); words from UTF-16 inside a UTF-8 file; three kinds of mojibake; invalid UTF-8, U+FFFD and control characters; length and digits-only filters with optional saving of the removed lines.
- References in `Compare Files/` as generations, checked and fixed only with consent.
- WSL: work in a Linux temp folder when the files are on a Windows drive.
- Progress on long steps, a log of every action, statistics per step.
- Russian and English interface: chosen by the system language, menu item 8, `--lang` or `DEDUP_LANG`.
