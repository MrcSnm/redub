module redub.misc.username;

string getUserName()
{
    import redub.parsers.environment;
    foreach (envKey; ["USER", "USERNAME", "LOGNAME"]) {
        auto val = getEnvVariable(envKey);
        if (val !is null && val.length > 0)
            return val;
    }

    return "";
}