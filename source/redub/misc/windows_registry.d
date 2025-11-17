module redub.misc.windows_registry;

version(Windows):
public import std.windows.registry;
Key windowsGetKeyWithPath(string[] path...)
{
    Key hklm = Registry.localMachine;
    if(hklm is null) throw new Error("No HKEY_LOCAL_MACHINE in this system.");
    Key currKey = hklm;
    foreach(p; path)
    {
        try{
            currKey = currKey.getKey(p);
            if(currKey is null) return null;
        }
        catch(Exception e)
        {
            return null;
        }
    }
    return currKey;
}