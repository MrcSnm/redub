module redub.misc.github_tag_check;

private enum RedubUserRepository = "MrcSnm/redub";
private enum GithubTagAPI = "https://api.github.com/repos/"~RedubUserRepository~"/tags";
private enum CreateIssueURL = "https://github.com/"~RedubUserRepository~"/issues/new/choose";


void showNewerVersionMessage()
{
    import redub.buildapi;
    import redub.logging;
    string ver = getLatestVersion();
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

string getLatestVersion()
{
    import std.net.curl;
    import hipjson;
    
    char[] tagsContent = get(GithubTagAPI);
    if(tagsContent.length == 0)
        return null;
    return parseJSON(cast(string)tagsContent).array[0]["name"].str;
}

string getRedubDownloadLink(string ver)
{
    return "https://github.com/"~RedubUserRepository~"/archive/refs/tags/"~ver~".zip";
}

string getCreateIssueURL(){return CreateIssueURL;}