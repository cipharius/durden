-- Copyright: 2015-2020, Björn Ståhl
-- License: 3-Clause BSD
-- Reference: http://durden.arcan-fe.com
-- Description: Basic clipboard handling, currently text only but there's
-- little stopping us from using more advanced input and output formats.
--

local log = warning
local fmt = string.format

if suppl_add_logfn then
	log, fmt = suppl_add_logfn("clipboard");
end

-- also used for wnd:paste overrides to still send notifications
function clipboard_paste_default(wnd, msg, nosend)
	local dst = wnd.clipboard_out;

	if nosend then
		for _,v in ipairs(CLIPBOARD.paste_monitors) do
			v(msg)
		end
		return
	end

	if not dst or not valid_vid(dst) then
		if not valid_vid(wnd.external) then
			for k,v in ipairs(CLIPBOARD.paste_monitors) do
				v("unsupported", true)
			end
			return;
		end

-- this approach triggers an interesting bug that may be worthwhile to explore
--		wnd.clipboard_out = define_recordtarget(alloc_surface(1, 1),
--			wnd.external, "", {null_surface(1,1)}, {},
--			RENDERTARGET_DETACH, RENDERTARGET_NOSCALE, 0, function()
--		end);
		wnd.clipboard_out = define_nulltarget(wnd.external, "clipboard",
		function(source, status)
			if (status.kind == "terminated") then
				delete_image(source);
				wnd.clipboard_out = nil;
			end
		end);

		link_image(wnd.clipboard_out, wnd.anchor);
		target_flags(wnd.clipboard_out, TARGET_BLOCKADOPT);
	end

	msg = wnd.pastefilter ~= nil and wnd.pastefilter(msg) or msg;

	if (msg and string.len(msg) > 0) then
		for k,v in ipairs(CLIPBOARD.paste_monitors) do
			v(msg)
		end

		target_input(wnd.clipboard_out, msg);
	end
end

local function clipboard_add(ctx, source, msg, multipart)
	log(fmt(
		"add:multipart=%d:message=%s", multipart and 1 or 0, msg));

	if (multipart) then
		if (ctx.mpt[source] == nil) then
			ctx.mpt[source] = {};
		end

-- simple cutoff to prevent nasty clients from sending multipart forever
		table.insert(ctx.mpt[source], msg);
		if (#ctx.mpt[source] < ctx.mpt_cutoff) then
			return;
		end
	end

-- if there's previous multipart tracking, combine them now
	if (ctx.mpt[source]) then
		msg = table.concat(ctx.mpt[source], "") .. msg;
		ctx.mpt[source] = nil;
	end

-- quick-check for uri. like strings (not that comprehensive), store
-- in a separate global history that we can grab from at will
	if (string.len(msg) < 1024) then
		for k in string.gmatch(msg, "%a+://[^%s]+") do
			table.insert_unique_i(ctx.urls, 1, k);
			if (#ctx.urls > 10) then
				table.remove(ctx.urls, #ctx.urls);
			end
		end
	end

	if (ctx.locals[source] == nil) then
		ctx.locals[source] = {};
	end

-- default is promote to global, but less trusted won't be allowed to
	if (not ctx.locals[source].blocked) then
		ctx:set_global(msg, source);
	end

-- skip duplicates
	for k,v in ipairs(ctx.locals[source]) do
		if (v == msg) then
			return;
		end
	end

	table.insert_unique_i(ctx.locals[source], 1, msg);
	if (#ctx.locals[source] > ctx.history_size) then
		table.remove(ctx.locals[source], #ctx.locals[source]);
	end
end

local function clipboard_setglobal(ctx, msg, src)
	local insert = true

-- if we are updating with a substring of the top entry, just swap it out
	if #ctx.globals >= 1 then
		local cap = #msg > #ctx.globals[1] and #msg or #ctx.globals[1]
		if (string.sub(msg, 1, cap) == string.sub(ctx.globals[1], 1, cap)) then
			insert = false;
		end
	end

	if insert then
		table.insert_unique_i(ctx.globals, 1, msg);
		log(fmt("global:message=%s", msg));
	end

	if (#ctx.globals > ctx.history_size) then
		table.remove(ctx.globals, #ctx.globals);
	end

-- notify in reverse order to handle _del calls as a reaction to the event
	for i=#ctx.monitors,1,-1 do
		ctx.monitors[i](msg, src);
	end
end

-- by default, we don't retain history that is connected to a dead window
local function clipboard_lost(ctx, source)
	log(fmt("lost:source=%d", source));
	ctx.mpt[source] = nil;
	ctx.locals[source] = nil;
end

local function clipboard_save(ctx, fn)
	zap_resource(fn);
	local wout = open_nonblock(fn, 1);
	if (not wout) then
		log(
			fmt("save:kind=error:destination=%s:message=couldn't open", fn));
		return false;
	end

	wout:write(fmt("local res = { globals = {}; urls = {}; };\n"));
	for k,v in ipairs(ctx.globals) do
		wout:write(fmt("table.insert(res.globals, %q);\n", v));
	end
	for k,v in ipairs(ctx.urls) do
		wout:write(fmt("table.insert(res.urls, %q);\n", v));
	end

	wout:write("return res;\n");
	wout:close();
	return true;
end

local function clipboard_del_monitor(ctx, fctx)
	table.remove_match(ctx.monitors, fctx);
	table.remove_match(ctx.paste_monitors, fctx);
end

local function clipboard_add_monitor(ctx, fctx, paste)
	if type(fctx) == "function" then
		table.remove_match(ctx.monitors, fctx);
		if (paste) then
			table.insert(ctx.paste_monitors, fctx);
		else
			table.insert(ctx.monitors, fctx);
		end
	else
		log(fmt("add:kind=error:source=add_monitor:message=bad argument"));
	end
end

local function clipboard_load(ctx, fn)
	if (not resource(fn)) then
		return;
	end

	local res = system_load(fn, 0);
	if (not res) then
		log(fmt("load:kind=error:source=%s:message=couldn't open", fn));
		return;
	end

	local okstate, map = pcall(res);
	if (not okstate) then
		log(fmt("load:kind=error:source=%s:message=couldn't parse", fn));
		return;
	end

	if (map and type(map) == "table" and
		map.globals and type(map.globals) == "table" and
		map.urls and type(map.urls) == "table") then
		ctx.globals = map.globals;
		ctx.urls = map.urls;
	end

	return true;
end

-- The client referenced by 'ref' can provide multiple paste types,
-- and this set can mutate whenever.
local function clipboard_provider(ctx, ref, types, trigger)
	if not types or #types == 0 or not trigger then
		ctx.providers[ref] = nil
		if ctx.focus_provider == ref then
			ctx.focus_provider = nil
		end
		return;
	end

	ctx.providers[ref] = {
		ts = CLOCK,
		ref = ref,
		types = types
	};
end

-- Used to indicate that provider 'ref' should be the first returned
-- result when enumerating possible providers
local function clipboard_focus_provider(ctx, ref)
	ctx.focus_provider = ref
end

-- Retrieve a list of possible providers and their types sorted
-- by when they were added
local function clipboard_providers(ctx)
	local res = {};

	for k,v in pairs(ctx.providers) do
		table.insert(res, v);
	end

	table.sort(res,
	function(a, b)
		return a.ts <= b.ts;
	end)

	if ctx.focus_provider then
		table.insert(res, 1, ctx.focus_provider);
	end

	return res, focus_provider;
end

local function clipboard_locals(ctx, source)
	return ctx.locals[source] and ctx.locals[source] or {};
end

local function clipboard_text(ctx)
	return ctx.global and ctx.global or "";
end

-- premade filters to help in cases where we get a lot of junk like
-- copy / paste from terminals.
local pastemodes = {
normal = {
	"Normal",
	function(instr)
		return instr;
	end
},
trim = {
	"Trim",
	function(instr)
		return (string.gsub(instr, "^%s*(.-)%s*$", "%1"));
	end
},
nocrlf = {
	"No CR/LF",
	function(instr)
		return (string.gsub(instr, "[\n\r]+", ""));
	end
},
nodspace = {
	"Single Spaces",
	function(instr)
		return (string.gsub(instr, "%s+", " "));
	end
}
};

local function clipboard_pastemodes(ctx, key)
	local res = {};

-- try match by index, else match by labelstr else default
	if (key) then
		local ent = pastemodes[key] and pastemodes[key] or pastemodes[1];
		for k,v in pairs(pastemodes) do
			if (v[1] == key) then
				ent = v;
				break;
			end
		end

		return ent[2], ent[1];
	end

	for k,v in pairs(pastemodes) do
		table.insert(res, v[1]);
	end
	table.sort(res);
	return res;
end

return {
	mpt = {}, -- mulitpart tracking
	locals = {}, -- local clipboard history (of history_size size)
	globals = {},
	urls = {},
	providers = {},
	monitors = {},
	paste_monitors = {},
	modes = pastemodes,
	history_size = 10,
	mpt_cutoff = 100,
	add = clipboard_add,
	text = clipboard_text,
	lost = clipboard_lost,
	save = clipboard_save,
	load = clipboard_load,
	add_monitor = clipboard_add_monitor,
	del_monitor = clipboard_del_monitor,
	pastemodes = clipboard_pastemodes,
	set_global = clipboard_setglobal,
	list_local = clipboard_locals,
	set_provider = clipboard_provider,
	focus_provider = clipboard_focus_provider,
	get_providers = clipboard_providers
};
