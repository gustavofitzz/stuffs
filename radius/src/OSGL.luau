------------------------------------------------------------
-- OSGL v1.6b - Open-Source Graphical Library
-- Created/maintained by @saaawdust and contributors
--
-- Free to use, modify and distribute in your projects (including commercial games ;3)
-- Credit appreciated but not required
--
-- Do NOT:
-- - Repackage and sell OSGL directly
-- - Claim you created the core library
--
-- By using OSGL, you agree to these terms.
-- Full license available in the LICENSE file
------------------------------------------------------------

local things = game:GetObjects("rbxassetid://94615674281768")[1]

local DrawableObject = things.DrawableObject
local types = loadstring(game:HttpGet("https://raw.githubusercontent.com/gustavofitzz/stuffs/refs/heads/main/radius/src/types.luau"))()

export type Window = types.Window
export type Color = types.Color
export type Texture = types.Texture
export type Bitmap = types.Bitmap
export type Video = types.Video
export type Font = types.Font

return {
	Window = loadstring(DrawableObject.window.Source)(),
	Texture = loadstring(DrawableObject.texture.Source)(),
	Bitmap = loadstring(things.bitmap)(),
	Enum = loadstring(things.enums)(),
	Video = loadstring(things.video)(),
	Font = loadstring(things.font)(),

	color = loadstring(things.color)(),
}
