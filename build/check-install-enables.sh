#!/usr/bin/env bash
# check-install-enables.sh — guard the rule that AN INSTALL ALWAYS ENABLES THE
# PLUG-IN.
#
# Lightroom Classic remembers a disabled plug-in in its preferences — by plugin
# id (AgSdkPluginLoader_disabledPluginIDs) AND by absolute path
# (AgSdkPluginLoader_disabledPluginPaths). Before this guard, installing over a
# previously-disabled copy left the fresh install disabled: the plug-in
# vanished from Plug-in Extras until the user found Plug-in Manager ▸ Enable
# (the wiki even documented it as a known gotcha instead of fixing it).
#
# Harness: a byte-accurate fake prefs file in the "Lightroom Classic CC 7
# Preferences.agprefs" container format (what Windows uses; macOS reaches the
# same pickled tables through `defaults`, sharing the same table surgery) + the
# REAL native lens-helper + the REAL `build.lua --install`.
#
# Checks (any failure exits 1):
#   1. after `build.lua --install`, the installed path is gone from
#      disabledPluginPaths and the plugin id is gone from disabledPluginIDs
#   2. everything else in the prefs survives byte-for-byte: other disabled
#      plug-ins, OTHER SpeciesTagger copies (deliberately disabled dev copies
#      must NOT be re-enabled — that would duplicate the menu), other keys
#   3. the rewritten file is still a valid Lua container Lightroom can load
#   4. a second install is a byte-identical no-op (idempotent)
set -euo pipefail
cd "$(dirname "$0")/.."
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mcheck-install-enables:\033[0m %s\n' "$*" >&2; exit 1; }

DIST=output/dist
[ -d "$DIST/SpeciesTagger.lrplugin" ] || fail "no composed bundle at $DIST — run 'lua build/build.lua' first"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "building the native helper for this host"
( cd src/helper && go build -trimpath -o "$tmp/lens-helper" . )

dest="$tmp/plugins/SpeciesTagger.lrplugin"
prefs="$tmp/Lightroom Classic CC 7 Preferences.agprefs"

# The fixture mirrors a real CC 7 prefs container byte-for-byte: tab-indented
# keys, pickled multi-line string values with backslash+newline escapes and
# backslash-escaped inner quotes. @DEST@ is substituted below (a quoted heredoc
# keeps every backslash literal; an unquoted one would eat the line
# continuations).
cat > "$prefs" <<'EOF'
prefs = {
	Adobe_successfulUpgrades1500000 = "pickle = {\
	[\"/Users/x/cat.lrcat\"] = {\
		catalogType = \"lr\",\
	},\
}\
",
	AgSdkPluginLoader_disabledPluginIDs = "t = {\
	[\"com.adobe.lightroom.sdk.aperture_importer\"] = true,\
	[\"org.yoren.lightroom.speciestagger\"] = true,\
}\
",
	AgSdkPluginLoader_disabledPluginPaths = "t = {\
	[\"@DEST@\"] = true,\
	[\"/Users/x/other-checkout/SpeciesTagger.lrplugin\"] = true,\
	[\"/Users/x/Modules/Topaz Photo.lrplugin\"] = true,\
}\
",
	libraryToLoad20 = "/Users/x/cat.lrcat",
}
EOF
sed -i.bak "s|@DEST@|$dest|" "$prefs" && rm -f "$prefs.bak"

say "installing with a prefs file that has this very install disabled"
ST_LR_HELPER="$tmp/lens-helper" ST_LR_AGPREFS="$prefs" LR_PLUGIN_DIR="$tmp/plugins" \
	lua build/build.lua --install >/dev/null 2>&1 \
	|| fail "install run failed (LR_PLUGIN_DIR=$tmp/plugins)"
[ -d "$dest" ] || fail "install produced no $dest"

say "prefs: the installed copy is enabled, nothing else changed"
grep -qF "$dest" "$prefs" \
	&& fail "installed path is STILL in disabledPluginPaths — the install left the plug-in disabled"
grep -qF 'org.yoren.lightroom.speciestagger' "$prefs" \
	&& fail "plugin id is STILL in disabledPluginIDs — the install left the plug-in disabled"
grep -qF 'other-checkout/SpeciesTagger.lrplugin' "$prefs" \
	|| fail "a deliberately-disabled OTHER SpeciesTagger copy was re-enabled (menu would duplicate)"
grep -qF 'Topaz Photo.lrplugin' "$prefs" \
	|| fail "an unrelated disabled plug-in was re-enabled"
grep -qF 'aperture_importer' "$prefs" \
	|| fail "an unrelated disabled plugin id was re-enabled"
grep -qF 'libraryToLoad20 = "/Users/x/cat.lrcat",' "$prefs" \
	|| fail "an unrelated prefs key was damaged"

say "prefs: rewritten file is still a valid Lua container"
lua - "$prefs" <<'LUA' || fail "rewritten prefs no longer parse as Lua — Lightroom would reset them"
local chunk = assert(loadfile(arg[1]))
local env = {}
setfenv(chunk, env)
chunk()
assert(type(env.prefs) == 'table', 'no prefs table')
assert(env.prefs.AgSdkPluginLoader_disabledPluginPaths, 'paths key vanished')
assert(env.prefs.AgSdkPluginLoader_disabledPluginIDs, 'ids key vanished')
LUA

say "prefs: a second install is a byte-identical no-op"
cp "$prefs" "$prefs.before"
ST_LR_HELPER="$tmp/lens-helper" ST_LR_AGPREFS="$prefs" LR_PLUGIN_DIR="$tmp/plugins" \
	lua build/build.lua --install >/dev/null 2>&1 \
	|| fail "second install run failed"
cmp -s "$prefs" "$prefs.before" || fail "re-install modified the prefs again (not idempotent)"

say "OK: an install always enables the plug-in (and touches nothing else)"
