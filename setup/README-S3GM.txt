S3GM v2.2.2 (UI test): Skate 3 in Garry's Mod
=============================================

Skate 3's real skating in Garry's Mod: its own physics, flick-it tricks,
grinds, manuals and bails, on any map, with any playermodel.

Free forever. Unofficial fan project, not affiliated with EA or Facepunch.
Nothing from Skate 3 is in this download: the setup reads what the mod needs
from YOUR OWN Skate 3 (Xbox 360) disc image, on your own computer.


What you need
-------------
- Your own Skate 3 for Xbox 360, as a disc image (.iso) or an extracted
  folder with default.xex in it.
- 64-bit Garry's Mod: Steam > Garry's Mod > Properties > Betas > x86-64.
- A controller (recommended). On Steam Deck / SteamOS, Garry's Mod's
  controller layout must be a "Gamepad" template, not keyboard and mouse.
  Keyboard and mouse also works, but it's early: WASD, Space pushes,
  E gets on and off, flick the mouse for tricks, click to grab. Keys are in
  Utilities > Skate 3 > Settings.
- Internet the first time (setup fetches its own helpers).


Install
-------
Video walkthrough of this whole install: https://youtu.be/oGdIwMNwp14

1. Extract this zip anywhere. You get one folder, S3GM-setup.
2. Open S3GM-setup and double-click the setup for your computer:
     Windows:          S3GM-setup-Windows.bat
     Linux / SteamOS:  S3GM-setup-Linux.sh (Desktop Mode; pick Execute/Run
                       if it asks)
     Mac:              S3GM-setup-Mac.command (no Mac version of this
                       release yet; it will tell you)
3. A window shows your garrysmod folder and your Skate 3 disc. Fix either
   with Browse, press Install, and wait for "All set". It shows the S3GM
   version it installed. The first run takes a few minutes.
   The Gmod folder is the lowercase "garrysmod" folder INSIDE "GarrysMod":
     ...\steamapps\common\GarrysMod\garrysmod
   (picking GarrysMod itself works too, setup uses the garrysmod inside it).
4. Start Garry's Mod, load a map, and equip the Skateboard
   (spawn menu > Weapons > Skate 3).

Setup installs everything: the addon (replacing any older copy), the skate
engine, and what it converts from your disc. Updating = do the same with the
new zip. Subscribed to S3GM on the Steam Workshop? Keep it, as long as the
Workshop copy is the same version; if the game ever seems older than what
setup said it installed, unsubscribe from the Workshop one.

Joining someone's server? You need this setup too: everyone's skating runs
from their own disc.


Controls
--------
Skate 3's own: A pushes, Y gets on and off the board, the right stick flicks
tricks, triggers grab. Hold L1 (Shift on keyboard) for the quick menu: D-pad
down drops a session marker, hold D-pad up to go back to it, left interacts
with what you're next to, right opens the games list. Switch weapons to
leave skate mode.


Settings
--------
Spawn menu > Utilities > Skate 3: stance, camera, sounds (Skate 3's from
your disc, or Half-Life 2's), bail sounds, footsteps, volume, the trick
score's look (Skate 3's own, minimal, or Half-Life 2's; on screen or in the
world), the button pictures (Xbox or PlayStation; Automatic goes by your
controller's name, and Steam Input can hide a PlayStation pad behind an Xbox
name, so pick PlayStation yourself then), and a button to reset them all to the
defaults.
PlayStation buttons: drawn by the mod. If setup finds a decrypted PS3 copy of Skate 3
(the folder with PS3_GAME in it, next to the setup or in Downloads or Desktop)
it makes the game's own PlayStation button pictures from it instead.
Hall of Meat (Utilities > Skate 3, or skate3_hall_of_meat_toggle): bails
score, in red, with a skeleton showing fractured bones yellow and broken ones
red. Bail on purpose: hold both triggers and click both sticks.
Servers: skate3_bail_damage turns bail damage on or off (fractures and breaks
cost extra: skate3_bail_damage_fracture, skate3_bail_damage_break),
skate3_blood 0 turns off blood splats, skate3_spawned_props 0 makes spawned
props passable to the board again, skate3_enabled 0 turns the mode off.


Credits
-------
- Skate 3 engine and converters: SK8-ENGINE/skate-3-rust-engine (dumbad,
  Chasm and contributors), used with their permission on the condition
  that this mod stays free. It always will be.
- Headless host, collision handoff and grind-rail finder:
  chasmlol/2010-rust-rewrite-mashup (Apache-2.0, see LICENSES/ and NOTICE).
- Module architecture inspired by ckosmic/g64. No code taken.
- Sound bank research: doriangironde/skate-3-rust-macos and Hailey-Ross's
  audio work on SK8-ENGINE. Sounds are decoded on your machine by vgmstream.


License
-------
GPL-3.0 (LICENSE). Code ported from chasmlol's project stays under
Apache-2.0 as NOTICE describes. The source code is in the S3GM release post
next to this download. Skate 3 and its assets belong to Electronic Arts.
