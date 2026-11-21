--- jsonreq: JSON over HTTP(S) requests and JSON-RPC 2.0 client helpers.
-- Works on Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.
local _M = {
	_VERSION     = 'json-request 0.2.2',
	_DESCRIPTION = 'JSON-Request (jsonreq) : handles general JSON HTTP/anything request with headers and JSONRPC functions.',
	_COPYRIGHT   = 'Copyright (C) Sam Orlando 2026',
	verbose = false -- when true, prints method/url and payload (may expose secrets)
}

local type, pairs, next, tostring, pcall, require, setmetatable, getmetatable, rawget, print =
	type, pairs, next, tostring, pcall, require, setmetatable, getmetatable, rawget, print
local lower, concat = string.lower, table.concat

-- JSON backend: lua-cjson preferred, dkjson fallback. Replaceable via _M.json.
local function load_json()
	local ok, lib = pcall(require, "cjson")
	if ok then return lib end
	ok, lib = pcall(require, "dkjson")
	if ok then return lib end
	error("jsonreq: no JSON library found (install lua-cjson or dkjson)", 3)
end
_M.json = load_json()

local function is_https(url) return lower(url:sub(1, 8)) == "https://" end

_M.TIMEOUT = 15 -- default request timeout in seconds (client opt.timeout / per-call override)

-- Transports are loaded lazily so plain-HTTP users do not need luasec.
local http_mod, https_mod, ltn12
local function get_module(https)
	if https then
		https_mod = https_mod or require("ssl.https")
		return https_mod
	end
	http_mod = http_mod or require("socket.http")
	return http_mod
end

-- Default transport: luasocket/luasec request with rtbl.timeout applied.
-- Both modules read their TIMEOUT field per connection (luasec forbids a
-- custom 'create'), so it is set for the duration of this blocking call.
local function default_transport(rtbl)
	local mod = get_module(is_https(rtbl.url))
	local old = mod.TIMEOUT
	mod.TIMEOUT = rtbl.timeout or _M.TIMEOUT
	local ok, res, code, h = pcall(mod.request, rtbl)
	mod.TIMEOUT = old
	if not ok then return nil, tostring(res) end
	-- luasec reports TLS-level timeouts as "wantread"/"wantwrite"
	if not res and (code == "wantread" or code == "wantwrite") then code = "timeout" end
	return res, code, h
end
_M.default_transport = default_transport


local function copy(t, into)
	into = into or {}
	if t then for k, v in pairs(t) do into[k] = v end end
	return into
end


local request_reserved = { jsonrpc = true, method = true, params = true, id = true }
local response_reserved = { jsonrpc = true, result = true, error = true, id = true }

-- n % 1 rejects NaN and inf: those results are not 0.
local function is_integer(n) return type(n) == "number" and n % 1 == 0 end

local function is_json_null(v)
	local n = _M.json.null
	return n ~= nil and v == n
end

local function has_array_mt(t)
	local mt = getmetatable(t)
	if mt == nil then return false end
	local j = _M.json
	return mt == j.empty_array_mt or mt == j.array_mt
end

-- "array", "sparse", "object", "empty", or "bad" (mixed or non-JSON keys).
local function classify(t)
	local maxk, count, has_string = 0, 0, false
	for k in pairs(t) do
		count = count + 1
		if type(k) == "number" and k >= 1 and k % 1 == 0 then
			if k > maxk then maxk = k end
		elseif type(k) == "string" then
			has_string = true
		else
			return "bad"
		end
	end
	if has_string then return maxk > 0 and "bad" or "object" end
	if count == 0 then return has_array_mt(t) and "array" or "empty" end
	return maxk == count and "array" or "sparse"
end

-- nil omits params. {} is omitted: Lua cannot tell it from []. json.empty_array sends [].
-- Named client params merge only into an object. The caller's table is not modified.
-- It is reused as-is unless a merge needs a new table.
local function build_params(user_params, injected)
	if injected ~= nil and type(injected) ~= "table" then
		return nil, "jsonreq: client params must be a table"
	end
	local injecting = injected ~= nil and next(injected) ~= nil
	local empty_array = _M.json.empty_array
	if user_params == nil then
		if not injecting then return nil end
		user_params = {}
	elseif empty_array ~= nil and user_params == empty_array then
		if injecting then
			return nil, "jsonreq: cannot inject named params into positional params"
		end
		return empty_array
	elseif type(user_params) ~= "table" then
		return nil, "jsonreq: params must be an array or an object"
	end

	local kind = classify(user_params)
	if kind == "bad" then
		return nil, "jsonreq: params must be an array or an object"
	end
	if kind == "array" or kind == "sparse" then
		if injecting then
			return nil, "jsonreq: cannot inject named params into positional params"
		end
		return user_params
	end
	if not injecting then
		if kind == "empty" then return nil end
		return user_params
	end

	local out = copy(user_params)
	copy(injected, out)
	kind = classify(out)
	if kind == "bad" then
		return nil, "jsonreq: params must be an array or an object"
	end
	if kind == "empty" then return nil end
	return out
end

local function accept_id(id)
	if is_integer(id) or type(id) == "string" or is_json_null(id) then return id end
	if type(id) == "number" then return nil, "jsonreq: id number must be an integer" end
	return nil, "jsonreq: id must be a string, integer, or null"
end

-- Returns sent_id, omit_id, err. false omits id (notification). nil allocates one.
local function resolve_id(self, id)
	if id == nil then
		self.next_id = (self.next_id or 0) + 1
		return self.next_id
	end
	if id == false then return nil, true end
	local sent, err = accept_id(id)
	if err then return nil, false, err end
	return sent
end

local function ids_equal(a, b)
	if is_json_null(a) or is_json_null(b) then
		return is_json_null(a) and is_json_null(b)
	end
	return type(a) == type(b) and a == b
end

local function is_array(t)
	if type(t) ~= "table" or #t == 0 then return false end
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
	end
	return true
end

-- Error string, or nil. A JSON null placeholder for the unused result or error
-- member is one outcome. A real result next to a real error is not.
-- sent_id can be omitted to validate a table being send for construction
local function validate_response(resp, sent_id)
	if type(resp) ~= "table" or is_array(resp) then
		return "jsonreq: response must be an object"
	end
	if resp.jsonrpc ~= "2.0" then
		return "jsonreq: response jsonrpc must be \"2.0\""
	end
	if resp.id == nil then
		return "jsonreq: response missing id"
	end
	if sent_id and not ids_equal(resp.id, sent_id) then
		return "jsonreq: response id does not match request"
	end
	local result_set = resp.result ~= nil and not is_json_null(resp.result)
	local error_set = type(resp.error) == "table"
	if error_set and result_set then
		return "jsonreq: response contains both result and error"
	end
	if error_set then
		if not is_integer(resp.error.code) then
			return "jsonreq: error.code must be an integer"
		end
		if type(resp.error.message) ~= "string" then
			return "jsonreq: error.message must be a string"
		end
		return nil
	end
	if resp.result == nil then
		return "jsonreq: response missing result"
	end
end

-- nil is an unknown request id, sent as JSON null. Does not allocate client ids.
local function rpc_id(id)
	if id ~= nil then return accept_id(id) end
	local null = _M.json.null
	if null == nil then return nil, "jsonreq: id must be a string, integer, or null" end
	return null
end

-- One pass. A rejected root leaves tbl partial; the caller discards it.
local function attach_root(tbl, root, reserved)
	if root == nil then return tbl end
	if type(root) ~= "table" then return nil, "jsonreq: root must be a table" end
	for k, v in pairs(root) do
		if reserved[k] then
			return nil, "jsonreq: root cannot override '" .. k .. "'"
		end
		tbl[k] = not tbl[k] and v
	end
	return tbl
end

local function pack_proxy_args(proxy, ...)
	local n = select("#", ...)
	local start_at = 1
	if n > 0 and select(1, ...) == proxy then start_at = 2 end
	local null = _M.json.null
	local out = {}
	for i = start_at, n do
		local v = select(i, ...)
		if v == nil then v = null end
		out[i - start_at + 1] = v
	end
	return out
end

local function safe_decode(s)
	if s == nil or s == "" then return nil end
	local json = _M.json
	local ok, res, _, err = pcall(json.decode, s)
	if not ok then return nil, "json decode error: " .. tostring(res) end
	if res == nil and err then return nil, "json decode error: " .. tostring(err) end -- dkjson style
	return res
end

local function safe_encode(v)
	local ok, res = pcall(_M.json.encode, v)
	if not ok then return nil, "json encode error: " .. tostring(res) end
	return res
end

local function encode_tbl(tbl, err)
	if not tbl then return nil, err end
	return safe_encode(tbl)
end

_M.meta = { methods = {} }
local mm = _M.meta.methods
_M.meta.__index = mm

--- Default HTTP request handler.
-- Returns: decoded_body, status_code, response_headers, raw_body
-- On transport failure: nil, error_message
-- On non-JSON body: nil, status_code, response_headers, raw_body, decode_error
local function request_handler_http(self, payload, headers, resource, method, timeout)
	local url = (self.url or "") .. (resource or "")
	local transport = self.transport or default_transport
	ltn12 = ltn12 or require("ltn12")
	local response_body = {}
	local rtbl = {
		url = url,
		method = method or "POST",
		headers = headers,
		source = (payload and payload ~= "") and ltn12.source.string(payload) or nil,
		sink = ltn12.sink.table(response_body),
		timeout = timeout or self.timeout or _M.TIMEOUT,
	}
	if _M.verbose then
		print(rtbl.method .. " -> " .. url)
		if payload then print(payload) end
	end

	local res, code, rheaders = transport(rtbl)
	if not res then return nil, tostring(code) end

	local raw = concat(response_body)
	local body, err = safe_decode(raw)
	if err then return nil, code, rheaders, raw, err end
	return body, code, rheaders, raw
end
_M.request_handler_http = request_handler_http

_M.new = function(opt)
	opt = opt or {}
	if type(opt) == "string" then opt = { url = opt } end

	local tbl = {
		enabled = opt.enabled ~= false,
		params = opt.params or {}, -- injected params (for jsonrpc)
		root = opt.root or {},     -- injected root table items
		url = opt.url,             -- base url/uri
		headers = opt.headers or {}, -- injected headers on calls (for auth, etc)
		request_handler = opt.request_handler or request_handler_http,
		timeout = opt.timeout,     -- seconds; nil -> jsonreq.TIMEOUT
		transport = opt.transport, -- optional function(rtbl) -> res, code, headers (luasocket style)
		next_id = 0,
	}
	local obj = setmetatable(tbl, _M.meta)
	-- obj.proxy.method(a, b) -> obj:request("method", {a, b})
	-- A nil argument is sent as JSON null. Colon calls drop the proxy receiver.
	tbl.proxy = setmetatable({}, {
		__index = function(proxy, key)
			return function(...) return obj:request(key, pack_proxy_args(proxy, ...)) end
		end,
		-- backward compat: obj:proxy() returns the proxy table
		__call = function(self) return self end,
	})
	return obj
end

-- Instance headers, then per-call headers. Content-Type and Content-Length are
-- set from ctype and len. Other spellings are left as given.
local function build_headers(self, headers, ctype, len)
	local h = copy(self.headers)
	if type(headers) == "table" then copy(headers, h) end
	h["Content-Type"] = ctype and ctype
	h["Content-Length"] = len and tostring(len)
	return h
end

local function post_json(self, payload, headers, resource, timeout)
	return self.request_handler(self, payload,
		build_headers(self, headers, "application/json", #payload),
		resource or "", "POST", timeout)
end

mm.validate_response = function(self, t) return validate_response(t) end

function mm:request_table(method, params, id)
	if type(method) ~= "string" then
		return nil, "jsonreq: method must be a string"
	end
	local params_value, perr = build_params(params, self.params)
	if perr then return nil, perr end
	-- Root is checked before resolve_id so a rejection does not consume an id.
	local tbl = { jsonrpc = "2.0", method = method }
	if params_value ~= nil then tbl.params = params_value end
	tbl, perr = attach_root(tbl, self.root, request_reserved)
	if not tbl then return nil, perr end
	local sent_id, omit, ierr = resolve_id(self, id)
	if ierr then return nil, ierr end
	if not omit then tbl.id = sent_id end
	return tbl
end

function mm:request_string(method, params, id)
	return encode_tbl(self:request_table(method, params, id))
end

function mm:request(method, params, id, headers, resource, timeout)
	if not self.enabled then return nil, "disabled" end
	local request_tbl, err = self:request_table(method, params, id)
	if not request_tbl then return nil, err end
	local payload, eerr = safe_encode(request_tbl)
	if not payload then return nil, eerr end
	local body, code, rheaders, raw, derr = post_json(self, payload, headers, resource, timeout)
	-- Transport failure keeps nil, message. A notification does not require a body.
	if type(code) ~= "number" or derr then
		return body, code, rheaders, raw, derr
	end
	if request_tbl.id == nil then
		return body, code, rheaders, raw
	end
	if body == nil then
		return nil, code, rheaders, raw, "jsonreq: empty response"
	end
	local verr = validate_response(body, request_tbl.id)
	if verr then return nil, code, rheaders, raw, verr end
	return body, code, rheaders, raw
end
-- ease and naming shortcuts
mm.rpc = mm.request
mm.rpc_table = mm.request_table
mm.rpc_string = mm.request_string

function mm:notify(method, params, headers, resource, timeout)
	return self:request(method, params, false, headers, resource, timeout)
end

function mm:response_table(result, id)
	local sent_id, ierr = rpc_id(id)
	if ierr then return nil, ierr end
	if result == nil then
		result = _M.json.null
		if result == nil then return nil, "jsonreq: JSON null is not available" end
	end
	return attach_root({ jsonrpc = "2.0", result = result, id = sent_id }, self.root, response_reserved)
end

function mm:response_string(result, id)
	return encode_tbl(self:response_table(result, id))
end

function mm:error_table(code, message, id, data)
	if not is_integer(code) then return nil, "jsonreq: error.code must be an integer" end
	if type(message) ~= "string" then return nil, "jsonreq: error.message must be a string" end
	local sent_id, ierr = rpc_id(id)
	if ierr then return nil, ierr end
	local err_obj = { code = code, message = message }
	if data ~= nil then err_obj.data = data end
	return attach_root({ jsonrpc = "2.0", error = err_obj, id = sent_id }, self.root, response_reserved)
end

function mm:error_string(code, message, id, data)
	return encode_tbl(self:error_table(code, message, id, data))
end

function mm:call(payload, headers, resource, method, timeout)
	if not self.enabled then return nil, "disabled" end
	if type(payload) == "table" then
		payload = copy(self.root, payload)
	end
	if payload ~= nil and type(payload) ~= "string" then
		local err
		payload, err = safe_encode(payload)
		if not payload then return nil, err end
	end
	payload = payload or ""
	local h = build_headers(self, headers, "application/json", #payload)
	return self.request_handler(self, payload, h, resource or "", method or "POST", timeout)
end

function mm:get(resource, headers, timeout) return self:call(nil, headers, resource, "GET", timeout) end
function mm:post(resource, payload, headers, timeout) return self:call(payload, headers, resource, "POST", timeout) end
function mm:put(resource, payload, headers, timeout) return self:call(payload, headers, resource, "PUT", timeout) end
function mm:patch(resource, payload, headers, timeout) return self:call(payload, headers, resource, "PATCH", timeout) end
function mm:delete(resource, headers, timeout) return self:call(nil, headers, resource, "DELETE", timeout) end

return _M
