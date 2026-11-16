# Changelog

## 1.5.0 — 2026-11-16

- **Dictionary analysis**, menu item 8 and `analyze <file>...`: read only. The same checks the preparation makes before its questions and a pass without writing with the default answers: how many lines would be left and what the dictionary is made of (length, digit lines, characters, emails and `user:pass` pairs, alphabets), then what to do in order and what to run right away with the same answers (item 2 or 1, tool 7.11). Several files at once — only the reports. The menu is now: 9 — sorting, 10 — language, 11 — help.
- **A file with several one-byte encodings at once** is converted line by line, each line from its own: Windows-1251, KOI8-R or CP866 by Russian letter pairs (in Windows-1251 also Belarusian and Ukrainian і ў ї є ґ), Western text from Windows-1252 when its accented letters stand next to Latin ones. The lines that fit none stay as they are: the UTF-8 check removes them, they can be saved to `<name>_notutf8.txt`, and you see what they look like.
- **New kinds of mojibake:** Western text in Windows-1252 read as Windows-1251 (`Mьller` → `Müller`) and emoji in CESU-8 read as Windows-1251.
- **Soft hyphen as the byte AD** inside a Latin word (the line is not UTF-8 only because of it): its own count, examples and question; the step goes first.
- If the sample points to one encoding for the lines not in UTF-8, it is suggested in colour and used by Enter; `-` means no conversion, just remove them. An encoding typed for a file that is mostly UTF-8 converts only the lines not in UTF-8.
- **Queue** (item 4): the dictionaries are cleaned of each other only, the references from `Compare Files/` are not used (item 1 does that). Enter takes all files except results of tools; tool results are marked in file lists.
- **For big files the counts of the checks are remembered** (`logs/.dedup_cache`: path, size, time, version): a repeated analysis or preparation of an unchanged file does not read it again. `--recheck` or `DEDUP_RECHECK=1` recounts. The checks before the questions run in parallel.
- **Tools** (item 7): tool 4 also cuts `user:pass` pairs (from links too) and MACs; tool 9 can keep instead of remove, take whole lines or a regular expression, ignore case and save the removed lines; tool 13 can ignore case or look only at the part before a separator. New: 10 — transliteration (`привет` → `privet`), 17 — keep only the common lines, 18 — order by frequency or length, 19 — random order. Splitting by alphabets … removing other dictionaries are now 11–16.
- **Report:** in columns, empty lines between blocks; «Bigger than the source» names the encodings that were really converted; after the analysis a wrong number asks again; when nothing would be left, items 1 and 2 are not offered.
- Known issues: Windows-1250 is not among the line-by-line encodings yet; Belarusian words without і and ў are told by Russian letter pairs only.

## 1.4.0 — 2026-11-11

- **Temp files and memory for sorting**, menu item 9: put the temporary files of `sort` into another folder or on another disk (for example a removable one) and set its memory — automatic, a size (`4G`) or a share of the free memory (`70%`). Saved like the language; also `DEDUP_SORT_TMP` and `DEDUP_SORT_MEM`. The help is now item 10.
- Typed answers (a folder, an encoding, numbers) can be edited with the arrow keys, Home, End, paste and Tab. Before, an arrow key went into the answer as invisible bytes, and a folder with odd characters in its name could appear.
- **Merge** (item 5): `all` takes every file of the folder, not only `_final` results; every merge is added to one log `merged_list.txt`; after it you can move the merged files to `originals_<date-time>/`.
- The menu tells where duplicates are removed.
- **Lines not in UTF-8:** their share of the file and what they look like (Windows-1251, KOI8-R, CP866, Western languages); if almost the whole file is not UTF-8, Enter at the encoding question asks again instead of removing everything; after `_notutf8.txt` — how to sort it out.
- **A byte the encoding has no character for** (98 in Windows-1251 — the letter Ш in DOS text) is no longer cut out of the word silently: a count and a question — keep such lines for the second step (restoring the mojibake brings the letter back) or remove them now.
- **Mojibake:** text damaged twice is restored in one pass; a line cut in the middle of a letter keeps its full letters; the DOS rule no longer takes lines that are mostly ASCII signs; examples show the final result of all steps, KOI8-R shows words first.
- **Soft hyphen** (U+00AD) inside a word: a count, examples and a question. In mojibake the same character is part of a letter, such lines are not counted.
- Examples show bytes that are not UTF-8 as `�`, so the log stays valid UTF-8.
- Tool 10 does not copy the file when it has only one alphabet; tool 15 warns about lines not in UTF-8.
- Known issues: Western words read as Windows-1251 (`Mьller`) and emoji in CESU-8 are not restored yet; a file with several one-byte encodings needs two runs of item 2 (the script tells how).

## 1.3.0 — 2026-11-07

- **New kind of mojibake:** Russian KOI8-R text read as Windows-1251 (`РТЙЧЕФ` → `привет`). Only if most lines in capitals look so, and letter pair frequencies check each line; a real word in capitals is sometimes converted too, a short one more often, so the question stays yours.
- UTF-8 of any characters read as Windows-1251 is restored too (`cafГ©` → `café`), not only Russian letters. Before, the DOS rule could turn such lines into Russian nonsense: this is fixed.
- A line of DOS signs only (`¤®¬` → `дом`) is restored if the file already has DOS mojibake.
- Lines not in UTF-8: if the encoding is not found, you are told how many lines the check removes before the question, and they can be saved to `<name>_notutf8.txt`.
- Queue: the menu lists files from the biggest to the smallest, so Enter is enough; a short summary line per file; with many references the screen shows only their number, the names go to the log.
- Lines with spaces or tabs at the edges of a result: only a count now, no question. New tool 14 moves such lines out or trims them on the right or left, and can replace the file itself if you ask.
- New tool 15 removes from a file the lines of other dictionaries (`<name>_minus.txt`), without `Compare Files`.
- After tools 1–4 you can save the dictionary without the lines something was extracted from (`<name>_rest.txt`). Tool 6 can make all four files at once. Tool 11 tells when the end of its list is chosen among equal counts.
- The warning of item 3 is about ten times faster.
- Known issues: the DOS rule can still take a line that is mostly ASCII signs; text damaged twice needs a second run of item 2; a file with several one-byte encodings at once is not recognized — give one encoding by hand, then run item 2 on the result.

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
