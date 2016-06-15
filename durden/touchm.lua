-- Copyright: 2016, Björn Ståhl
-- touch, tablet, multitouch support and routing.
-- each device is assigned a classifier that covers how multitouch
-- events should be mapped to other device behaviors or explicit
-- gestures.

--
-- On an unknown touch event entering, we should run a calibration
-- tool automatically, with the option to ignore/disable the device
-- or automatic activation.
--
-- The tool should query for:
--  [number of fingers]
--  actual range
--  pressure- sensitivity
--  preferred classifier (relmouse, absmouse, gesture, more advanced..)
--  if it also maps to any mouse event
--  and possibly disabilities in the user (e.g. parkinson)
--
-- good cases to try it out with is DS "second screen" touch input
-- and some vectorizer -> chinese OCR style input
--

local devices = {};

-- aggregate samples with a variable number of ticks as sample period
-- and then feed- back into _input as a relative mouse input event
local function relative_sample(devtbl, iotbl)
	local ind = iotbl.subid - 128;
	if (iotbl.digital) then
		return;
	end

-- only map to normal motion if a single source is marked as active

-- should also register a tick handler to periodically reset sample-base
-- to deal with jittery or broken devices that do not expose a release
-- event.

	if (not iotbl.active) then
		devtbl.last_x = nil;
		devtbl.last_y = nil;
		return;
	elseif (not devtbl.last_x) then
		devtbl.last_x = iotbl.x;
		devtbl.last_y = iotbl.y;
		return;
	end

	local dx = iotbl.x - devtbl.last_x;
	local dy = iotbl.y - devtbl.last_y;
	devtbl.last_x = iotbl.x;
	devtbl.last_y = iotbl.y;

	mouse_input(dx, dy);
	return nil;
end

local function relative_init(devtbl)
	devtbl.last_x = VRESW * 0.5;
	devtbl.last_y = VRESH * 0.5;
	devtbl.scale_x = 1.0;
	devtbl.scale_y = 1.0;
end

local classifiers = {
	relmouse = {relative_init, relative_sample}
};

function touch_consume_sample(iotbl)
	if (not devices[iotbl.devid]) then
		local st = {};
		devices[iotbl.devid] = st;
		local cf = classifiers[gconfig_get("mt_classifier")];
		cf[1](st);
		durden_register_devhandler(iotbl.devid, cf[2], st);
		durden_input(iotbl);
	end
end