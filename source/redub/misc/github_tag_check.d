module redub.misc.github_tag_check;
import hipjson;

private enum RedubUserRepository = "MrcSnm/redub";
private enum CreateIssueURL = "https://github.com/"~RedubUserRepository~"/issues/new/choose";


void showNewerVersionMessage()
{
    import redub.buildapi;
    import redub.logging;
    string ver = getLatestRedubVersion();
    if(ver)
    {
        if(ver != RedubVersionOnly)
        {
            warnTitle(
                "Redub "~ ver~ " available. \n\t",
                "Maybe try updating it with 'redub update 'or running dub fetch redub@"~ver[1..$]~" if you think this compilation error is a redub bug."
            );
            return;
        }
    }
    warn(
        "If you think this is a bug on redub, do test with dub, if it works, do file an issue at ",
        CreateIssueURL
    );
}

/**
 * Params:
 *   repo = The repository which you want to fetch from. Both user/repo
 * Returns:
 */
string getLatestGitRepositoryTag(string repo)
{
    JSONValue v = getGithubRepoAPI(repo);
    if(v.isNull)
        return null;
    return v.array[0]["name"].str;
}

JSONValue getGithubRepoAPI(string repo)
{
    import d_downloader;
    import std.conv:text;
    string api = i"https://api.github.com/repos/$(repo)/tags".text;
    char[] tagsContent = cast(char[])downloadToBuffer(api);
    if(tagsContent.length == 0)
        return JSONValue(null);
    return parseJSON(tagsContent);
}

string getLatestRedubVersion()
{
    static string newestVer;
    if(!newestVer)
        newestVer = getLatestGitRepositoryTag(RedubUserRepository);
    return newestVer;
}

string getRedubDownloadLink(string ver)
{
    return "https://github.com/"~RedubUserRepository~"/archive/refs/tags/"~ver~".zip";
}

string getCreateIssueURL(){return CreateIssueURL;}