
APILib.Config = {
    git_api_url = "https://api.github.com",
    git_raw_url = "https://raw.githubusercontent.com",
    endpoints = {},

    repo_owner = "nanos-world",
    repo_name = "api",
    repo_branch = "main",

    cache_folder_name = "api-cache",
}

local Config = APILib.Config

Config.endpoints.repo_files_tree = string.format("/repos/%s/%s/git/trees/%s?recursive=1", Config.repo_owner, Config.repo_name, Config.repo_branch)
Config.endpoints.repo_last_commit = string.format("/repos/%s/%s/commits/%s", Config.repo_owner, Config.repo_name, Config.repo_branch)
Config.raw_file_endpoint = string.format("/%s/%s/refs/heads/%s/", Config.repo_owner, Config.repo_name, Config.repo_branch)