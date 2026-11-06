# Changelog

## 1.2.0 — 2026-11-06

- **New license from this version:** still free for any use, including at work, but selling the script or programs based on it, charging for a service built on it, and collecting donations for them are not allowed without the author's written permission. See `LICENSE`. Versions 1.0.0 and 1.1.0 stay under the MIT License.
- **Dictionary tools**, menu item 7 and `tool <name>`: emails to logins, `user:pass` to logins and passwords, any separator, emails, links and IPs out of a dump, keyboard layout RU ↔ EN, case, spaces, trimming, removing lines by a piece, splitting by alphabets, the most frequent lines, duplicates without sorting, search across dictionaries. The source file stays unchanged, the result is a new file.
- Menu: item 7 is the tools, 8 is the language, 9 is the help.
- New kind of mojibake: Russian DOS text (CP866) that lost its high bit — the letter «а» became a space, other letters became signs. Recognized by the whole file, restored with the same question; lines with digits or Latin letters stay as they are.
- A CR inside a line is no longer treated as CRLF: its own count, examples and question, such lines are split. The CRLF question appears only when a CR ends a line (before, answering yes could change nothing).
- Empty lines and lines of only spaces or tabs: a count and a question during preparation, Enter removes them. Item 3 only warns about them.
- Known issues, also in 1.1.0: the UTF-8 check shows the number of removed lines only afterwards, and a file with several one-byte encodings at once is not recognized; symbols and CJK text in UTF-8 read as Windows-1251 can be taken for DOS mojibake; KOI8-R text read as Windows-1251 is not recognized.

## 1.1.0 — 2026-11-05

- `dedup_tool_first_windows_start.bat` for the first start on Windows: put it next to `dedup_tool.sh` and double-click it. It finds Git for Windows (Git Bash) and runs the script in its folder, showing where Git was found; if Git is missing, it offers to install it with winget or to open the download page. After that a double click on `dedup_tool.sh` itself is enough. Russian and English messages, by the Windows language or `--lang`.
- The help tells how to start the script on Windows, and that dictionaries up to about 1 GB are comfortable in Git Bash, while bigger ones are 3–4 times faster in WSL.

## 1.0.0 — 2026-11-04

The first public release.

- Menu and hidden commands: full processing, preparation only, comparison only, a queue of dictionaries, merge, split.
- One pass from the input to the result: preparation → `sort -u` → `comm -13` with each reference, no intermediate files.
- Preparation: UTF-16 → UTF-8; automatic Windows-1251, KOI8-R and CP866 detection, mixed files converted line by line; CRLF and BOM (also U+FEFF inside lines); words from UTF-16 inside a UTF-8 file; three kinds of mojibake; invalid UTF-8, U+FFFD and control characters; length and digits-only filters with optional saving of the removed lines.
- References in `Compare Files/` as generations, checked and fixed only with consent.
- WSL: work in a Linux temp folder when the files are on a Windows drive.
- Progress on long steps, a log of every action, statistics per step.
- Russian and English interface: chosen by the system language, menu item 8, `--lang` or `DEDUP_LANG`.
