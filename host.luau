--!strict
-- Strata Server panel: start/stop/status for any configured local server.

local ui = tern.ui

local LOG_MAX = 40
local FETCH_MS = 4000
local RATE_N = 32
local KIND_OFFLINE = "offline"
local KIND_UP = "up"
local KIND_STRATA = "strata"

type Server = {
	id: string,
	name: string,
	base_url: string,
	api_key: string,
	cwd: string?,
	start: { string },
	stop: { string },
	kill: { string },
	kill_port: number?,
}

type Config = {
	poll_ms: number,
	selected: string,
	servers: { Server },
}

type Snap = {
	kind: string,
	error: string?,
	http: number?,
	model: string?,
	loaded: boolean?,
	images: boolean?,
	context: number?,
	engine: string?,
	uptime_s: number?,
	requests: number?,
	busy: boolean?,
	phase: string?,
	generated: number?,
	tok_s: number?,
	queued: number?,
	elapsed_s: number?,
	gpu_used: number?,
	gpu_total: number?,
	ram_used: number?,
	ram_total: number?,
	prompt_n: number?,
	prompt_s: number?,
	pred_n: number?,
	pred_s: number?,
	models: { string },
	at: number,
}

type State = {
	cx: BlockCx,
	cfg: Config,
	selected: string,
	snap: Snap?,
	log: { string },
	rates: { number },
	busy: string?,
	starting: boolean,
	stopping: boolean,
	timer: TimerHandle?,
}

local running: { [number]: State } = {}

local function join(a: string, b: string): string
	local last = string.sub(a, -1)
	if last == "/" or last == "\\" then
		return a .. b
	end
	local sep = if tern.runtime.os == "windows" then "\\" else "/"
	return a .. sep .. b
end

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

local function as_str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	if type(v) == "number" then
		return tostring(v)
	end
	return nil
end

local function as_num(v: any): number?
	if type(v) == "number" then
		return v
	end
	if type(v) == "string" then
		return tonumber(v)
	end
	return nil
end

local function as_bool(v: any): boolean?
	if type(v) == "boolean" then
		return v
	end
	return nil
end

local function as_argv(v: any): { string }
	local out: { string } = {}
	if type(v) == "string" and v ~= "" then
		table.insert(out, v)
		return out
	end
	if type(v) ~= "table" then
		return out
	end
	for _, item in v do
		if type(item) == "string" and item ~= "" then
			table.insert(out, item)
		end
	end
	return out
end

local function join_url(base: string, path: string): string
	base = string.gsub(base, "/+$", "")
	if string.sub(path, 1, 1) ~= "/" then
		path = "/" .. path
	end
	return base .. path
end

local function fmt_int(n: number): string
	return tostring(math.floor(n + 0.5))
end

local function fmt_rate(n: number): string
	return string.format("%.1f", n)
end

local function fmt_uptime(s: number): string
	s = math.max(0, math.floor(s))
	if s < 60 then
		return tostring(s) .. "s"
	elseif s < 3600 then
		return tostring(s // 60) .. "m " .. tostring(s % 60) .. "s"
	end
	return tostring(s // 3600) .. "h " .. tostring((s % 3600) // 60) .. "m"
end

local function fmt_bytes_mib(mib: number): string
	if mib >= 1024 then
		return string.format("%.1f GiB", mib / 1024)
	end
	return fmt_int(mib) .. " MiB"
end

local function rate_buf(): { number }
	return {}
end

local function push_rate(state: State, v: number)
	table.insert(state.rates, v)
	while #state.rates > RATE_N do
		table.remove(state.rates, 1)
	end
end

local function log_add(state: State, line: string)
	table.insert(state.log, os.date("%H:%M:%S") .. "  " .. line)
	while #state.log > LOG_MAX do
		table.remove(state.log, 1)
	end
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
end

local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

local function parse_servers(raw: any): { Server }
	local servers: { Server } = {}
	if type(raw) ~= "table" then
		return servers
	end
	for _, item in raw do
		if type(item) == "table" and type(item.id) == "string" and type(item.base_url) == "string" then
			table.insert(servers, {
				id = item.id,
				name = as_str(item.name) or item.id,
				base_url = item.base_url,
				api_key = as_str(item.api_key) or "",
				cwd = as_str(item.cwd),
				start = as_argv(item.start),
				stop = as_argv(item.stop),
				kill = as_argv(item.kill),
				kill_port = as_num(item.kill_port),
			})
		end
	end
	return servers
end

local function builtin_config(): Config
	return {
		poll_ms = 2000,
		selected = "flash-abliterated",
		servers = {
			{
				id = "flash-abliterated",
				name = "Flash Next (abliterated)",
				base_url = "http://127.0.0.1:8080",
				api_key = "",
				cwd = "C:\\Users\\lalal\\OneDrive\\Desktop\\flash-serve\\flash-serve",
				start = {
					"cmd.exe",
					"/c",
					"start",
					"/min",
					"C:\\Users\\lalal\\OneDrive\\Desktop\\flash-serve\\flash-serve\\start-flash-uncensored.bat",
				},
				stop = {},
				kill = { "strata.exe", "strata-vision.exe", "llama-server.exe" },
				kill_port = 8080,
			},
		},
	}
end

local function load_config(): Config
	local data_path = join(tern.plugin.data, "config.json")
	local pack_path = join(tern.plugin.dir, "config.default.json")
	if not tern.fs.exists(data_path) and tern.fs.exists(pack_path) then
		pcall(function()
			tern.fs.write(data_path, tern.fs.read(pack_path, 64 * 1024))
		end)
	end
	local cfg = builtin_config()
	if not tern.fs.exists(data_path) then
		return cfg
	end
	local ok, text = pcall(tern.fs.read, data_path, 64 * 1024)
	if not ok or type(text) ~= "string" then
		return cfg
	end
	local decoded_ok, decoded = pcall(tern.json.decode, text)
	if not decoded_ok or type(decoded) ~= "table" then
		return cfg
	end
	local servers = parse_servers(decoded.servers)
	if #servers == 0 then
		servers = cfg.servers
	end
	local selected = as_str(decoded.selected) or cfg.selected
	local found = false
	for _, s in servers do
		found = found or s.id == selected
	end
	if not found then
		selected = servers[1].id
	end
	return {
		poll_ms = math.max(750, as_num(decoded.poll_ms) or cfg.poll_ms),
		selected = selected,
		servers = servers,
	}
end

local function find_server(cfg: Config, id: string): Server
	for _, s in cfg.servers do
		if s.id == id then
			return s
		end
	end
	return cfg.servers[1]
end

local function headers_for(srv: Server): { [string]: string }
	local h: { [string]: string } = { Accept = "application/json" }
	if srv.api_key ~= "" then
		h.Authorization = "Bearer " .. srv.api_key
	end
	return h
end

local function fetch_json(url: string, headers: { [string]: string }, cb: (any, string?, FetchResult) -> ())
	tern.fetch(url, { headers = headers, timeout_ms = FETCH_MS }, function(r: FetchResult)
		if r.error or r.status == 0 then
			cb(nil, r.error or "no response", r)
			return
		end
		if r.status ~= 200 then
			cb(nil, "HTTP " .. tostring(r.status), r)
			return
		end
		local ok, data = pcall(tern.json.decode, r.body)
		if not ok then
			cb(nil, "not JSON", r)
			return
		end
		cb(data, nil, r)
	end)
end

local function model_ids(data: any): { string }
	local ids: { string } = {}
	if type(data) ~= "table" then
		return ids
	end
	local list = data.data
	if type(list) ~= "table" then
		return ids
	end
	for _, item in list do
		if type(item) == "table" then
			local id = as_str(item.id)
			if id then
				table.insert(ids, id)
			end
		end
	end
	return ids
end

local function apply_health(snap: Snap, health: any)
	if type(health) ~= "table" then
		return
	end
	if as_str(health.service) == "strata" then
		snap.kind = KIND_STRATA
	end
	snap.model = as_str(health.model) or snap.model
	snap.loaded = as_bool(health.loaded)
	snap.images = as_bool(health.images)
	snap.context = as_num(health.max_context) or as_num(health.n_ctx) or snap.context
end

local function apply_live(snap: Snap, status: any)
	if type(status) ~= "table" then
		return
	end
	snap.busy = as_bool(status.busy)
	snap.phase = as_str(status.phase)
	snap.generated = as_num(status.generated)
	snap.tok_s = as_num(status.tokens_per_s)
	snap.queued = as_num(status.queued)
	snap.elapsed_s = as_num(status.elapsed_s)
	local act = status.activity
	if type(act) == "table" then
		snap.requests = as_num(act.requests) or snap.requests
	end
	snap.engine = as_str(status.engine) or snap.engine
	snap.uptime_s = as_num(status.uptime_s) or snap.uptime_s
	local machine = status.machine
	if type(machine) == "table" then
		local gpu = machine.gpu
		if type(gpu) == "table" then
			snap.gpu_used = as_num(gpu.used_mib) or snap.gpu_used
			snap.gpu_total = as_num(gpu.total_mib) or snap.gpu_total
		end
		local ram = machine.ram
		if type(ram) == "table" then
			local used = as_num(ram.used_gib)
			local total = as_num(ram.total_gib)
			if used then
				snap.ram_used = used * 1024
			end
			if total then
				snap.ram_total = total * 1024
			end
		end
	end
	local lt = status.last_timings
	if type(lt) == "table" then
		snap.prompt_n = as_num(lt.prompt_n)
		snap.prompt_s = as_num(lt.prompt_per_second)
		snap.pred_n = as_num(lt.predicted_n)
		snap.pred_s = as_num(lt.predicted_per_second)
	end
end

local function apply_metrics(snap: Snap, met: any)
	if type(met) ~= "table" then
		return
	end
	local eng = met.engine
	if type(eng) == "table" then
		snap.engine = as_str(eng.version) or snap.engine
	end
	local hw = met.hardware
	if type(hw) == "table" then
		local used = as_num(hw.gpu_mem_used)
		local total = as_num(hw.gpu_mem_total)
		if used then
			snap.gpu_used = used / (1024 * 1024)
		end
		if total then
			snap.gpu_total = total / (1024 * 1024)
		end
		local ram_used = as_num(hw.ram_used)
		local ram_total = as_num(hw.ram_total)
		if ram_used then
			snap.ram_used = ram_used / (1024 * 1024)
		end
		if ram_total then
			snap.ram_total = ram_total / (1024 * 1024)
		end
	end
end

local function publish(state: State)
	local srv = find_server(state.cfg, state.selected)
	local snap = state.snap
	local payload: { [string]: any } = {
		id = srv.id,
		name = srv.name,
		kind = if snap then snap.kind else KIND_OFFLINE,
		model = if snap then snap.model else nil,
		loaded = if snap then snap.loaded else nil,
		busy = if snap then snap.busy else nil,
		tok_s = if snap then snap.tok_s else nil,
		starting = state.starting,
		stopping = state.stopping,
		at = os.time(),
	}
	pcall(tern.kv.set, "status", payload)
end

local function poll(state: State)
	if not alive(state) or state.busy ~= nil then
		return
	end
	state.busy = "poll"
	local srv = find_server(state.cfg, state.selected)
	local headers = headers_for(srv)
	fetch_json(join_url(srv.base_url, "/health"), headers, function(health, err, r)
		if not alive(state) then
			return
		end
		if err then
			state.snap = {
				kind = KIND_OFFLINE,
				error = err,
				http = r.status,
				models = {},
				at = os.time(),
			}
			if state.starting and (r.status == 0 or r.error ~= nil) then
				-- still coming up
			else
				state.starting = false
			end
			state.busy = nil
			publish(state)
			state.cx:render()
			return
		end
		state.starting = false
		local snap: Snap = {
			kind = KIND_UP,
			http = r.status,
			models = {},
			at = os.time(),
		}
		apply_health(snap, health)
		local pending = 3
		local function done()
			pending -= 1
			if pending > 0 then
				return
			end
			if not alive(state) then
				return
			end
			state.snap = snap
			push_rate(state, snap.tok_s or snap.pred_s or 0)
			state.busy = nil
			publish(state)
			state.cx:render()
		end
		fetch_json(join_url(srv.base_url, "/v1/status"), headers, function(data, _, _)
			apply_live(snap, data)
			done()
		end)
		fetch_json(join_url(srv.base_url, "/status"), headers, function(data, _, _)
			apply_live(snap, data)
			done()
		end)
		fetch_json(join_url(srv.base_url, "/v1/models"), headers, function(data, _, _)
			snap.models = model_ids(data)
			if snap.model == nil and snap.models[1] then
				snap.model = snap.models[1]
			end
			done()
		end)
		fetch_json(join_url(srv.base_url, "/metrics"), headers, function(data, _, _)
			apply_metrics(snap, data)
			-- metrics is extra; don't stall the three required fetches
		end)
	end)
end

local function schedule(state: State)
	if not alive(state) or state.timer then
		return
	end
	state.timer = tern.timer(state.cfg.poll_ms, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		poll(state)
		schedule(state)
	end)
end

local function run_argv(argv: { string }, cwd: string?, timeout_ms: number, cb: (ProcessResult) -> ()): string?
	if #argv == 0 then
		return "no command configured"
	end
	local opts: ProcessOptions = { timeout_ms = timeout_ms }
	if cwd then
		opts.cwd = cwd
	end
	local ok, err = pcall(function()
		tern.process.run(argv, opts, function(result: ProcessResult)
			cb(result)
		end)
	end)
	if ok then
		return nil
	end
	return tostring(err)
end

local function win_kill_script(srv: Server): string
	local parts: { string } = {}
	for _, image in srv.kill do
		local name = string.gsub(image, "%.exe$", "")
		table.insert(parts, string.format("Stop-Process -Name %q -Force -ErrorAction SilentlyContinue", name))
	end
	if srv.kill_port then
		table.insert(
			parts,
			string.format(
				"Get-NetTCPConnection -LocalPort %d -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }",
				srv.kill_port
			)
		)
	end
	return table.concat(parts, "; ")
end

local function stop_server(state: State)
	if not alive(state) or state.stopping then
		return
	end
	local srv = find_server(state.cfg, state.selected)
	state.stopping = true
	state.starting = false
	log_add(state, "stopping " .. srv.name)
	state.cx:render()
	local function finish(msg: string)
		if not alive(state) then
			return
		end
		state.stopping = false
		log_add(state, msg)
		publish(state)
		state.cx:render()
		poll(state)
	end
	local function kill_rest()
		if tern.runtime.os == "windows" and (#srv.kill > 0 or srv.kill_port) then
			local script = win_kill_script(srv)
			local spawn = run_argv({ "powershell.exe", "-NoProfile", "-Command", script }, nil, 15000, function(r)
				finish(if r.status == 0 then "stopped" else "stop finished (exit " .. tostring(r.status) .. ")")
			end)
			if spawn then
				finish("stop failed: " .. spawn)
			end
			return
		end
		if #srv.kill > 0 then
			local argv: { string } = { "pkill", "-f" }
			table.insert(argv, srv.kill[1])
			local spawn = run_argv(argv, nil, 8000, function(_r)
				finish("stop signal sent")
			end)
			if spawn then
				finish("stop failed: " .. spawn)
			end
			return
		end
		finish("no stop command configured")
	end
	if #srv.stop > 0 then
		local spawn = run_argv(srv.stop, srv.cwd, 20000, function(r)
			if not alive(state) then
				return
			end
			if r.stdout ~= "" then
				log_add(state, trim(r.stdout))
			end
			if r.stderr ~= "" then
				log_add(state, trim(r.stderr))
			end
			kill_rest()
		end)
		if spawn then
			log_add(state, spawn)
			kill_rest()
		end
		return
	end
	kill_rest()
end

local function start_server(state: State)
	if not alive(state) or state.starting then
		return
	end
	local srv = find_server(state.cfg, state.selected)
	if #srv.start == 0 then
		log_add(state, "no start command configured for " .. srv.id)
		state.cx:render()
		return
	end
	state.starting = true
	log_add(state, "starting " .. srv.name)
	state.cx:render()
	local spawn = run_argv(srv.start, srv.cwd, 15000, function(r)
		if not alive(state) then
			return
		end
		if r.timed_out then
			log_add(state, "start launcher timed out (server may still be coming up)")
		elseif r.status ~= 0 then
			log_add(state, "start launcher exit " .. tostring(r.status))
			if r.stderr ~= "" then
				log_add(state, trim(r.stderr))
			end
			if r.stdout ~= "" then
				log_add(state, trim(r.stdout))
			end
		else
			log_add(state, "start launched; waiting for /health")
		end
		publish(state)
		state.cx:render()
		poll(state)
	end)
	if spawn then
		state.starting = false
		log_add(state, "could not start: " .. spawn)
		state.cx:render()
	end
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function action_badge(label: string, act: string, tone: string): Node
	return with(ui.badge(label, tone), { actions = { click = act }, key = act })
end

local function btn(label: string, act: string, class: string): Node
	return with(ui.el("button", { class = class, text = label }), {
		actions = { click = act },
		key = act,
	})
end

local function status_label(state: State): (string, string)
	if state.stopping then
		return "stopping", "warning"
	end
	if state.starting then
		return "starting", "warning"
	end
	local snap = state.snap
	if snap == nil then
		return "checking", "muted"
	end
	if snap.kind == KIND_OFFLINE then
		return "offline", "error"
	end
	if snap.loaded == false then
		return "unloaded", "warning"
	end
	if snap.busy then
		return "busy", "accent"
	end
	if snap.kind == KIND_STRATA then
		return "ready", "success"
	end
	return "up", "info"
end

local function server_switcher(state: State): Node?
	if #state.cfg.servers < 2 then
		return nil
	end
	local badges: { Node } = {}
	for _, srv in state.cfg.servers do
		local tone = if srv.id == state.selected then "accent" else "neutral"
		table.insert(badges, action_badge(srv.name, "select=" .. srv.id, tone))
	end
	return with(ui.row(badges), { key = "servers", role = "strata.switcher" })
end

local function controls(state: State): Node
	return with(ui.row({
		btn("Start", "start", if state.starting then "strata-btn muted" else "strata-btn go"),
		btn("Stop", "stop", if state.stopping then "strata-btn muted" else "strata-btn stop"),
		btn("Refresh", "refresh", "strata-btn"),
	}), { key = "controls", role = "strata.controls" })
end

local function hero(state: State, srv: Server): Node
	local label, tone = status_label(state)
	local chips: { Node } = {
		with(ui.badge(label, tone), { key = "status" }),
	}
	local snap = state.snap
	if snap and snap.loaded == true then
		table.insert(chips, with(ui.badge("loaded", "success"), { key = "loaded" }))
	elseif snap and snap.loaded == false then
		table.insert(chips, with(ui.badge("unloaded", "warning"), { key = "loaded" }))
	end
	if snap and snap.images == true then
		table.insert(chips, with(ui.badge("vision", "info"), { key = "vision" }))
	end
	if snap and snap.context then
		table.insert(chips, with(ui.badge(fmt_int(snap.context // 1024) .. "K ctx", "neutral"), { key = "ctx" }))
	end
	if snap and snap.engine then
		table.insert(chips, with(ui.badge(snap.engine, "muted"), { key = "eng" }))
	end
	local activity: Node
	if state.starting then
		activity = with(ui.node("spinner", {
			style = "dots",
			label = { ui.span("Loading model — PC may freeze 1–3 min", "muted") },
		}), { key = "activity" })
	elseif snap and snap.kind == KIND_OFFLINE then
		activity = with(ui.text({ ui.span(snap.error or "not reachable", "error") }), { key = "activity" })
	elseif snap and snap.busy then
		local phase = ui.span(snap.phase or "generating", "accent")
		phase.fx = "pulse"
		local extra = ""
		if snap.tok_s then
			extra ..= "  " .. fmt_rate(snap.tok_s) .. " tok/s"
		end
		if snap.elapsed_s then
			extra ..= "  " .. fmt_rate(snap.elapsed_s) .. "s"
		end
		activity = with(ui.text({ phase, ui.span(extra, "muted num") }), { key = "activity" })
	else
		activity = with(ui.text({ ui.span("idle", "dim") }), { key = "activity" })
	end
	local body: { Node } = {
		with(ui.row(chips), { key = "chips" }),
		with(ui.text({ ui.span(if snap and snap.model then snap.model else srv.name, "strong") }), { key = "model" }),
		with(ui.text({ ui.span(srv.base_url .. "/v1", "muted code") }), { key = "url" }),
		activity,
		controls(state),
	}
	local card = ui.card({ ui.span(srv.name, "strong") }, body)
	return with(card, { tone = tone, key = "hero", role = "strata.hero" })
end

local function hardware(snap: Snap): Node?
	local rows: { { any } } = {}
	if snap.gpu_used and snap.gpu_total and snap.gpu_total > 0 then
		local frac = math.clamp(snap.gpu_used / snap.gpu_total, 0, 1)
		table.insert(rows, {
			"GPU",
			ui.meter_cell(frac, { 0.75, 0.92 }),
			fmt_bytes_mib(snap.gpu_used) .. " / " .. fmt_bytes_mib(snap.gpu_total),
		})
	end
	if snap.ram_used and snap.ram_total and snap.ram_total > 0 then
		local frac = math.clamp(snap.ram_used / snap.ram_total, 0, 1)
		table.insert(rows, {
			"RAM",
			ui.meter_cell(frac, { 0.8, 0.95 }),
			fmt_bytes_mib(snap.ram_used) .. " / " .. fmt_bytes_mib(snap.ram_total),
		})
	end
	if #rows == 0 then
		return nil
	end
	return with(ui.card({ ui.span("Memory", "strong") }, {
		ui.table({
			{ id = "res", head = "", grow = 0 },
			{ id = "bar", head = "Use", grow = 1 },
			{ id = "val", head = "", align = "end", grow = 0 },
		}, rows),
	}), { key = "hw" })
end

local function live(state: State): Node?
	local snap = state.snap
	if snap == nil or snap.kind == KIND_OFFLINE then
		return nil
	end
	local chips: { Node } = {
		with(ui.badge(fmt_rate(snap.tok_s or 0) .. " tok/s", if snap.busy then "accent" else "muted"), { key = "tps" }),
		with(ui.badge(fmt_int(snap.requests or 0) .. " req", "neutral"), { key = "req" }),
		with(ui.badge(if snap.uptime_s then fmt_uptime(snap.uptime_s) else "—", "muted"), { key = "up" }),
		with(ui.badge(fmt_int(snap.queued or 0) .. " queued", if (snap.queued or 0) > 0 then "warning" else "muted"), { key = "q" }),
	}
	local series: { { any } } = {}
	for i = 1, RATE_N do
		series[i] = { string.format("%02d", i), state.rates[i] or 0 }
	end
	local last = {
		{
			"Prompt",
			if snap.prompt_n then fmt_int(snap.prompt_n) .. " tok" else "—",
			if snap.prompt_s then fmt_rate(snap.prompt_s) .. "/s" else "—",
		},
		{
			"Decode",
			if snap.pred_n then fmt_int(snap.pred_n) .. " tok" else "—",
			if snap.pred_s then fmt_rate(snap.pred_s) .. "/s" else "—",
		},
	}
	return with(ui.card({ ui.span("Live", "strong") }, {
		with(ui.row(chips), { key = "livechips" }),
		with(ui.spark(series), { key = "spark" }),
		with(ui.table({
			{ id = "kind", head = "Last request", grow = 1 },
			{ id = "n", head = "Tokens", align = "end" },
			{ id = "r", head = "Speed", align = "end" },
		}, last), { key = "last" }),
	}), { key = "live" })
end

local function log_view(state: State): Node
	local text = if #state.log > 0 then table.concat(state.log, "\n") else "no events yet"
	return with(ui.ansi(text), { role = "strata.log", key = "log" })
end

local function log_card(state: State): Node
	return with(ui.card({ ui.span("Console", "muted") }, { log_view(state) }), {
		key = "console",
		collapsible = true,
		collapsed = true,
	})
end

tern.block.define("panel", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local cfg = load_config()
		local selected = cfg.selected
		if type(args[1]) == "string" and args[1] ~= "" then
			selected = args[1]
		elseif type(saved) == "table" and type(saved.selected) == "string" then
			selected = saved.selected
		end
		local found = false
		for _, s in cfg.servers do
			found = found or s.id == selected
		end
		if not found then
			selected = cfg.servers[1].id
		end
		local state: State = {
			cx = cx,
			cfg = cfg,
			selected = selected,
			snap = nil,
			log = {},
			rates = rate_buf(),
			busy = nil,
			starting = false,
			stopping = false,
			timer = nil,
		}
		running[cx.pane] = state
		log_add(state, "panel open · config " .. join(tern.plugin.data, "config.json"))
		poll(state)
		schedule(state)
		return state
	end,

	title = function(state: State): string?
		local srv = find_server(state.cfg, state.selected)
		local label, _ = status_label(state)
		return srv.name .. " · " .. label
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local srv = find_server(state.cfg, state.selected)
		local main: { Node } = { hero(state, srv) }
		local switcher = server_switcher(state)
		if switcher then
			table.insert(main, 1, switcher)
		end
		if state.snap then
			local hw = hardware(state.snap)
			if hw then
				table.insert(main, hw)
			end
		end
		local live_card = live(state)
		if live_card then
			table.insert(main, live_card)
		end
		table.insert(main, log_card(state))
		return {
			main = with(ui.col(main), { role = "strata.main", gap = "md" }),
			dock = with(ui.col({
				controls(state),
				ui.text({
					ui.span("s", "code"),
					ui.span(" start  ", "dim"),
					ui.span("x", "code"),
					ui.span(" stop  ", "dim"),
					ui.span("r", "code"),
					ui.span(" refresh", "dim"),
				}),
			}), { role = "strata.dock" }),
		}
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if k == "s" then
			start_server(state)
		elseif k == "x" then
			stop_server(state)
		elseif k == "r" then
			state.cfg = load_config()
			log_add(state, "reloaded config")
			poll(state)
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "start" then
			start_server(state)
		elseif ev.act == "stop" then
			stop_server(state)
		elseif ev.act == "refresh" then
			state.cfg = load_config()
			poll(state)
		elseif ev.act == "select" and type(ev.value) == "string" then
			state.selected = ev.value
			state.snap = nil
			state.rates = rate_buf()
			log_add(state, "selected " .. ev.value)
			poll(state)
		end
	end,

	save = function(state: State): any
		return { selected = state.selected }
	end,
})
