--
-- Keyboard dispatch
--
local tbl = system_load("keybindings.lua")();

-- state tracking table for locking/unlocking, double-tap tracking, and sticky
local mtrack = {
	m1 = nil,
	m2 = nil,
	last_m1 = 0,
	last_m2 = 0,
	unstick_ctr = 0,
	dblrate = 10,
	mstick = 0,
	mlock = "none"
};

-- the following line can be removed if meta state protection is not needed
system_load("meta_guard.lua")();

function dispatch_system(key, val)
	if (SYSTEM_KEYS[key] ~= nil) then
		SYSTEM_KEYS[key] = val;
		store_key("sysk_" .. key, val);
	else
		warning("tried to assign " .. key .. " / " .. val .. " as system key");
	end
end

function dispatch_tick()
	if (mtrack.unstick_ctr > 0) then
		mtrack.unstick_ctr = mtrack.unstick_ctr - 1;
		if (mtrack.unstick_ctr == 0) then
			mtrack.m1 = nil;
			mtrack.m2 = nil;
		end
	end
end

function dispatch_load(locktog)
	gconfig_listen("meta_stick_time", "dispatch.lua",
	function(key, val)
		mtrack.mstick = val;
	end);
	gconfig_listen("meta_dbltime", "dispatch.lua",
	function(key, val)
		mtrack.dblrate = val;
	end
	);
	gconfig_listen("meta_lock", "dispatch.lua",
	function(key, val)
		mtrack.mlock = val;
	end
	);

	mtrack.dblrate = gconfig_get("meta_dbltime");
	mtrack.mstick = gconfig_get("meta_stick_time");
	mtrack.mlock = gconfig_get("meta_lock");
	mtrack.locktog = locktog;

	for k,v in pairs(SYSTEM_KEYS) do
		local km = get_key("sysk_" .. k);
		if (km ~= nil) then
			SYSTEM_KEYS[k] = tostring(km);
		end
	end

	local get_kv = function(str)
		local pos, stop = string.find(str, "=", 1);
		local key = string.sub(str, 7, pos - 1);
		local val = string.sub(str, stop + 1);
		return key, val;
	end

-- custom bindings, global shared
	for i,v in ipairs(match_keys("custg_%")) do
		local key, val = get_kv(v);
		if (val and string.len(val) > 0) then
			tbl[key] = "!" .. val;
		end
	end

-- custom bindings, window shared
	for i,v in ipairs(match_keys("custs_%")) do
		local key, val = get_kv(v);
		if (val and string.len(val) > 0) then
			tbl[key] = "#" .. val;
		end
	end
end

function dispatch_list()
	local res = {};
	for k,v in pairs(tbl) do
		table.insert(res, k .. "=" .. v);
	end
	table.sort(res);
	return res;
end

function dispatch_custom(key, val, nomb, wnd, global, falling, append)
	if (falling) then
		if (nomb) then
			dispatch_custom(key, val, true, wnd, global, false);
		end
		key = "f_" .. key;
	end

	local old = tbl[key];
	local pref = wnd and "custs_" or "custg_";
-- go through these hoops to support unbind (nomb),
-- global/target prefix (which uses symbols not allowed as dbkey)
	if (nomb) then
		tbl[key] = val;
	else
		tbl[key] = val and ((wnd and "#" or "!") .. val) or nil;
	end

	store_key(pref .. key, val and val or "");
	return old;
end

function dispatch_meta()
	return mtrack.m1 ~= nil, mtrack.m2 ~= nil;
end

function dispatch_meta_reset(m1, m2)
	mtrack.m1 = m1 and CLOCK or nil;
	mtrack.m2 = m2 and CLOCK or nil;
end

function dispatch_toggle(forcev, state)
	local oldign = mtrack.ignore;

	if (mtrack.mlock == "none") then
		mtrack.ignore = false;
		return;
	end

	if (forcev ~= nil) then
		mtrack.ignore = forcev;
	else
		mtrack.ignore = not mtrack.ignore;
	end

-- run cleanup hook
	if (type(oldign) == "function" and mtrack.ignore ~= oldign) then
		oldign();
	end

	if (mtrack.locktog) then
		mtrack.locktog(mtrack.ignore, state);
	end
end

local function track_label(iotbl, keysym, hook_handler)
	local metadrop = false;
	local metam = false;

-- notable state considerations here, we need to construct
-- a string label prefix that correspond to the active meta keys
-- but also take 'sticky' (release- take artificially longer) and
-- figure out 'gesture' (double-press)
	local function metatrack(s1)
		local rv1, rv2;
		if (iotbl.active) then
			if (mtrack.mstick > 0) then
				mtrack.unstick_ctr = mtrack.mstick;
			end
			rv1 = CLOCK;
		else
			if (mtrack.mstick > 0) then
				rv1 = s1;
			else
-- rv already nil
			end
			rv2 = CLOCK;
		end
		metam = true;
		return rv1, rv2;
	end

	if (keysym == SYSTEM_KEYS["meta_1"]) then
		local m1, m1d = metatrack(mtrack.m1, mtrack.last_m1);
		mtrack.m1 = m1;
		if (m1d and mtrack.mlock == "m1") then
			if (m1d - mtrack.last_m1 <= mtrack.dblrate) then
				dispatch_toggle();
			end
			mtrack.last_m1 = m1d;
		end
	elseif (keysym == SYSTEM_KEYS["meta_2"]) then
		local m2, m2d = metatrack(mtrack.m2, mtrack.last_m2);
		mtrack.m2 = m2;
		if (m2d and mtrack.mlock == "m2") then
			if (m2d - mtrack.last_m2 <= mtrack.dblrate) then
				dispatch_toggle();
			end
			mtrack.last_m2 = m2d;
		end
	end

	local lutsym = "" ..
		(mtrack.m1 and "m1_" or "") ..
		(mtrack.m2 and "m2_" or "") .. keysym;

	if (hook_handler) then
		hook_handler(active_display(), keysym, iotbl, lutsym, metam, tbl[lutsym]);
		return true, lutsym;
	end

	if (metam or not meta_guard(mtrack.m1 ~= nil, mtrack.m2 ~= nil)) then
		return true, lutsym;
	end

	return false, lutsym;
end

--
-- Central input management / routing / translation outside of
-- mouse handlers and iostatem_ specific translation and patching.
--
-- definitions:
-- SYM = internal SYMTABLE level symble
-- LUTSYM = prefix with META1 or META2 (m1, m2) state (or device data)
-- OUTSYM = prefix with normal modifiers (ALT+x, etc.)
-- LABEL = more abstract and target specific identifier
--
local last_deferred = nil;
local deferred_id = 0;

function dispatch_translate(iotbl, nodispatch)
	local ok, sym, outsym, lutsym;
	local sel = active_display().selected;

-- apply keymap (or possibly local keymap), note that at this stage,
-- iostatem_ has converted any digital inputs that are active to act
-- like translated
	if (iotbl.translated or iotbl.dsym) then
		if (iotbl.dsym) then
			sym = iotbl.dsym;
			outsym = sym;
		elseif (sel and sel.symtable) then
			sym, outsym = sel.symtable:patch(iotbl);
		else
			sym, outsym = SYMTABLE:patch(iotbl);
		end
-- generate durden specific meta- tracking or apply binding hooks
		ok, lutsym = track_label(iotbl, sym, active_display().input_lock);
	end

	if (not lutsym or mtrack.ignore) then
		if (type(mtrack.ignore) == "function") then
			return mtrack.ignore(lutsym, iotbl, tbl[lutsym]);
		end

		return false, nil, iotbl;
	end

	if (ok or nodispatch) then
		return true, lutsym, iotbl, tbl[lutsym];
	end

	local rlut = "f_" ..lutsym;
	if (tbl[lutsym] or (not iotbl.active and tbl[rlut])) then
		if (iotbl.active and tbl[lutsym]) then
			dispatch_symbol(tbl[lutsym]);
			if (tbl[rlut]) then
				last_deferred = tbl[rlut];
				deferred_id = iotbl.devid;
			end

		elseif (tbl[rlut]) then
			dispatch_symbol(tbl[rlut]);
			last_deferred = nil;
		end

-- don't want to run repeat for valid bindings
		iostatem_reset_repeat();
		return true, lutsym, iotbl;
	elseif (last_deferred and iotbl.devid == deferred_id) then
		dispatch_symbol(last_deferred);
		last_deferred = nil;
		return true, lutsym, iotbl;
	elseif (not sel) then
		return false, lutsym, iotbl;
	end

-- we can have special bindings on a per window basis
	if (sel.bindings and sel.bindings[lutsym]) then
		if (iotbl.active) then
			sel.bindings[lutsym](sel);
		end
		ok = true;
-- or an input handler unique for the window
	elseif (not iotbl.analog and sel.key_input) then
		sel:key_input(outsym, iotbl);
		ok = true;
	else
-- for label bindings, we go with the non-internal view of modifiers
		if (sel.labels) then
			iotbl.label = sel.labels[outsym] and sel.labels[outsym] or iotbl.label;
		end
	end

	return ok, outsym, iotbl;
end
