-- Glass.lua: this addon's instance of the "liquid glass" material.
--
-- The material lives in the embedded library LibGlass-1.0
-- (Libs\LibGlass-1.0, from github.com/Spotnick2/LibGlass through .pkgmeta
-- externals; the TOC loads it first). Material changes are LibGlass PRs, not
-- edits here. An instance, not the library itself: STYLE, the live setters and
-- the font registry are GuildSpy's own. Glass.MEDIA is the library's folder,
-- never our own art. Used by the log window (phase 2).

local ADDON = ...
GuildSpy = GuildSpy or {}
GuildSpy.Glass = LibStub("LibGlass-1.0"):New()
