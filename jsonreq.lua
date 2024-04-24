local _M = {
	_VERSION	 = 'json-request 0.0.2',
	_DESCRIPTION = 'JSON-Request : handles general JSON HTTP/anything request with headers and optional request function.',
	_COPYRIGHT   = 'Copyright (C) Sam Orlando 2024 - MIT Cheese Please',
}

local verbose = nil
local http_request = require("socket.http").request
local https_request = require("ssl.https").request
local ltn12 = require("ltn12")
local json = require("cjson")
local encode, decode = json.encode, json.decode
local random = math.random
local tostring, lower = tostring, string.lower
local concat = table.concat
local function is_https(url) return lower(url:sub(1, 8)) == "https://" end

-- removed meta because of potential methods using global rawget, etc before localization
_M.meta = {
		methods = {},
		__index = function(self, key) return rawget(getmetatable(self), "methods")[key] or rawget(self, key) end,
	}

local mm = _M.meta.methods -- meta methods for module - short var ref
local random_string = function() return tostring(random()) end

-- default handler for module - others can be added
local request_handler_http = function(self, payload, headers, resource, method)
	local response_body = {}
	local url = self.url .. resource
	local rtbl = {
		url = url,
		method = method or "POST",
		headers = headers,
		source = ltn12.source.string(payload),
		sink = ltn12.sink.table(response_body)
	}
	
	if verbose then
		print(rtbl.method .. " -> " .. url)
		--printTable(headers or {})
		print(payload)
	end
	
	local res, code
    if is_https(url) then res, code = https_request(rtbl)
    else res, code = http_request(rtbl)end

	-- TODO: need better error handling
	return decode(concat(response_body)), code
end

_M.new = function(opt)
	opt = opt or {}
	if type(opt) == "string" then opt = {url=opt} end
	
	local tbl = {
		enabled = opt.enabled and opt.enabled or true,
		params = {}, -- injected params (for jsonrpc)
		root = {}, -- root table items
		root2params = nil, -- if true do this, false remove this
		params2root = nil, -- if true do this, false remove this
		url = opt.url, -- base url/uri
		headers = {}, -- injected headers on calls (for auth, etc)
		request_handler = request_handler_http,
		proxy = setmetatable({}, {
			__index = function(self, key)
				return function(...)
					return self:rpc(key, {...})
				end
			end,
		}),
	}
	return setmetatable(tbl, _M.meta)
end

function mm:rpc_string(method, params, id)
	local params_count = 0
	params = params or {}
	for k,v in pairs(params) do	params_count = params_count + 1	end
	for k,v in pairs(self.params) do
		params[k] = v
		params_count = params_count + 1
	end

	local rpc_tbl = {
		jsonrpc = "2.0",
		method = method,
		params = params_count > 0 and params,
		id = id or tostring(random()),
	}
	
	for k,v in pairs(self.root) do rpc_tbl[k] = v end
	
	return encode(rpc_tbl)
end

function mm:rpc(method, params, id, headers) -- add self toggle for id/headers omit
	local payload = mm:rpc_string(method, params, id)
	if type(headers) ~= "table" then headers = {} end
	for k,v in pairs(self.headers) do headers[k] = v end
	for k,v in pairs({
		["content-type"] = "application/json-rpc",
		["content-length"] = #payload
	}) do headers[k] = v end

	return self.request_handler(self, payload, headers)
end

function mm:proxy()	return rawget(self, "proxy") end

function mm:call(payload, headers, resource, method)
	if type(payload) == "table" then
		for k,v in pairs(self.root) do payload[k] = v end
	end
	payload = payload and encode(payload) or ""

	if type(headers) ~= "table" then headers = {} end
	for k,v in pairs(self.headers) do headers[k] = v end
	for k,v in pairs({
		["content-type"] = "application/json",
		["content-length"] = #payload
	}) do headers[k] = v end

	return self.request_handler(self, payload, headers, resource, method)
end
	
function mm:get(resource, headers) return self:call(nil, headers, resource, "GET") end
function mm:post(resource, payload, headers) return self:call(payload, headers, resource, "POST")  end
function mm:put(resource, payload, headers) return self:call(payload, headers, resource, "PUT")  end
function mm:update(resource, payload, headers) return self:call(payload, headers, resource, "UPDATE")  end
function mm:delete(resource, headers) return self:call(nil, headers, resource, "DELETE")  end

return _M