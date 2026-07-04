module redub.error_driver;
import d_depedencies;

//hip.view.load_scene.obj : error LNK2001: símbolo externo não resolvido D3hip3api12_ModuleInfoZ
string getUndefinedSymbolExplanationMSVC(ModuleParsing modules, string errorMessage)
{
    import std.algorithm.searching:countUntil,endsWith;
    import std.string:lineSplitter,lastIndexOf;

    string errMessage = "";

    foreach(l; lineSplitter(errorMessage))
    {

        if(l.countUntil("error LNK2001:") != -1)
        {
            import core.demangle;
            string obj = l[0..l.countUntil(".obj")];
            string identifiers = l[lastIndexOf(l, " ")+1..$];
            char[] symbol = demangle(identifiers);
            if(symbol.endsWith(".__ModuleInfo"))
            {
                symbol = symbol[0..$-".__ModuleInfo".length];
                ModuleDef* moduleData = modules.fromModuleName(symbol);
                if(moduleData !is null)
                {
                    import std.conv:text;
                    import core.interpolation;
                    errMessage~= i"Module '$(symbol)' is imported by:\n".text;
                    foreach(ModuleDef parent; moduleData.importedBy)
                    {
                        errMessage~= i"\t$(parent.modName) ($(parent.modPath))".text;
                    }
                }
                
            }
            
        }
    }
    return errMessage;
}