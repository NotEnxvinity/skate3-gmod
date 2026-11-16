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
	riding = {
		{ { 0.3969, -0.6803, 0.6162 }, { 0.7901, -0.2542, 0.5578 }, { 0.7587, 0.3984, 0.5154 } },
		{ { 0.953, -0.0019, 0.3028 }, { 0.8878, 0.0826, 0.4527 }, { 0.5671, 0.2557, 0.783 } },
		{ { 0.9462, 0.0184, 0.3231 }, { 0.7575, 0.087, 0.647 }, { 0.4335, 0.1356, 0.8909 } },
		{ { 0.9566, 0.0469, 0.2876 }, { 0.7442, -0.014, 0.6678 }, { 0.121, -0.0618, 0.9907 } },
		{ { 0.9695, 0.033, 0.2428 }, { 0.7419, -0.1216, 0.6594 }, { 0.3955, -0.2914, 0.871 } },
	},
	grab = {
		{ { 0.4002, -0.5591, 0.7262 }, { 0.681, -0.5981, 0.4225 }, { 0.5808, -0.6473, 0.4936 } },
		{ { 0.4121, 0.1173, 0.9035 }, { 0.1379, 0.167, 0.9763 }, { -0.0937, 0.2232, 0.9703 } },
		{ { 0.4037, 0.1038, 0.909 }, { 0.1036, 0.128, 0.9863 }, { -0.1125, 0.1262, 0.9856 } },
		{ { 0.4505, 0.0934, 0.8879 }, { 0.112, 0.1016, 0.9885 }, { -0.3156, 0.0438, 0.9479 } },
		{ { 0.532, 0.154, 0.8326 }, { 0.1911, 0.1098, 0.9754 }, { -0.0011, -0.0584, 0.9983 } },
	},
	carry = {
		{ { 0.4036, -0.5961, 0.6941 }, { 0.8434, -0.2655, 0.4671 }, { 0.9481, -0.1118, 0.2978 } },
		{ { 0.8474, 0.1385, 0.5126 }, { 0.7705, 0.1715, 0.6139 }, { 0.603, 0.2528, 0.7566 } },
		{ { 0.8493, 0.0915, 0.5199 }, { 0.7653, 0.1445, 0.6273 }, { 0.6124, 0.1653, 0.773 } },
		{ { 0.8789, 0.0681, 0.4722 }, { 0.807, 0.0668, 0.5867 }, { 0.4902, -0.0001, 0.8716 } },
		{ { 0.9774, 0.0234, 0.21 }, { 0.8327, 0.0014, 0.5538 }, { 0.6771, -0.0778, 0.7318 } },
	},
	-- How far Enx turned the wrist from where the game had it, holding the
	-- board: per side, an axis in the hand frame { to the knuckles, the
	-- second axis, knuckles x (index -> pinky) } and an angle in radians.
	wrist = {
		grab = { R = { 0.9528, -0.2981, -0.0567, 0.6119 }, L = { -0.9528, 0.2981, -0.0567, 0.6119 } }, -- 35.1 degrees
		carry = { R = { 0.9699, 0.2397, 0.0439, 0.6279 }, L = { -0.9699, -0.2397, 0.0439, 0.6279 } }, -- 36.0 degrees
	},
}
