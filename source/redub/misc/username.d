module redub.misc.username;

string getUserName()
{
    import std.process;
    foreach (envKey; ["USER", "USERNAME", "LOGNAME"]) {
        auto val = environment.get(envKey, null);
        if (val !is null && val.length > 0)
            return val;
    }

    return "";
}