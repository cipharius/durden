local exit_query = {
{
	name = "no",
	label = "No",
	kind = "action",
	handler = function() end
},
{
	name = "yes",
	label = "Yes",
	description = "This will close external connections, any unsaved data will be lost",
	kind = "action",
	dangerous = true,
	handler = function() shutdown(); end
},
{
	name = "silent",
	label = "Silent",
	description = "Shutdown, but don't tell external connections to terminate",
	kind = "action",
	dangerous = true,
	handler = function() shutdown("", EXIT_SILENT); end
}
};

-- Lockscreen States:
-- [Idle-setup] -(idle_wakeup)-> [lock_query] -> (cancel: Idle-setup,
-- ok/verify: Idle-restore, ok/fail: Idle-setup)

local ef = function() end;
local idle_wakeup = ef;
local idle_setup = function(val, failed)
	if (failed > 0) then
		local fp = gconfig_get("lock_fail_" .. tostring(failed));
		if (fp) then
			dispatch_symbol(fp);
		end
	end

	active_display():set_input_lock(ef);
	timer_add_idle("idle_wakeup", 10, true, ef, function()
		idle_wakeup(val, failed);
	end);
end

local function idle_restore()
	durden_input = durden_normal_input;
	for d in all_tilers_iter() do
		show_image(d.anchor);
	end
	active_display():set_input_lock();
end

idle_wakeup = function(key, failed)
	local bar = active_display():lbar(
		function(ctx, msg, done, lastset)
			if (not done) then
				return true;
			end

-- accept, note that this comparison is early-out timing side channel
-- sensitive, but for the threat model here it does not really matter
			if (msg == key) then
				idle_restore();
				if (gconfig_get("lock_ok")) then
					dispatch_symbol(gconfig_get("lock_ok"));
				end
			else
				idle_setup(key, failed + 1);
			end
			iostatem_restore();
		end,
		{}, {label = string.format(
			failed > 0 and
				"Enter Unlock Key (%d Failed Attempts):" or
				"Enter Unlock Key:", failed),
			password_mask = gconfig_get("passmask")
		}
	);
	bar.on_cancel = function()
		idle_setup(key, failed);
	end
end

local function lock_value(ctx, val)
-- don't go through the normal input lock as events could then
-- still be forwarded to the selected window, input should trigger
-- lbar that, on escape, immediately jumps into idle state.
	if (durden_input == durden_locked_input) then
		warning("already in locked state, ignoring");
		return;
	end

	durden_input = durden_locked_input;
	iostatem_save();

-- this doesn't allow things like a background image / "screensaver"
	for d in all_tilers_iter() do
		hide_image(d.anchor);
	end

	local fn = gconfig_get("lock_on");
	if (fn) then
		dispatch_symbol(fn);
	end

	idle_setup(val, 0);
end

local function gen_appl_menu()
	local res = {};
	local tbl = glob_resource("*", SYS_APPL_RESOURCE);
	for i,v in ipairs(tbl) do
		table.insert(res, {
			name = "switch_" .. tostring(i);
			label = v,
			description = "Change the active set of scripts, data or external clients may be lost",
			dangerous = true,
			kind = "action",
			handler = function()
				durden_shutdown();
				system_collapse(v);
			end,
		});
	end
	return res;
end

local reset_query = {
	{
		name = "no",
		label = "No",
		kind = "action",
		handler = function() end
	},
	{
		name = "yes",
		label = "Yes",
		description = "Reset / Reload Durden? Unsaved data may be lost",
		kind = "action",
		dangerous = true,
		handler = function()
			durden_shutdown();
			system_collapse();
		end
	},
	{
		name = "switch",
		label = "Switch Appl",
		kind = "action",
		description = "Change the currently active window management scripts",
		submenu = true,
		eval = function() return #glob_resource("*", SYS_APPL_RESOURCE) > 0; end,
		handler = gen_appl_menu
	}
};

local function spawn_debug_wnd(vid, title)
	show_image(vid);
	local wnd = active_display():add_window(vid, {scalemode = "stretch"});
	wnd:set_title(title);
end

local function gen_displaywnd_menu()
	local res = {};
	for disp in all_displays_iter() do
		table.insert(res, {
			name = "disp_" .. tostring(disp.name),
			handler = function()
				local nsrf = null_surface(disp.tiler.width, disp.tiler.height);
				image_sharestorage(disp.rt, nsrf);
				if (valid_vid(nsrf)) then
					spawn_debug_wnd(nsrf, "display: " .. tostring(k));
				end
			end,
			label = disp.name,
			kind = "action"
		});
	end

	return res;
end

local counter = 0;

local function gettitle(wnd)
	return string.format("%s/%s:%s", wnd.name,
		wnd.title_prefix and wnd.title_prefix or "unk",
		wnd.title_text and wnd.title_text or "unk");
end

local debug_menu = {
	{
		name = "dump",
		label = "Dump",
		kind = "value",
		description = "create a debug snapshot",
		hint = "(debug/)",
		validator = strict_fname_valid,
		handler = function(ctx, val)
			zap_resource("debug/" .. val);
			system_snapshot("debug/" .. val);
		end
	},
	-- for testing fallback application handover
	{
		name = "broken",
		label = "Broken Call (Crash)",
		kind = "action",
		handler = function() does_not_exist(); end
	},
	{
		name = "testwnd",
		label = "Color window",
		kind = "action",
		handler = function()
			counter = counter + 1;
			spawn_debug_wnd(
				fill_surface(math.random(200, 600), math.random(200, 600),
					math.random(64, 255), math.random(64, 255), math.random(64, 255)),
				"color_window_" .. tostring(counter)
			);
		end
	},
	{
		name = "worldid_wnd",
		label = "WORLDID window",
		kind = "action",
		handler = function()
			local wm = active_display();
			local newid = null_surface(wm.width, wm.height);
			if (valid_vid(newid)) then
				image_sharestorage(WORLDID, newid);
				spawn_debug_wnd(newid, "worldid");
			end
		end
	},
	{
		name = "display_wnd",
		label = "display_window",
		kind = "action",
		submenu = true,
		eval = function()
			return not gconfig_get("display_simple");
		end,
		handler = gen_displaywnd_menu
	},
	{
		name = "animation_cycle",
		label = "Animation Cycle",
		kind = "action",
		description = "Add an animated square that moves up and down the display",
		handler = function()
			if not DEBUG_ANIMATION then
				DEBUG_ANIMATION = {};
			end
			local vid = color_surface(64, 64, 0, 255, 0);
			if (not valid_vid(vid)) then
				return;
			end
			show_image(vid);
			order_image(vid, 65530);
			move_image(vid, 0, active_display().height - 64, 200);
			move_image(vid, 0, 0, 200);
			image_transform_cycle(vid, true);
			table.insert(DEBUG_ANIMATION, vid);
		end
	},
	{
		name = "stop_animation",
		label = "Stop Animation",
		eval = function() return DEBUG_ANIMATION and #DEBUG_ANIMATION > 0 or false; end,
		handler = function()
			for _,v in ipairs(DEBUG_ANIMATION) do
				if (valid_vid(v)) then
					delete_image(v);
				end
			end
			DEBUG_ANIMATION = nil;
		end
	},
	{
		name = "alert",
		label = "Random Alert",
		kind = "action",
		handler = function()
			timer_add_idle("random_alert" .. tostring(math.random(1000)),
				math.random(1000), false, function()
				local tiler = active_display();
				tiler.windows[math.random(#tiler.windows)]:alert();
			end);
		end
	},
	{
		name = "stall",
		label = "Frameserver Debugstall",
		kind = "value",
		eval = function() return frameserver_debugstall ~= nil; end,
		validator = gen_valid_num(0, 100),
		handler = function(ctx,val) frameserver_debugstall(tonumber(val)*10); end
	},
	{
		name = "dump_tree",
		label = "Dump Space-Tree",
		kind = "action",
		eval = function() return active_display().spaces[
			active_display().space_ind] ~= nil; end,
		handler = function(ctx)
			local space = active_display().spaces[active_display().space_ind];
			local fun;
			print("<space>");
			fun = function(node, level)
				print(string.format("%s<node id='%s' horiz=%f vert=%f>",
					string.rep("\t", level), gettitle(node),
					node.weight, node.vweight));
				for k,v in ipairs(node.children) do
					fun(v, level+1);
				end
				print(string.rep("\t", level) .. "</node>");
			end
			fun(space, 0);
			print("</space>");
		end
	}
};

local system_menu = {
	{
		name = "shutdown",
		label = "Shutdown",
		kind = "action",
		submenu = true,
		description = "Perform a clean shutdown",
		handler = exit_query
	},
	{
		name = "reset",
		label = "Reset",
		kind = "action",
		submenu = true,
		description = "Rebuild the WM state machine",
		handler = reset_query
	},
	{
		name = "status_msg",
		label = "Status-Message",
		kind = "value",
		invisible = true,
		description = "Add a custom string to the statusbar message area",
		validator = function(val) return true; end,
		handler = function(ctx, val)
			active_display():message(val and val or "");
		end
	},
	{
		name = "output_msg",
		label = "IPC-Output",
		kind = "value",
		description = "Write a custom string to the output IPC fifo",
		invisible = true,
		validator = function(val) return string.len(val) > 0; end,
		handler = function(ctx, val)
			if (OUTPUT_CHANNEL) then
				OUTPUT_CHANNEL:write(val .. "\n");
			end
		end
	},
	{
		name = "debug",
		label = "Debug",
		kind = "action",
		eval = function() return DEBUGLEVEL > 0; end,
		submenu = true,
		handler = debug_menu,
	},
	{
		name = "lock",
		label = "Lock",
		kind = "value",
		description = "Query for a temporary unlock key and then lock the display",
		dangerous = true,
		password_mask = gconfig_get("passmask"),
		hint = "(unlock key)",
		validator = function(val) return string.len(val) > 0; end,
		handler = lock_value
	}
};

return system_menu;
