module redub.misc.github_tag_check;

private enum RedubUserRepository = "MrcSnm/redub";
private enum GithubTagAPI = "https://api.github.com/repos/"~RedubUserRepository~"/tags";
private enum CreateIssueURL = "https://github.com/"~RedubUserRepository~"/issues/new/choose";


void showNewerVersionMessage()
{
    string ver = getLatestVersion();
    if(ver)
    {
        import redub.logging;
        warnTitle(
            "Redub "~ ver~ " available. \n\t",
            "Maybe try updating or running dub fetch redub@"~ver[1..$]~" if you think this compilation error is a redub bug."
        );
    }
}

private string getLatestVersion()
{
    import std.net.curl;
    import hipjson;
    
    char[] tagsContent = get(GithubTagAPI);
    if(tagsContent.length == 0)
        return null;
    return parseJSON(cast(string)tagsContent).array[0]["name"].str;
}

string getCreateIssueURL(){return CreateIssueURL;}