S3GM v2.2.0: Skate 3 in Garry's Mod
===================================

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
  Keyboard and mouse also works now, but it's early: WASD, Space pushes,
  E gets on and off, flick the mouse for tricks, click to grab. Keys are in
  Utilities > Skate 3 > Settings.
- Nothing else: the setup brings its own Python the first time (it needs
  internet for that, a few hundred MB).


Install
-------
1. Subscribe to "S3GM: Skate 3 in Gmod" on the Steam Workshop. That's the
   addon itself.
2. Extract this zip anywhere, Downloads is fine. You get one folder,
   S3GM-setup. Don't put it in your Garry's Mod folder, it finds Gmod itself.
3. Run the setup once (and again after every S3GM update):
     Windows:  drag your Skate 3 .iso onto S3GM-setup-Windows.bat
               (or double-click it and pick the .iso)
     macOS:    double-click S3GM-setup-Mac.command. The first time, macOS
               says it "Not Opened": click Done, then System Settings >
               Privacy & Security, scroll down, click Open Anyway next to
               S3GM-setup-Mac.command. Or skip that and paste in Terminal:
               bash ~/Downloads/S3GM-setup/S3GM-setup-Mac.command
     Linux / SteamOS:  open S3GM-setup in a terminal and run ./skate3-setup.sh
   An .iso sitting next to the S3GM-setup folder (or inside it) is used
   without asking. Setup finds Garry's Mod, installs the skate engine
   module, and converts the skater, animations and sounds from your disc.
   The first run downloads a few helpers, so give it a few minutes.
   Without a window: add  --game "/path/to/Skate 3.iso"  (and
   --gmod "/path/to/garrysmod" if it can't find Garry's Mod).
4. Start Garry's Mod, load a map, and equip the Skateboard
   (spawn menu > Weapons > Skate 3).

Joining someone's server? You need this setup too: everyone's skating runs
from their own disc.


Controls
--------
Skate 3's own: A pushes, Y gets on and off the board, the right stick flicks
tricks, triggers grab. D-pad down drops a session marker, hold D-pad up to
go back to it. Switch weapons to leave skate mode.


Settings
--------
Spawn menu > Utilities > Skate 3: stance, camera, sounds (Skate 3's from
your disc, or Half-Life 2's), bail sounds, footsteps, volume, the trick
score's look, and a button to reset them all to the defaults.
Servers: skate3_bail_damage turns bail damage on or off, skate3_spawned_props 0
makes spawned props passable to the board again, skate3_enabled 0 turns the
mode off.


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
