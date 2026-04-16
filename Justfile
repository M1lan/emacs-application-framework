# Justfile for emacs-application-framework (EAF)
#
# EAF is a framework that embeds graphical applications (browser, PDF viewer,
# terminal, etc.) inside Emacs via PyQt6/QtWebEngine.
#
# Layout:
#   eaf.el / eaf.py         core framework (Elisp + Python EPC bridge)
#   core/                   shared Python modules (buffer, view, webengine, utils)
#   core/js/                injected browser JS (markers, dark mode, autofill)
#   extension/              optional Elisp integrations (evil, org, interleave)
#   app/                    cloned per-app repos (browser, pdf-viewer, ...)
#   install-eaf.py          installer / dependency manager
#   sync-eaf-resources.py   Gitee mirror sync helper
#   dependencies.json       per-distro system + uv + pnpm deps
#   applications.json       app catalog (name, url, branch, default_install)
#
# Conventions:
#   - Use `just` (no args) to see the default recipe (help).
#   - Python deps are managed via `uv pip install --system`.
#   - Node deps are managed via `pnpm`.
#   - All `app-*` recipes operate on the `app/` directory.
#   - Recipes tagged `[fzf]` require fzf on PATH.

set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments := true

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

# Editor for open/edit recipes.
editor := env_var_or_default("EDITOR", "emacsclient -c -a zile")

# App directory where per-app repos are cloned.
app_dir := "app"

# Python interpreter.
python := "python3"

# ---------------------------------------------------------------------------
# Meta
# ---------------------------------------------------------------------------

# Default recipe: show the help listing.
default: help

# Print every recipe with its documentation line.
help:
    @just --list --unsorted

# Print resolved variables.
vars:
    @echo "editor   = {{editor}}"
    @echo "app_dir  = {{app_dir}}"
    @echo "python   = {{python}}"

# Print environment info useful for bug reports.
info:
    @echo "python:  $({{python}} --version 2>/dev/null || echo 'not installed')"
    @echo "uv:      $(uv --version 2>/dev/null || echo 'not installed')"
    @echo "node:    $(node --version 2>/dev/null || echo 'not installed')"
    @echo "pnpm:    $(pnpm --version 2>&1 | head -1 || echo 'not installed')"
    @echo "emacs:   $(emacs --version 2>/dev/null | head -1 || echo 'not installed')"
    @echo "just:    $(just --version)"
    @echo "os:      $(uname -srm)"
    @echo "git:     $(git --version 2>/dev/null || echo 'not installed')"

# ---------------------------------------------------------------------------
# Install / update
# ---------------------------------------------------------------------------

# Run the full EAF installer (update core + existing apps + deps).
install:
    {{python}} install-eaf.py

# Install core deps only (system + Python), skip apps.
install-core:
    {{python}} install-eaf.py --install-core-deps

# Install/update all available apps (including ones not yet cloned).
install-all:
    {{python}} install-eaf.py --install-all-apps

# Interactively install previously-uninstalled or newly-added apps.
install-new:
    {{python}} install-eaf.py --install-new-apps

# Install a specific app by name, e.g. `just install-app browser`.
install-app app:
    {{python}} install-eaf.py -i {{app}}

# Force reinstall of all app deps (removes node_modules, re-fetches).
install-force:
    {{python}} install-eaf.py --force

# Pull latest EAF core and run installer.
update: pull install

# ---------------------------------------------------------------------------
# Python: lint, check, test
# ---------------------------------------------------------------------------

# Byte-compile all Python files as a smoke check.
py-check:
    {{python}} -m compileall -q . -x 'node_modules|__pycache__|\.git'

# Lint core Python files with ruff (if installed).
py-lint:
    ruff check eaf.py install-eaf.py sync-eaf-resources.py core/

# Auto-fix Python lint issues with ruff.
py-fix:
    ruff check --fix eaf.py install-eaf.py sync-eaf-resources.py core/

# Format Python files with ruff.
py-fmt:
    ruff format eaf.py install-eaf.py sync-eaf-resources.py core/

# Check Python formatting without modifying files.
py-fmt-check:
    ruff format --check eaf.py install-eaf.py sync-eaf-resources.py core/

# ---------------------------------------------------------------------------
# Elisp: lint
# ---------------------------------------------------------------------------

# Byte-compile all .el files with Emacs batch mode (warnings only, no error exit).
el-check:
    emacs --batch -Q -L . -L core -L extension \
        --eval '(setq byte-compile-error-on-warn nil)' \
        --eval '(defvar eaf-config-location (expand-file-name "eaf" user-emacs-directory))' \
        -f batch-byte-compile eaf.el core/eaf-epc.el \
        $(fd -e el . extension/) || true

# Remove compiled .elc files.
el-clean:
    fd -e elc . -x rm -f {}

# ---------------------------------------------------------------------------
# Full lint / verify
# ---------------------------------------------------------------------------

# Lint Markdown files with rumdl (report only, non-blocking for upstream files).
rumdl:
    rumdl check . || true

# Lint shell scripts with shellcheck.
shellcheck:
    fd -e sh -e bash --type f . -x shellcheck {}

# Full lint pass: Python + Elisp + Markdown + Shell.
lint: py-check py-lint el-check rumdl shellcheck

# Quick pre-push check: Python compile + format check.
check: py-check py-fmt-check

# ---------------------------------------------------------------------------
# Apps
# ---------------------------------------------------------------------------

# List all installed EAF applications.
apps:
    @ls {{app_dir}} 2>/dev/null || echo "No apps installed. Run 'just install-new' first."

# List all available apps from the catalog.
apps-available:
    #!/usr/bin/env python3
    import json
    d = json.load(open("applications.json"))
    for k, v in d.items():
        if v["type"] == "app":
            print(f"  {k:24s} {v['name']:40s} (default: {v['default_install']})")

# Show dependencies for a specific app, e.g. `just app-deps browser`.
app-deps app:
    @cat {{app_dir}}/{{app}}/dependencies.json 2>/dev/null || echo "No dependencies.json for {{app}}"

# Update a single app (git pull), e.g. `just app-update browser`.
app-update app:
    git -C {{app_dir}}/{{app}} pull

# Update all installed apps in parallel.
apps-update:
    #!/usr/bin/env bash
    for d in {{app_dir}}/*/; do
        app=$(basename "$d")
        echo "[EAF] Updating $app..."
        git -C "$d" pull &
    done
    wait
    echo "[EAF] All apps updated."

# Show git status of all installed app repos.
apps-status:
    #!/usr/bin/env bash
    for d in {{app_dir}}/*/; do
        app=$(basename "$d")
        status=$(git -C "$d" status --porcelain 2>/dev/null)
        branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -n "$status" ]]; then
            echo "  $app ($branch) [dirty]"
        else
            echo "  $app ($branch)"
        fi
    done

# ---------------------------------------------------------------------------
# Node (pnpm) helpers
# ---------------------------------------------------------------------------

# Run pnpm install in every app that has a package.json.
node-install:
    #!/usr/bin/env bash
    for pkg in $(fd 'package.json' {{app_dir}} --max-depth 2); do
        dir=$(dirname "$pkg")
        echo "[EAF] pnpm install @ $dir"
        pnpm install --dir "$dir"
    done

# Remove all node_modules directories under app/.
node-clean:
    fd -t d 'node_modules' {{app_dir}} -x rm -rf {}

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

# Remove all Python bytecode caches.
clean-pyc:
    fd -H -t d '__pycache__' . -x rm -rf {}
    fd -H -t f -e pyc . -x rm -f {}

# Remove compiled .elc files + Python caches.
clean: clean-pyc el-clean

# Full clean: Python caches + .elc + node_modules.
clean-all: clean node-clean

# Count lines of code by language.
loc:
    @tokei . --exclude app --exclude node_modules 2>/dev/null \
        || echo "Install tokei for LoC counts: cargo install tokei"

# Show the dependency tree from dependencies.json.
deps:
    #!/usr/bin/env python3
    import json
    d = json.load(open("dependencies.json"))
    for k, v in d.items():
        if isinstance(v, dict):
            print(f"  {k}:")
            for k2, v2 in v.items():
                print(f"    {k2}: {v2}")
        else:
            print(f"  {k}: {v}")

# ---------------------------------------------------------------------------
# Git shortcuts
# ---------------------------------------------------------------------------

# Pull latest from upstream.
pull:
    git pull

# Show log as oneline graph (last 20 commits).
log:
    git log --oneline --graph --decorate -20

# Amend the last commit without editing the message.
amend:
    git add -A && git commit --amend --no-edit

# Show what changed since last commit.
diff:
    git diff

# ---------------------------------------------------------------------------
# Search / explore
# ---------------------------------------------------------------------------

# Search for a pattern across all Python + Elisp files.
search pattern:
    rg "{{pattern}}" --type py --glob '*.el' --glob '*.js' -g '!node_modules'

# Search only core framework files (not apps).
search-core pattern:
    rg "{{pattern}}" eaf.py eaf.el core/ extension/ install-eaf.py

# Show project tree (excludes node_modules and __pycache__).
tree:
    eza -Td -L3 -I 'node_modules|__pycache__|.git'

# Show project tree including apps (depth 2).
tree-full:
    eza -Td -L2

# ---------------------------------------------------------------------------
# fzf-powered workflows
# ---------------------------------------------------------------------------

# [fzf] Categorized menu -- the main entry point for interactive workflows.
fzf:
    #!/usr/bin/env bash
    # Build menu with categories and descriptions.
    # Lines with ── are category headers. Lines with * are recommended.
    menu=$(printf '%s\n' \
        "── ESSENTIALS ──────────────────────────" \
        "* update            Pull + reinstall everything" \
        "* lint              Full lint pass (py + el + md + sh)" \
        "* info              Environment diagnostics" \
        "── INSTALL ─────────────────────────────" \
        "  install           Run the standard installer" \
        "  install-new       Add newly-available apps" \
        "  install-all       Install every app in the catalog" \
        "  apps-pick         Pick a single app to install" \
        "── CODE QUALITY ────────────────────────" \
        "  py-lint           Ruff lint (Python)" \
        "  py-fix            Ruff auto-fix (Python)" \
        "  py-fmt            Ruff format (Python)" \
        "  el-check          Byte-compile Elisp" \
        "  rumdl             Lint Markdown" \
        "  check             Quick pre-push check" \
        "── APPS ────────────────────────────────" \
        "  apps              List installed apps" \
        "  apps-available    Show full app catalog" \
        "  apps-status       Git status of all app repos" \
        "  apps-update       Pull latest for all apps" \
        "── SEARCH ──────────────────────────────" \
        "* search-fzf        Live grep + open at line" \
        "* edit              Fuzzy-find + open a source file" \
        "  search-core       Search core framework files" \
        "  tree              Project tree (eza)" \
        "── GIT ─────────────────────────────────" \
        "  pull              Git pull" \
        "  log               Oneline commit graph" \
        "  diff              Show uncommitted changes" \
        "  branch            Switch branch (fzf)" \
        "  amend             Amend last commit" \
        "── HOUSEKEEPING ────────────────────────" \
        "  clean             Remove .elc + __pycache__" \
        "  clean-all         clean + node_modules" \
        "  node-install      pnpm install across all apps" \
        "  loc               Lines of code (tokei)" \
        "  deps              Show dependency tree" \
    )
    # Extract recipe name from selection.
    selection=$(echo "$menu" \
        | fzf --prompt="EAF> " --height=80% --reverse --ansi \
              --header="Pick a recipe  (* = recommended)" \
              --color="header:bold,pointer:bright-cyan" \
              --no-mouse \
        | sed 's/^[* ]*//' | awk '{print $1}')
    # Skip category headers and empty selections.
    if [[ -n "$selection" && "$selection" != "──" ]]; then
        just "$selection"
    fi

# [fzf] Pick any recipe to run (flat list, no categories).
pick:
    #!/usr/bin/env bash
    recipe=$(just --list --unsorted \
        | tail -n +2 \
        | sed 's/^[[:space:]]*//' \
        | fzf --prompt="just> " --height=40% --reverse \
        | awk '{print $1}')
    [[ -n "$recipe" ]] && just "$recipe"

# [fzf] Pick an available app to install.
apps-pick:
    #!/usr/bin/env bash
    app=$(python3 -c 'import json; d=json.load(open("applications.json")); [print(k) for k,v in d.items() if v["type"]=="app"]' \
        | fzf --prompt="install app> " --height=40% --reverse)
    [[ -n "$app" ]] && just install-app "$app"

# [fzf] Open a source file in $EDITOR.
edit:
    #!/usr/bin/env bash
    file=$(fd -e py -e el -e js --max-depth 3 -E node_modules -E __pycache__ \
        | fzf --prompt="edit> " --height=40% --reverse --preview 'head -80 {}')
    [[ -n "$file" ]] && {{editor}} "$file"

# [fzf] Live grep -- type a pattern, results update in real time, pick to open.
search-fzf:
    #!/usr/bin/env bash
    RG_CMD="rg --line-number --no-heading --color=always --type py --glob '*.el' --glob '*.js' -g '!node_modules'"
    match=$(
        fzf --prompt="grep> " --height=80% --reverse --ansi --disabled \
            --bind "change:reload:$RG_CMD {q} || true" \
            --bind "start:reload:echo 'Type to search...'" \
            --preview 'file=$(echo {} | cut -d: -f1); line=$(echo {} | cut -d: -f2); [[ -f "$file" ]] && head -n $((line + 30)) "$file" | tail -n 60 || echo ""' \
            --delimiter=: --nth=3.. \
            --header="Type a pattern to search Python/Elisp/JS files"
    )
    if [[ -n "$match" ]]; then
        file=$(echo "$match" | cut -d: -f1)
        line=$(echo "$match" | cut -d: -f2)
        {{editor}} "+$line" "$file"
    fi

# [fzf] Pick a git branch to checkout.
branch:
    #!/usr/bin/env bash
    b=$(git branch --all --format='%(refname:short)' \
        | fzf --prompt="branch> " --height=40% --reverse)
    [[ -n "$b" ]] && git checkout "$b"
