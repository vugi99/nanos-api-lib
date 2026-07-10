APILib = {}
Package.Export("APILib", APILib)

Package.Require("Config.lua")

APILib.Cache = {}
APILib.CacheFolderPrefix = (Server and "Packages/" .. Package.GetName() .. "/") or ""
APILib.Initialized = false
APILib.Initializing = false

--- The path to store the last known commit SHA
---@type string
local COMMIT_ID_FILENAME = "last_commit.txt"


--- Returns whether the library has finished initializing and is ready to use.
---@return boolean
function APILib.IsInitialized()
    return APILib.Initialized
end

--- Returns whether the library is currently in the process of initializing.
---@return boolean
function APILib.IsInitializing()
    return APILib.Initializing
end

--- Returns the full path to the cache folder.
---@return string
function APILib.GetCacheFolderPath()
    return APILib.CacheFolderPrefix .. APILib.Config.cache_folder_name
end

--- Returns the full path to the commit ID file inside the cache folder.
---@return string
function APILib.GetCommitIdFilePath()
    return APILib.AppendPath(APILib.GetCacheFolderPath(), COMMIT_ID_FILENAME)
end

--- Reads the cached commit ID from the file system.
---@return string|nil # The cached commit SHA, or nil if not found
function APILib.GetCachedCommitId()
    local path = APILib.GetCommitIdFilePath()

    if not File.Exists(path) then
        return nil
    end

    local f = File(path, false, false)
    if not f:IsGood() then
        f:Close()
        return nil
    end

    local data = f:Read()
    f:Close()

    if not data or data == "" then
        return nil
    end

    -- Trim whitespace/newlines
    return data:match("^%s*(.-)%s*$")
end

--- Writes a commit ID to the cache file.
---@param commit_id string The commit SHA to persist
function APILib.SaveCommitId(commit_id)
    local cache_path = APILib.GetCacheFolderPath()

    -- Ensure the cache directory exists
    if not File.Exists(cache_path) then
        File.CreateDirectory(cache_path)
    end

    local path = APILib.GetCommitIdFilePath()
    local f = File(path, true, false)
    f:Write(commit_id)
    f:Flush()
    f:Close()
end

--- Fetches the file tree of the repository from the GitHub API and returns
--- only the JSON-file blobs as a flat list of paths.
---@param callback fun(files: string[]|nil) Called with the list of file paths, or nil on failure
function APILib.FetchRepositoryTree(callback)
    HTTP.RequestAsync(
        APILib.Config.git_api_url,
        APILib.Config.endpoints.repo_files_tree,
        HTTPMethod.GET,
        nil,
        nil,
        false,
        {},
        function(status, data)
            if status ~= 200 then
                Console.Warn("Failed to fetch repository tree (HTTP " .. tostring(status) .. ")")
                callback(nil)
                return
            end

            local parsed = JSON.parse(data)
            if not parsed or not parsed.tree then
                Console.Warn("Invalid tree response from GitHub")
                callback(nil)
                return
            end

            local files = {}
            for _, entry in ipairs(parsed.tree) do
                if entry.type == "blob" and entry.path:match("%.json$") then
                    table.insert(files, entry.path)
                end
            end

            callback(files)
        end
    )
end

--- Downloads a single raw file from the repository.
---@param file_path string The relative file path inside the repo
---@param callback fun(success: boolean, data: string|nil) Called with the result
function APILib.DownloadFile(file_path, callback)
    HTTP.RequestAsync(
        APILib.Config.git_raw_url,
        APILib.Config.raw_file_endpoint .. file_path,
        HTTPMethod.GET,
        nil,
        nil,
        false,
        {},
        function(status, data)
            if status ~= 200 then
                Console.Warn("Failed to download file '" .. file_path .. "' (HTTP " .. tostring(status) .. ")")
                callback(false, nil)
                return
            end
            callback(true, data)
        end
    )
end

--- Saves raw file content to the local cache, preserving directory structure.
---@param file_path string The relative path of the file (e.g. "Classes/Actor.json")
---@param data string The raw file content to write
function APILib.SaveFileToCache(file_path, data)
    local full_path = APILib.AppendPath(APILib.GetCacheFolderPath(), file_path)

    -- Ensure parent directories exist by splitting the path
    local dir = full_path:match("^(.+)/[^/]+$")
    if dir and not File.Exists(dir) then
        File.CreateDirectory(dir)
    end

    local f = File(full_path, true, false)
    f:Write(data)
    f:Flush()
    f:Close()
end

--- Pulls or downloads every file of the repository, respecting repository structure.
--- Fetches the tree, downloads all JSON files, saves them to the cache,
--- and marks the library as ready once complete.
---@param commit_id string|nil The latest commit SHA to persist after downloading
function APILib.PullRepository(commit_id)
    APILib.FetchRepositoryTree(function(files)
        if not files or #files == 0 then
            Console.Warn("No files found in repository tree")
            -- Fallback to cached files if available
            if APILib.HasCachedFiles() then
                APILib.Ready()
            end
            return
        end

        local total = #files
        local completed = 0

        Console.Log("Downloading " .. tostring(total) .. " files from repository...")

        for _, file_path in ipairs(files) do
            APILib.DownloadFile(file_path, function(success, data)
                if success and data then
                    APILib.SaveFileToCache(file_path, data)
                end

                completed = completed + 1

                if completed >= total then
                    Console.Log("Download complete (" .. tostring(total) .. " files)")

                    -- Persist the commit ID so we can skip re-downloading next time
                    if commit_id then
                        APILib.SaveCommitId(commit_id)
                    end

                    APILib.Ready()
                end
            end)
        end
    end)
end

--- Checks for updates by comparing the latest remote commit SHA against the
--- locally cached one. Triggers a full repository pull when they differ.
--- This function is asynchronous.
function APILib.CheckUpdates()
    HTTP.RequestAsync(
        APILib.Config.git_api_url,
        APILib.Config.endpoints.repo_last_commit,
        HTTPMethod.GET,
        nil,
        nil,
        false,
        {},
        function(status, data)
            if status ~= 200 then
                Console.Warn("Failed to fetch latest commit (HTTP " .. tostring(status) .. ")")
                -- Fallback to cached files
                if APILib.HasCachedFiles() then
                    Console.Warn("Falling back to cached files")
                    APILib.Ready()
                end
                return
            end

            local parsed = JSON.parse(data)
            if not parsed or not parsed.sha then
                Console.Warn("Invalid commit response from GitHub")
                if APILib.HasCachedFiles() then
                    APILib.Ready()
                end
                return
            end

            local last_commit_id = parsed.sha
            local cache_commit_id = APILib.GetCachedCommitId()

            if last_commit_id ~= cache_commit_id then
                Console.Log("New version detected, pulling repository...")
                APILib.PullRepository(last_commit_id)
            else
                Console.Log("Cache is up to date")
                APILib.Ready()
            end
        end
    )
end

--- Checks whether any cached API files exist on disk.
---@return boolean # True if the cache folder exists and contains files
function APILib.HasCachedFiles()
    local cache_path = APILib.GetCacheFolderPath()

    if not File.Exists(cache_path) or not File.IsDirectory(cache_path) then
        return false
    end

    local files = File.GetFiles(cache_path, ".json")
    return files ~= nil and #files > 0
end

--- Appends a path to an existing path.
---@param base_path string 
---@param added_path string
---@return string
function APILib.AppendPath(base_path, added_path)
    if base_path == "" then return added_path end
    local ret = base_path .. "/" .. added_path
    return ret
end

--- Lists all API files currently downloaded in the cache folder.
---@param relative_path string|nil Relative path to list files
---@return string[]|nil # A list of relative file paths, or nil if not initialized
function APILib.ListAPIFiles(relative_path)
    if not APILib.IsInitialized() then
        Console.Warn("Tried to use APILib while it is not ready yet")
        return nil
    end

    local cache_path = APILib.GetCacheFolderPath()

    local target_path = cache_path
    if relative_path then
        target_path = APILib.AppendPath(target_path, relative_path)
    end

    if not File.Exists(target_path) then
        Console.Warn("ListAPIFiles: " .. target_path .. " doesn't exit")
        return {}
    end

    local files = File.GetFiles(target_path, ".json", -1)
    if not files then
        return {}
    end

    -- Convert full paths to relative paths within the cache folder
    local relative_files = {}
    local prefix = ((Client and ".transient/") or "") .. cache_path .. "/"
    local prefix_len = string.len(prefix)

    for _, file_path in ipairs(files) do
        --print(prefix, file_path)
        local relative = string.sub(file_path, prefix_len+1)
        table.insert(relative_files, relative)
    end

    return relative_files
end

--- Reads an API file synchronously and caches the parsed result in `APILib.Cache`.
---@param api_file_path string The relative path to the API file inside the cache
---@return table|nil # The parsed JSON data, or nil on failure
function APILib.ReadAPIFile(api_file_path)
    if not APILib.IsInitialized() then
        Console.Warn("Tried to use APILib while it is not ready yet")
        return nil
    end

    -- Return from memory cache if available
    if APILib.Cache[api_file_path] then
        return APILib.Cache[api_file_path]
    end

    local full_path = APILib.AppendPath(APILib.GetCacheFolderPath(), api_file_path)

    if not File.Exists(full_path) then
        Console.Warn("File not found: " .. api_file_path)
        return nil
    end

    local f = File(full_path, false, false)
    if not f:IsGood() then
        Console.Warn("Failed to open file: " .. api_file_path)
        f:Close()
        return nil
    end

    local api_file_data = f:ReadJSON()
    f:Close()

    if api_file_data then
        APILib.Cache[api_file_path] = api_file_data
    end

    return api_file_data
end

--- Reads an API file asynchronously and caches the parsed result in `APILib.Cache`.
---@param api_file_path string The relative path to the API file inside the cache
---@param callback fun(data: table|nil) Called with the parsed JSON data, or nil on failure
function APILib.ReadAPIFileAsync(api_file_path, callback)
    if not APILib.IsInitialized() then
        Console.Warn("Tried to use APILib while it is not ready yet")
        return
    end

    -- Return from memory cache if available
    if APILib.Cache[api_file_path] then
        callback(APILib.Cache[api_file_path])
        return
    end

    local full_path = APILib.AppendPath(APILib.GetCacheFolderPath(), api_file_path)

    if not File.Exists(full_path) then
        Console.Warn("File not found: " .. api_file_path)
        callback(nil)
        return
    end

    local f = File(full_path, false, false)
    if not f:IsGood() then
        Console.Warn("Failed to open file: " .. api_file_path)
        f:Close()
        callback(nil)
        return
    end

    f:ReadJSONAsync(function(data)
        f:Close()

        if data then
            APILib.Cache[api_file_path] = data
        end

        callback(data)
    end)
end

--- Clears the in-memory cache of parsed API files.
function APILib.ClearCache()
    APILib.Cache = {}
end

--- Called internally when initialization is complete. Fires the `APILibInitialized` event.
function APILib.Ready()
    APILib.Initialized = true
    APILib.Initializing = false
    Console.Log("Ready")
    Events.Call("APILibInitialized")
end

--- Initializes the API library. Begins checking for updates and downloading
--- the repository if needed. Safe to call multiple times — subsequent calls
--- are no-ops while initializing or after initialization.
---@return boolean|nil # True if initialization started, nil if already initialized/initializing
function APILib.Initialize()
    if APILib.IsInitialized() then return end
    if APILib.IsInitializing() then return end
    APILib.Initializing = true

    --Console.Log("Initializing...")
    APILib.CheckUpdates()

    return true
end
