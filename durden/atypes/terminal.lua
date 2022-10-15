--
-- Terminal archetype, settings and menus specific for terminal-
-- frameserver session (e.g. keymapping, state control)
--
local action_menu = {
	{
		name = "hide_reveal",
		kind = "value",
		description = "Hide parent and swap in child on new connection",
		label = "Hide/Reveal",
		set = {LBL_YES, LBL_NO},
		initial = function()
		end,
		handler = function()
		end,
	},
	{
		name = "swap_active",
		kind = "action",
		description = "Toggle between parent and child",
		label = "Swap",
		handler = function()
		end,
	},
}

local res = {
	dispatch = {
		preroll = function(wnd, source, status)
			if gconfig_get("tui_colorscheme") then
				suppl_tgt_color(source, gconfig_get("tui_colorscheme"))
			end
		end,
		content_state = function(wnd, source, status)
			if status.max_w <= 0 or status.max_h <= 0 or
				not wnd.space or not wnd.space.in_float then
				return
			end

-- could have other strategies here for tiled at least where any children or
-- siblings get more space allocated to them, but would take some refactoring
-- of the layout code
			wnd:displayhint(status.max_w, status.max_h, wnd.dispmask)
		end,

-- message is used for notifications or prompt hints (still in flux, idea
-- was for readline widget to communicate the actual prompt part to integrate
-- with the HUD style prompt but it might just turn out to be a bad idea).
		message = function(wnd, source, tbl)
			if string.sub(tbl.message, 1, 1) == ">" then
				return;
			end
			notification_add(
				wnd:get_name(),
				nil,
				#tbl.message < 24 and tbl.message or "terminal notification",
				tbl.message, 1
			)
			return true;
		end
	},
-- actions are exposed as target- menu
	actions = {
		{
			name = "group_action",
			label = "Group Action",
			kind = "action",
			handler = action_menu,
			submenu = true,
			eval = function()
				return active_display().selected.terminal_group
			end,
		}
	},
-- labels is mapping between known symbol and string to forward
	labels = {},
	default_shader = {"simple", "crop"},
	atype = "terminal",
	props = {
-- keep as client for now, when the server-side rendering can do cropping
-- and clipping correctly for tui surfaces we can reconsider..
		scalemode = "client",
		autocrop = true,
		centered = false,
		font_block = true,
		filtermode = FILTER_NONE,
		allowed_segments = {"tui", "handover"}
	},
};

-- globally listen for changes to the default opacity and forward
gconfig_listen("term_opa", "aterm",
function(id, newv)
	for wnd in all_windows("terminal") do
		if (valid_vid(wnd.external, TYPE_FRAMESERVER)) then
			target_graphmode(wnd.external, 1, newv * 255.0);
		end
	end

	local col = gconfig_get("term_bgcol");
	shader_update_uniform("crop", "simple", "color",
		{col[1], col[2], col[3], newv}, nil, "term-alpha");
end);

-- globally apply changes to terminal font and terminal font sz,
-- share fallback- font system wide though.
gconfig_listen("term_font", "aterm",
function(id, newv)
	for wnd in all_windows("terminal") do
		wnd.font_block = false;
		local tbl = {newv};
		local fbf = gconfig_get("font_fb");
		if (fbf and resource(fbf, SYS_FONT_RESOURCE)) then
			tbl[2] = fbf;
		end
		wnd:update_font(-1, -1, tbl);
		wnd.font_block = true;
	end
end);

gconfig_listen("term_font_hint", "aterm",
function(id, newv)
	for wnd in all_windows("terminal") do
		wnd.font_block = false;
		wnd:update_font(-1, newv);
		wnd.font_block = true;
	end
end);

gconfig_listen("term_font_sz", "aterm",
function(id, newv)
	for wnd in all_windows("terminal") do
		wnd.font_block = false;
		wnd:update_font(tonumber(newv), -1);
		wnd.font_block = true;
	end
end);

res.init = function(res, wnd, source)
	wnd.font_block = false;
	local tbl = {gconfig_get("term_font")};
	local fbf = gconfig_get("font_fb");
	if (fbf and resource(fbf, SYS_FONT_RESOURCE)) then
		tbl[2] = fbf;
	end

	if (gconfig_get("term_bitmap")) then
		wnd.last_font = nil;
		wnd:update_font(gconfig_get("term_font_sz"),
			gconfig_get("term_font_hint"));
		wnd:update_font(gconfig_get("term_font_sz"),
			gconfig_get("term_font_hint"));
	else
		wnd:update_font(gconfig_get("term_font_sz"),
			gconfig_get("term_font_hint"), tbl);
	end

	wnd.receive_cursortag =
	function(wnd, probe, srcwnd)
		if probe then
			return wnd.stateinf ~= nil and srcwnd.stateinf ~= nil
			and wnd.stateinf.typeid == srcwnd.stateinf.typeid
		end

		bond_target(srcwnd.external, wnd.external);
	end

	wnd.font_block = true;
end

res.labels["LEFT"] = "LEFT";
res.labels["UP"] = "UP";
res.labels["DOWN"] = "DOWN";
res.labels["RIGHT"] = "RIGHT"
res.labels["lshift_UP"] = "PAGE_UP";
res.labels["lshift_DOWN"] = "PAGE_DOWN";

return res;
