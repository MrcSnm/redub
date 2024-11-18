module dub_sdl_to_json;
public import hipjson;
import sdlite;

SDLNode[] parseSDL(string fileName)
{
	import std.file;
	return parseSDL(fileName, readText(fileName));
}


SDLNode[] parseSDL(string fileName, string sdlData)
{
	SDLNode[] result;
	parseSDLDocument!((n){result~= n;})(sdlData, fileName);
	return result;
}

JSONValue toJSONValue(SDLValue v)
{
	switch(v.kind)
	{
		case SDLValue.Kind.text:
			return JSONValue(v.textValue);
		case SDLValue.Kind.int_:
			return JSONValue(v.int_Value);
		case SDLValue.Kind.long_:
			return JSONValue(v.long_Value);
		case SDLValue.Kind.float_:
			return JSONValue(v.float_Value);
		case SDLValue.Kind.double_:
			return JSONValue(v.double_Value);
		case SDLValue.Kind.bool_:
			return JSONValue(v.bool_Value);
		default:break;
	}
	return JSONValue(null);
}

JSONValue toJSONValue(SDLValue[] values, bool forceArray = false)
{
	if(values.length == 1 && !forceArray)
		return toJSONValue(values[0]);
	JSONValue ret = JSONValue.emptyArray;
	foreach(v; values)
	{
		ret.jsonArray~= toJSONValue(v);
	}
	return ret;
}

string getName(SDLNode node)
{
	import std.exception;
	if(node.attributes.length == 0) return node.name;
	SDLValue plat = node.getAttribute("platform");
	if(plat.isNull_) return node.name;
	enforce(plat.isText, "platform attribute from node "~node.name~" must be a string.");
	return node.name~"-"~plat.textValue;
}

JSONValue sdlToJSON(SDLNode[] sdl)
{
	import std.exception;
	import std.algorithm.searching:countUntil;
	JSONValue ret = JSONValue.emptyObject;
	JSONValue dependencies = JSONValue.emptyObject;
	JSONValue subConfigurations = JSONValue.emptyObject;
	JSONValue configurations = JSONValue.emptyArray;
	JSONValue subPackages = JSONValue.emptyArray;
	foreach(SDLNode v; sdl)
	{
		switch(v.name)
		{
			case "dependency":
				enforce(v.values.length == 1, "Can only have a single value for dependency");
				enforce(v.values[0].isText, "Value for dependency must be a text.");
				string depName = v.values[0].textValue;
				string depVer;

				enforce(v.attributes.length > 0, "A dependency must have at least one attribute. (Parsing "~depName~")");
				if(v.attributes.length == 1)
				{
					enforce(v.attributes[0].name == "version", "Whenever dependency has a single attribute, it must be a version. (Parsing "~depName~")");
					SDLValue versionValue = v.getAttribute("version");
					enforce(versionValue.isText, "version must be a string.");
					depVer = versionValue.textValue;
					dependencies[depName]  = JSONValue(depVer);
				}
				else
				{
					JSONValue dep = JSONValue.emptyObject;
					foreach(SDLAttribute attr; v.attributes)
						dep[attr.name] = toJSONValue(attr.value);
					dependencies[depName] = dep;
				}
				break;
			case "configuration":
				import std.stdio;
				enforce(v.values.length == 1, "A configuration can only have a single value, which is the configuration name");
				enforce(v.values[0].isText, "The configuration value must be a string.");
				configurations.jsonArray~= sdlToJSON(v.children);
				break;
			case "subConfiguration":
				enforce(v.values.length == 2, "subConfiguration must contain a two values.");
				enforce(v.values[0].isText, "subConfiguration value 1 must be a text.");
				enforce(v.values[1].isText, "subConfiguration value 2 must be a text.");
				enforce(!(v.values[0].textValue in subConfigurations), "Subconfiguration "~v.values[0].textValue~" is already present in subConfigurations.");
				subConfigurations[v.values[0].textValue] = JSONValue(v.values[1].textValue);

				break;
			case "subPackage":
				enforce(v.values.length > 0, "subPackage must have at least one value.");
				if(v.values.length == 1)
				{
					enforce(v.values[0].isText, "Whenever a subPackage has a single value, it must be a text.");
					subPackages.jsonArray~= JSONValue(v.values[0].textValue);
				}
				break;
			default:
				bool shouldForceArray = countUntil([
					"dflags",
					"lflags",
					"libs",
					"versions",
					"platforms",

					"preGenerateCommands",
					"postGenerateCommands",
					"preBuildsCommands",
					"postBuildCommands",

					"sourceFiles",
					"excludedSourceFiles",
					"copyFiles",

					"sourcePaths",
					"importPaths",
					"stringImportPaths",

					"buildOptions",
					"buildRequirements",
					], v.name) != -1;
				string name = getName(v);
				JSONValue* json = name in ret;
				if(json)
				{
					enforce(json.type == JSONType.array, "Can only show twice on SDL's '"~name~"' if it is an array type.");
					foreach(jsonValue; toJSONValue(v.values, true).array)
						json.jsonArray~= jsonValue;
				}
				else
					ret[getName(v)] = toJSONValue(v.values, shouldForceArray);
				break;
		}
		// ret[v.name] = v.values[0]
	}
	if(configurations.array.length != 0)
		ret["configurations"] = configurations;
	if(subConfigurations != JSONValue.emptyObject)
		ret["subConfigurations"] = subConfigurations;
	if(dependencies != JSONValue.emptyObject)
		ret["dependencies"] = dependencies;
	if(subPackages.array.length != 0)
		ret["subPackages"] = subPackages;
	return ret;
}