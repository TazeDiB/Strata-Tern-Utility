--!strict
-- Palette command, status segment, and a chrome poll of the last host snapshot.

local KIND = "strata-server.panel"

local function open_panel(cx: WindowCx)
	for _, pane in cx.session:panes() do
		if string.find(pane.title, "Flash Next", 1, true) or string.find(pane.title, "Strata", 1, true) then
			if string.find(pane.title, " · ", 1, true) then
				cx.layout:focus(pane.pane)
				return
			end
		end
	end
	if cx:new_block(KIND, nil, "beside") == nil then
		cx:toast("error", "Strata Server is not loaded on this host", "Check Preferences › Plugins.")
	end
end

tern.command({
	id = "open",
	title = "Open Strata server panel",
	icon = "cpu",
	run = open_panel,
})

tern.chrome.status(function(_pane: PaneInfo): { StatusSegment }?
	local st = tern.kv.get("status")
	if type(st) ~= "table" then
		return { { text = "Strata", tone = "muted", command = "plugin.strata-server.open" } }
	end
	local name = if type(st.name) == "string" then st.name else "Strata"
	local kind = if type(st.kind) == "string" then st.kind else "offline"
	local text = name
	local tone = "muted"
	if st.starting == true then
		text = name .. " starting"
		tone = "warn"
	elseif st.stopping == true then
		text = name .. " stopping"
		tone = "warn"
	elseif kind == "offline" then
		text = name .. " off"
		tone = "error"
	elseif st.busy == true then
		local rate = st.tok_s
		if type(rate) == "number" then
			text = name .. " " .. string.format("%.0f", rate) .. " tok/s"
		else
			text = name .. " busy"
		end
		tone = "accent"
	elseif st.loaded == false then
		text = name .. " unloaded"
		tone = "warn"
	else
		if type(st.model) == "string" and st.model ~= "" then
			text = st.model
		else
			text = name .. " ready"
		end
		tone = "ok"
	end
	return { { text = text, icon = "cpu", tone = tone, command = "plugin.strata-server.open" } }
end)

local function tick()
	tern.chrome.refresh()
	tern.timer(3000, tick)
end

tern.timer(1500, tick)
