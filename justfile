plenary_ref := "74b06c6c75e4eeb3108ec01852001636d85a932b"
plenary_url := "https://github.com/nvim-lua/plenary.nvim"

_default:
	just -l

# Run every test with plenary.
test:
	#!/usr/bin/env bash
	set -euo pipefail
	plenary_path="{{ justfile_directory() }}/plenary.nvim"

	if ! test -d "${plenary_path}"; then
		git clone {{ plenary_url }} "${plenary_path}"
	fi

	git -C "${plenary_path}" checkout "{{ plenary_ref }}"

	minimal_init="{{ justfile_directory() }}/tests/minimal_init.lua"
	nvim --headless --noplugin \
		-u "${minimal_init}" \
		-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = '${minimal_init}' })"

# Run Neovim with the plugin from this checkout. Extra arguments go to nvim.
[positional-arguments]
dev *args:
	nvim -u dev/init.lua "$@"

# Check formatting and types. Needs `stylua`, `nvim` and `lua-language-server`.
check:
	#!/usr/bin/env bash
	set -euo pipefail

	stylua --check .

	# LuaLS reads `vim.*` from the runtime of an installed Neovim. Asking that
	# Neovim for it keeps the path out of `.luarc.json` and out of this recipe.
	runtime="$(nvim --headless --noplugin -u NONE \
		-c 'lua io.stdout:write(vim.env.VIMRUNTIME)' -c 'qa!' 2>/dev/null)"
	if test -z "${runtime}"; then
		echo 'check: nvim reported no VIMRUNTIME' >&2
		exit 1
	fi

	scratch="$(mktemp -d)"
	trap 'rm -rf "${scratch}"' EXIT

	VIMRUNTIME="${runtime}" lua-language-server \
		--check=. \
		--checklevel=Warning \
		--check_format=pretty \
		--logpath="${scratch}/log" \
		--metapath="${scratch}/meta"

# Format every Lua file.
format:
	stylua .

# Record an anonymized fixture from the live Rex.
fixture:
	nvim --headless --noplugin -l tools/fixture.lua

# Check the plugin against the live Rex. Run it by hand; CI has no Rex.
smoke:
	nvim --headless --noplugin -l tools/smoke.lua
