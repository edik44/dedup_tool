# dedup_tool

**One Bash script for big wordlists.** It cleans a dictionary — encodings, mojibake, invisible garbage, length and digit filters — and removes every line that is already in your reference files. Everything runs in one pass, with a menu, in English or Russian.

A typical use: you collect password or login dictionaries from different sources and want each new one to keep only the lines you do not have yet.

[Русская версия](README.ru.md)

## What it does

- **One pass, no intermediate files.** Preparation → `sort -u` → `comm -13` with each reference → `<name>_final.txt`. Only the result is written, plus the temporary files of `sort` itself when the data does not fit in memory.
- **Preparation.** Each step is a question with a sensible default, and the count and examples come before it:
  - UTF-16 → UTF-8 (by the BOM or by null bytes);
  - single-byte Cyrillic (Windows-1251, KOI8-R, CP866) is recognized automatically; a mixed file is converted line by line, and its UTF-8 lines are left alone;
  - CRLF and BOM, also an invisible U+FEFF inside lines;
  - words written in UTF-16 inside a UTF-8 file (a NUL after each letter);
  - mojibake: UTF-8 read as Windows-1252 or Latin-1 (`Ã©tÃ©` → `été`), Russian DOS text read as Windows-1251, UTF-8 read as Windows-1251;
  - invalid UTF-8, the replacement character U+FFFD, control characters;
  - length and digits-only filters; the removed short lines and digit lines can be saved to `<name>_short.txt` and `<name>_digits.txt`.
- **References** live in `Compare Files/`. Each file is one "generation" of the comparison, in name order. They are checked (CRLF/BOM, order, duplicates) and fixed only with your consent.
- **Queue.** Several dictionaries in a row: each is cleaned of the references and of the results of all previous ones, so the results never overlap.
- **Merge** results into one file, **split** a file into parts.
- **WSL.** If the files are on a Windows drive (`/mnt/c`, `/mnt/d`), the script offers to work in a Linux temp folder: line-by-line writing through the WSL bridge is hundreds of times slower.
- Progress on long steps, a log of every action, statistics per step. It also notices an archive renamed to `.txt`, a working file that is a copy of a reference, and result lines with spaces at the edges.

## Requirements

- Bash 4.2 or newer (5.x recommended), GNU coreutils (`sort`, `comm`, `split`, `stat`, `mkfifo`, `df`, `od`), GNU `grep` with `-P`, GNU `sed`, `awk`, `iconv`.
- Works in **Git for Windows** (Git Bash), **WSL** and **Linux**. macOS is not tested; it needs the GNU tools (`brew install coreutils grep gnu-sed`).
- On Windows you need [Git for Windows](https://git-scm.com/download/win) (free): it brings bash and these tools. `dedup_tool_first_windows_start.bat` checks for it and offers to install it.

## Install

### Windows

1. Download `dedup_tool.sh` and `dedup_tool_first_windows_start.bat` from the [latest release](https://github.com/edik44/dedup_tool/releases/latest) and put both into the folder with your dictionaries.
2. Double-click `dedup_tool_first_windows_start.bat`. It checks for Git for Windows and, if it is missing, offers to install it with winget (Windows asks for administrator rights) or to open the download page. Then the menu starts in that folder.
3. After that the `.bat` is not needed: double-click `dedup_tool.sh` itself — Git for Windows opens `.sh` files in Git Bash. Delete the `.bat` or keep it, it works every time.
4. Windows may warn that the file comes from the internet: allow it to run (SmartScreen: "More info" → "Run anyway").

### Linux, WSL, Git Bash

```bash
git clone https://github.com/edik44/dedup_tool.git
cd dedup_tool
chmod +x dedup_tool.sh
./dedup_tool.sh --help
```

In Linux and WSL keep the `./` in front of the name: the current folder is not in `PATH`, and without it you get `command not found`.

Or download only `dedup_tool.sh` and put it next to your dictionaries.

## Usage

Put your dictionaries (`*.txt`) next to the script and the reference files into `Compare Files/`:

```
your_folder/
├── dedup_tool.sh
├── dedup_tool_first_windows_start.bat  ← the first start on Windows
├── new_words.txt            ← working files
├── more_words.txt
└── Compare Files/
    ├── 01_base.txt          ← references, one generation each
    └── 02_other_base.txt
```

Run `./dedup_tool.sh` (on Windows — a double click on it; the very first time — on `dedup_tool_first_windows_start.bat`) and choose an item:

```
  1) Full processing: preparation and comparison with references → <name>_final.txt
  2) Preparation only (encoding, CRLF/BOM, filters) → <name>_prep.txt
  3) Comparison with references only, the file as is → <name>_final.txt
  4) Several dictionaries in a queue: each is also cleaned of the previous ones → _final for each
  5) Merge _final results into one file → merged.txt and the list of files merged_list.txt
  6) Split a finished file into parts
  7) Help
  8) Language / Язык: English
  0) Exit
```

The script never changes your working files; after a queue it moves them to `originals_<date-time>/`. References are fixed only after a question.

### Without the menu

```bash
./dedup_tool.sh full words.txt
./dedup_tool.sh clean words.txt
./dedup_tool.sh compare [file...]
./dedup_tool.sh queue a.txt b.txt c.txt
./dedup_tool.sh merge [file...]
./dedup_tool.sh split words.txt 4
```

`split` also takes a part size: `500M`, `2G`. The answers can be given through stdin, for example `printf 'y\nn\nn\n' | ./dedup_tool.sh full raw.txt`; with `</dev/null` every question takes its default.

### Language

The interface follows the system language; in Git Bash and WSL it follows the Windows language. Change it with menu item 8 (the choice is saved), with `--lang en` or `--lang ru`, or with the variable `DEDUP_LANG=en`.

## What it looks like

The numbers below are made up:

```
=== One pass to the result ===
Steps: iconv (WINDOWS-1251 → UTF-8) → CRLF/BOM → UTF-8 check → control characters → length 8–18 → sort (memory up to 3.2 GB) → reference base.txt → words_final.txt
Input lines: 2,500,000
  − unreadable (not UTF-8 or U+FFFD): 0
  − with control characters: 12
  − length outside 8–18: 840,210
  − duplicates within the file: 3,904
  − in reference base.txt (generation 1): 1,402,551
▐► Generations processed: 1 of 1
✔ Final file: words_final.txt — lines: 253,323, 5 MB (2.1 s)
```

A result converted from Windows-1251 can be bigger than the source: in UTF-8 a Cyrillic letter takes 2 bytes instead of 1. The script says so when it happens.

## Big files

- **Git Bash or WSL.** Dictionaries up to about 1 GB are comfortable in Git Bash, right on Windows (it depends on the PC). Bigger ones are better in WSL: the same work runs there 3–4 times faster (a 95 MB dictionary with a 48 MB reference: 12 s in Git Bash, 3.5 s in WSL).
- **Memory.** `sort` takes up to half of the free memory and up to 8 threads; what does not fit goes into its temporary files next to the result. In WSL the Linux file cache takes the rest, so WSL looks almost full in the Task Manager — this is normal. `wsl --shutdown` returns the memory after the work.
- **Disk.** In WSL a 6.5 GB dictionary with an 8.1 GB reference means, by estimate, about 70 GB written the first time (copies to the Linux folder and back, sorting the reference, the temporary files of `sort`, the result) and about 40 GB later. You need about three times the size of the dictionaries and references together in free space. Keep big files inside Linux (`\\wsl.localhost\<distribution>\home\<user>` in Explorer) — then nothing is copied.
- **HDD.** It works, but slower: especially copying when the dictionaries and the Linux disk are on the same HDD, and sorting big files. If you have an SSD, keep the Linux disk (`ext4.vhdx`) and the working folder there.

## Compared with other tools

The core job — removing the lines that are in other files — is also done by [rling](https://github.com/Cynosureprime/rling) and by `rli`/`rli2` from [hashcat-utils](https://github.com/hashcat/hashcat-utils); [duplicut](https://github.com/nil0x42/duplicut) removes duplicates without sorting. They are fast tools with command-line options. dedup_tool is about everything around that job: the preparation before the comparison (encodings, mojibake, invisible garbage, words from UTF-16), generations and queues, WSL and logs — with a menu and questions instead of options.

## License

MIT — see [LICENSE](LICENSE).
