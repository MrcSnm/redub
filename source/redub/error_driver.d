module redub.error_driver;

import d_depedencies;

string getUndefinedSymbolExplanationMSVC(ModuleParsing modules, string errorMessage)
{
    import std.algorithm.searching:countUntil,endsWith;
    import std.string:lineSplitter;

    string errMessage = "";

    foreach(l; lineSplitter(errorMessage))
    {

        ptrdiff_t lnkErrorPos = l.countUntil("error LNK2001:");
        if(lnkErrorPos != -1)
        {
            import core.demangle;
            string obj = l[0..l.countUntil(".obj")];
            lnkErrorPos+= "error LNK2001:".length;
            string identifiers = l[lnkErrorPos..$];
            //hip.view.load_scene.obj : error LNK2001: símbolo externo não resolvido D3hip3api12_ModuleInfoZ
            char[] symbol = demangle(identifiers);
            if(symbol.endsWith("__ModuleInfo"))
            {
                symbol = symbol[0..$-"__ModuleInfo".length];
                ModuleDef* moduleData = modules.fromModuleName(symbol);
                if(moduleData !is null)
                {
                    import std.conv:text;
                    import core.interpolation;
                    errMessage~= i"Module $(symbol) is imported by:\n".text;
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