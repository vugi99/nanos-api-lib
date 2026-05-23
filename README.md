# nanos-api-lib
#### Shared
#### LuaLS annotations included

## Example
```lua
Package.Subscribe("Load", function()
    APILib.Initialize()
end)

Events.Subscribe("APILibInitialized", function()
    local files = APILib.ListAPIFiles("Classes")

    for _, api_path in ipairs(files) do
        APILib.ReadAPIFileAsync(api_path, function(data)
            if not data then
                -- failed
                return
            end
            print("Classname:", data.name)
        end)
    end
end)
```


## Functions

```lua
APILib.IsInitialized()
APILib.IsInitializing()

APILib.AppendPath(base_path, added_path)

APILib.ListAPIFiles(relative_path)
APILib.ReadAPIFile(api_file_path)
APILib.ReadAPIFileAsync(api_file_path, callback)

APILib.Initialize()

APILib.ClearCache()

-- Internal functions
APILib.GetCommitIdFilePath()
APILib.GetCachedCommitId()
APILib.SaveCommitId(commit_id)
APILib.FetchRepositoryTree(callback)
APILib.DownloadFile(file_path, callback)
APILib.SaveFileToCache(file_path, data)
APILib.PullRepository(commit_id)
APILib.CheckUpdates()
APILib.HasCachedFiles()
APILib.Ready()
```

## Events
```lua
Events.Subscribe("APILibInitialized", function() end)
```