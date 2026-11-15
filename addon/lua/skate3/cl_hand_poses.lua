-- Enx's hands for riding, grabbing, carrying and bailing. Skate 3's riding
-- and grab animations carry no fingers (its gameplay skeleton has none), so
-- Enx posed these by eye on a playermodel in Blender to match the game, and
-- tools turned them into the same measure the gestures use: per finger
-- (thumb, index, middle, ring, pinky) and joint (base to tip), where the
-- bone points in the hand's frame { to the knuckles, across them from index
-- to pinky, out of the palm }. cl_skater_anim points every playermodel's
-- fingers that way in its own hand, so one pose fits every model, either
-- hand. Posed on: maxinev2pm_ARM.

return {
	carry = {
		{ { 0.4036, -0.5961, 0.6941 }, { 0.8434, -0.2655, 0.4671 }, { 0.9481, -0.1118, 0.2978 } },
		{ { 0.8474, 0.1385, 0.5126 }, { 0.7705, 0.1715, 0.6139 }, { 0.603, 0.2528, 0.7566 } },
		{ { 0.8493, 0.0915, 0.5199 }, { 0.7653, 0.1445, 0.6273 }, { 0.6124, 0.1653, 0.773 } },
		{ { 0.8789, 0.0681, 0.4722 }, { 0.807, 0.0668, 0.5867 }, { 0.4902, -0.0001, 0.8716 } },
		{ { 0.9774, 0.0234, 0.21 }, { 0.8327, 0.0014, 0.5538 }, { 0.6771, -0.0778, 0.7318 } },
	},
	-- How far Enx turned the wrist from where the game had it, holding the
	-- board: per side, an axis in the hand frame { to the knuckles, the
	-- second axis, knuckles x (index -> pinky) } and an angle in radians,
	-- then how far the hand moved in that frame, in hand lengths.
	wrist = {
		carry = { R = { 0.9699, 0.2397, 0.0439, 0.6279, 0, 0, -0 }, L = { -0.9699, -0.2397, 0.0439, 0.6279, 0, 0, 0 } }, -- 36.0 degrees
	},
}
