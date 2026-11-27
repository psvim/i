# i

Small shell scripts you can run with one command. Paste a line into your terminal, pick a category, pick a script, and it runs. Nothing is installed, and nothing is left behind.

**Browse the menu online:** [psv.im/i](https://psv.im/i)

## Run it

```bash
bash <(curl -fsSL psv.im/i/init.sh)
```

If your shell doesn’t support that form, use the pipe version:

```bash
curl -fsSL psv.im/i/init.sh | bash
```

You need `curl` and `tar`, on Linux or macOS. That’s all.

## What you’ll see

Categories are just folders in this repo — there’s no fixed list of them. Whatever folders exist at the time you run it is what you’ll see, in alphabetical order, each with how many scripts it holds. You pick a category first, then a script from inside it:

```
================ Categories ================
  1) <category-a>              (N)
  2) <category-b>              (N)
  3) <category-b>/<sub-folder> (N)
  ...
----------------------------------------------------------
  a) All scripts (N total)
  q) Quit
Select a category:
```

Pick a number to open that category (or `a` to see every script together, from every category), then pick a script from the list:

```
================ <category>  (N total) ================
  1) Name - short description  [<category>/script.sh]
  2) Name - short description  [<category>/script.sh]
----------------------------------------------------------
  b) Back to categories
  q) Quit
Select a number:
```

Each category list shows 8 scripts per page, however many scripts that category grows to.

| Key | What it does |
| --- | --- |
| a number (category screen) | Opens that category |
| `a` (category screen) | Lists every script, from every category, together |
| a number (script screen) | Runs that script. Numbers stay the same on every page. |
| `n` | Next page |
| `p` | Previous page |
| `b` | Back to the category list |
| `q` | Quit |

When a script finishes, you’re back on the same page of that category's list.

Want more or fewer per page? Set `PAGE_SIZE`:

```bash
PAGE_SIZE=12 bash <(curl -fsSL psv.im/i/init.sh)
```

This controls how many scripts show per page inside a category (and in "All scripts" mode) — it defaults to 8, and doesn't affect the categories screen, which always lists every category at once. An invalid or `0` value is ignored and falls back to 8.

## How it works

1. `init.sh` downloads the repo into a temporary folder.
2. It finds every `.sh` file, in any folder, at any depth, except itself.
3. The category of a script is simply its folder path (a script sitting at the repo root would show as `general`). Nested folders become their own category, shown by their full path — e.g. a script in `cybersecurity/exploit/web/` shows under the category `cybersecurity/exploit/web`.
4. It builds the category list from whatever folders actually contain a `.sh` file right now — nothing is hardcoded, so folders are picked up or drop off the list automatically as scripts are added or removed. An empty folder with no scripts in it never shows up as a category.
5. Once you pick a category, it reads line 2 of each file in it and shows it as `Name - description`.
6. The script you pick runs in your current folder. The temporary folder is deleted when you quit.

[`index.html`](index.html) (the page at [psv.im/i](https://psv.im/i)) works the same way: it reads the repo's file tree live from GitHub, so its category list, filter dropdown, and script list all stay in sync with whatever folders and scripts actually exist — no part of the site needs editing when you add, rename, or remove a category.

Want to run a single script without the menu? Use its path directly:

```bash
bash <(curl -fsSL psv.im/i/path/to/script.sh)
```

## Add your own script

Anyone can contribute through a fork and a pull request. Once it’s merged, the script appears in the menu and on [psv.im/i](https://psv.im/i), filed under its folder as a category, with nothing else to edit.

1. [Fork this repo](https://github.com/psvim/i/fork) and clone your copy:
   ```bash
   git clone https://github.com/<your-username>/i.git
   cd i
   git remote add upstream https://github.com/psvim/i.git
   git checkout -b add-my-script
   ```
2. Put your `.sh` file inside the folder for the category it belongs in. Using an existing folder adds it to that category; using a new folder name creates a brand-new category automatically. Nest folders as deep as you like for sub-categories. Line 2, right after the shebang, must be the label:
   ```bash
   #!/usr/bin/env bash
   # Name - short description of what it does

   echo "Hello from my script"
   ```
3. Test it with `bash your-script.sh`.
4. Push to your fork and open a pull request against `main`.

A few ground rules:

- Keep the description short. It’s what people see in the menu.
- No secrets, tokens or personal data.
- Ask for confirmation before anything destructive, such as deleting or overwriting files.
- If line 2 is missing, the script still shows up, using its filename and “(no description)”.
- A script placed directly at the repo root (no folder) is filed under the `general` category.

## What’s in this repo

The repo root only holds the launcher and the site — every script lives inside a folder, and every folder is a category:

| Path | Purpose |
| --- | --- |
| `init.sh` | The menu launcher |
| `index.html` | The page at [psv.im/i](https://psv.im/i). It lists the scripts and categories live from this repo. |
| `.nojekyll` | Tells GitHub Pages to serve files as they are, with no Jekyll processing |
| `README.md` | This file |
| any other folder | A category. Its name is whatever the folder is called, and it can be nested (e.g. `cybersecurity/recon/`) for a sub-category. Browse the repo itself to see the categories that currently exist. |

There’s no list of categories to maintain anywhere — add, rename, remove, or nest a folder, and `init.sh` and `index.html` both reflect it the next time they run, automatically.

The site is served by GitHub Pages from the `main` branch.

## Good to know

- **Only run what you trust.** The launcher runs whatever is on the `main` branch. Read [`init.sh`](init.sh) before you run it.
- **Scripts run where you are.** They start in the folder you launched the menu from.
- **Different branch?** Change `BRANCH` at the top of `init.sh`.

Made by [psvim](https://psv.im).
