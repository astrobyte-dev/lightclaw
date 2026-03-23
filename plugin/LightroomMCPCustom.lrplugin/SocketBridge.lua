-- Two-socket bridge for Lightroom MCP Custom.
--
-- senderSocket (mode="send", senderPort):
--   Lua uses this to SEND responses back to Python.
--   Python connects here and READS responses/events.
--   No onMessage on this socket needed.
--
-- receiverSocket (mode="receive", receiverPort):
--   Python connects here and WRITES commands to Lua.
--   LrSocket fires onMessage in Lua for each incoming chunk.
--   Lua dispatches the command and sends the response via senderSocket.
--
-- Windows path fix: LrPathUtils.getStandardFilePath("temp") replaces /tmp/

local LrFileUtils = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils = import "LrPathUtils"
local LrSocket = import "LrSocket"
local LrTasks = import "LrTasks"

local Logger = require "Logger"
local JSON = require "JSON"
local CommandRouter = require "CommandRouter"

local SocketBridge = {}

local state = {
    running = false,
    senderSocket = nil,
    receiverSocket = nil,
    senderPort = nil,
    receiverPort = nil,
    senderConnected = false,
    receiverConnected = false,
    senderConnectedAt = nil,
    receiveBuffer = "",
    sessionId = nil,
    startedAt = nil,
    needsRestart = false,
}

local PORT_FILE = LrPathUtils.child(
    LrPathUtils.getStandardFilePath("temp"),
    "lightroom_mcp_custom_ports.json"
)

local function cleanupPortFile()
    if LrFileUtils.exists(PORT_FILE) then
        LrFileUtils.delete(PORT_FILE)
    end
end

local function writePortFileIfReady()
    if state.senderPort and state.receiverPort then
        local payload = JSON.encode({
            port         = state.senderPort,
            send_port    = state.senderPort,
            receive_port = state.receiverPort,
            session_id   = state.sessionId,
            started_at   = state.startedAt,
            plugin       = "Lightroom MCP Custom",
            version      = "0.4.0",
        })
        local file = io.open(PORT_FILE, "w")
        if file then
            file:write(payload)
            file:write("\n")
            file:close()
            Logger.info("Wrote port file (send=" .. tostring(state.senderPort) .. " receive=" .. tostring(state.receiverPort) .. ")")
        else
            Logger.error("Failed to write port file")
        end
    end
end

local function socketKey(socketObj)
    if not socketObj then return nil end
    local ok, key = pcall(function() return tostring(socketObj) end)
    if ok then return key end
    return nil
end

local function sendLine(socketObj, line)
    local ok, sent, err, partial = pcall(function()
        return socketObj:send(line)
    end)
    if not ok then
        return false, "send threw: " .. tostring(sent)
    end
    if sent == nil then
        if err == nil and partial == nil then return true, "sent" end
        return false, tostring(err or "send failed")
    end
    if sent == false then
        return false, tostring(err or "send failed")
    end
    if type(sent) == "number" then
        local n = #line
        if sent < n then
            local progressed = partial
            if type(progressed) ~= "number" then progressed = err end
            return false, string.format("partial send (%s/%s), err=%s",
                tostring(progressed or sent), tostring(n), tostring(err))
        end
    end
    return true, tostring(sent)
end

local function sendResponse(response, preferredSocket)
    local ok, encoded = pcall(function()
        return JSON.encode(response)
    end)
    if not ok then
        Logger.error("JSON encode failure: " .. tostring(encoded))
        return false
    end
    encoded = string.gsub(encoded, "\r", "")
    encoded = string.gsub(encoded, "\n", "")
    local responseLine = encoded .. "\n"

    local candidates = {}
    local seen = {}

    local function enqueue(name, socketObj, connected)
        if not socketObj or not connected then return end
        local key = socketKey(socketObj)
        if key and seen[key] then return end
        if key then seen[key] = true end
        candidates[#candidates + 1] = { name = name, socket = socketObj }
    end

    -- Send via senderSocket first (Python reads responses from there).
    enqueue("sender", state.senderSocket, state.senderConnected)
    enqueue("receiver", state.receiverSocket, state.receiverConnected)

    for _, candidate in ipairs(candidates) do
        local sendOk, detail = sendLine(candidate.socket, responseLine)
        if sendOk then
            Logger.debug("Response sent via " .. candidate.name .. " (" .. tostring(detail) .. ")")
            return true
        end
        Logger.warn("Socket send via " .. candidate.name .. " failed: " .. tostring(detail))
        if candidate.name == "sender" then state.senderConnected = false end
        if candidate.name == "receiver" then state.receiverConnected = false end
    end

    -- Emergency fallback: try any socket ignoring connection state.
    local emergency = {
        { name = "sender-emergency", socket = state.senderSocket },
        { name = "receiver-emergency", socket = state.receiverSocket },
    }
    for _, candidate in ipairs(emergency) do
        local key = socketKey(candidate.socket)
        if candidate.socket and (not key or not seen[key]) then
            local sendOk, detail = sendLine(candidate.socket, responseLine)
            if sendOk then
                Logger.warn("Response sent via " .. candidate.name .. " fallback")
                return true
            end
            Logger.warn("Fallback send via " .. candidate.name .. " failed: " .. tostring(detail))
        end
    end

    Logger.warn("Cannot send response: no connected socket accepted payload")
    return false
end

local function handleMessageLine(line, sourceSocket)
    if line == nil or line == "" then return end
    local ok, request = pcall(function()
        return JSON.decode(line)
    end)
    if not ok then
        Logger.error("Invalid JSON request: " .. tostring(request))
        return
    end
    Logger.debug("Handling request: " .. tostring(request and request.command or "?"))
    LrTasks.startAsyncTask(function()
        local response = CommandRouter.dispatch(request)
        sendResponse(response, sourceSocket)
    end)
end

local function processChunk(chunk, sourceSocket)
    if type(chunk) ~= "string" or chunk == "" then return end
    state.receiveBuffer = state.receiveBuffer .. chunk
    local consumedByNewline = false
    while true do
        local nl = string.find(state.receiveBuffer, "\n", 1, true)
        if not nl then break end
        local line = string.sub(state.receiveBuffer, 1, nl - 1)
        state.receiveBuffer = string.sub(state.receiveBuffer, nl + 1)
        handleMessageLine(line, sourceSocket)
        consumedByNewline = true
    end
    -- LrSocket may deliver message-framed chunks without a trailing newline.
    if (not consumedByNewline) and state.receiveBuffer ~= "" then
        handleMessageLine(state.receiveBuffer, sourceSocket)
        state.receiveBuffer = ""
    end
end

local function scheduleRestart()
    if state.needsRestart then return end
    state.needsRestart = true
    Logger.info("Scheduling bridge restart...")
    LrTasks.startAsyncTask(function()
        LrTasks.sleep(1.0)
        if not state.needsRestart then return end
        Logger.info("Executing deferred bridge restart")
        SocketBridge.stop()
        LrTasks.sleep(0.5)
        SocketBridge.start()
        state.needsRestart = false
    end)
end

function SocketBridge.start()
    if state.running then
        Logger.info("SocketBridge.start called while already running")
        return
    end
    state.running = true
    state.receiveBuffer = ""
    state.senderPort = nil
    state.receiverPort = nil
    state.senderConnected = false
    state.receiverConnected = false
    state.needsRestart = false
    state.startedAt = os.time()
    math.randomseed(state.startedAt)
    state.sessionId = tostring(state.startedAt) .. "-" .. tostring(math.random(100000, 999999))
    cleanupPortFile()
    Logger.info("Starting two-socket MCP bridge")

    LrTasks.startAsyncTask(function()
        LrFunctionContext.callWithContext("LightroomMCPCustomBridge", function(context)

            -- Sender socket: Lua sends responses to Python.
            -- Python connects here and reads responses.
            state.senderSocket = LrSocket.bind {
                functionContext = context,
                plugin          = _PLUGIN,
                address         = "localhost",
                port            = 0,
                mode            = "send",

                onConnecting = function(_, port)
                    state.senderPort = port
                    Logger.info("Sender socket on port " .. tostring(port))
                    writePortFileIfReady()
                end,

                onConnected = function(_, _)
                    state.senderConnected = true
                    state.senderConnectedAt = os.time()
                    Logger.info("Sender socket: client connected")
                end,

                onClosed = function(socket)
                    state.senderConnected = false
                    state.senderConnectedAt = nil
                    Logger.warn("Sender socket closed")
                    if state.running then scheduleRestart() end
                end,

                onError = function(socket, err)
                    if err == "timeout" then
                        Logger.debug("Sender timeout - reconnecting")
                        if state.running then socket:reconnect() end
                    else
                        Logger.error("Sender error: " .. tostring(err))
                        if state.running then scheduleRestart() end
                    end
                end,
            }

            -- Receiver socket: Python sends commands here.
            -- LrSocket fires onMessage when Python sends data.
            state.receiverSocket = LrSocket.bind {
                functionContext = context,
                plugin          = _PLUGIN,
                address         = "localhost",
                port            = 0,
                mode            = "receive",

                onConnecting = function(_, port)
                    state.receiverPort = port
                    Logger.info("Receiver socket on port " .. tostring(port))
                    writePortFileIfReady()
                end,

                onConnected = function(_, _)
                    state.receiverConnected = true
                    Logger.info("Receiver socket: client connected")
                end,

                onMessage = function(socketObj, message)
                    Logger.debug("Receiver onMessage chunk=" .. tostring(#(message or "")))
                    processChunk(message, socketObj)
                end,

                onClosed = function(socket)
                    state.receiverConnected = false
                    Logger.warn("Receiver socket closed")
                    if state.running then scheduleRestart() end
                end,

                onError = function(socket, err)
                    if err == "timeout" then
                        Logger.debug("Receiver timeout - reconnecting")
                        if state.running then socket:reconnect() end
                    else
                        Logger.error("Receiver error: " .. tostring(err))
                        if state.running then scheduleRestart() end
                    end
                end,
            }

            while state.running do
                LrTasks.sleep(0.2)
            end

            if state.senderSocket then pcall(function() state.senderSocket:close() end) end
            if state.receiverSocket then pcall(function() state.receiverSocket:close() end) end
            cleanupPortFile()
            Logger.info("Bridge stopped")
        end)
    end)
end

function SocketBridge.stop()
    if not state.running then return end
    Logger.info("Stopping bridge")
    state.running = false
    state.needsRestart = false
    if state.senderSocket then pcall(function() state.senderSocket:close() end) end
    if state.receiverSocket then pcall(function() state.receiverSocket:close() end) end
    cleanupPortFile()
end

function SocketBridge.status()
    return {
        running          = state.running,
        sender_connected = state.senderConnected,
        receiver_connected = state.receiverConnected,
        sender_port      = state.senderPort,
        receiver_port    = state.receiverPort,
        port_file        = PORT_FILE,
        needs_restart    = state.needsRestart,
    }
end

return SocketBridge
