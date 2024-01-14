module tree_generators.dub;
import buildapi;
import package_searching.dub;
import package_searching.entry;
import parsers.automatic;


/** 
 * This function receives an already parsed project path (BuildRequirements) and finishes parsing
 * its dependees. While it parses them, it also merge the root build flags with their dependees and
 * does that recursively.
 * 
 * If a project with the same name is found, it is merged with its existing counterpart
 * 
 * Params:
 *   req = Root project to build
 * Returns: A tree out of the BuildRequirements, with all its compilation flags merged. It is the final step
 * before being able to correctly use the compilation flags
 */
ProjectNode getProjectTree(BuildRequirements req, string compiler)
{
    ProjectNode[string] visited;
    ProjectNode[] collapsed;
    ProjectNode tree =  getProjectTreeImpl(req, compiler, visited, collapsed);
    tree.finish(collapsed);
    return tree;

}

/** 
 * 
 * Params:
 *   req = Requirement to generate node
 *   compiler = Compiler for parsing configs
 *   visited = Cache for unique matching
 *   collapsed = A collapsed representation of the tree. This is useful 
 *  for saving CPU and memory instead if needing to recursively iterate all the time.
 *  this was moved here because it already implements the `visited` pattern inside the tree,
 *  so, it is an assumption that can be made to make it slightly faster. Might be removed
 *  if it makes code comprehension significantly worse.
 * 
 * Returns: 
 */
private ProjectNode getProjectTreeImpl(
    BuildRequirements req, 
    string compiler, 
    ref ProjectNode[string] visited, 
    ref ProjectNode[] collapsed)
{
    ProjectNode root = new ProjectNode(req);
    if(req.cfg.targetType != TargetType.sourceLibrary) //Source libraries are not considered.
        collapsed~= root;
    foreach(dep; req.dependencies)
    {
        ProjectNode* visitedDep = dep.fullName in visited;
        ProjectNode depNode;
        //If visited already, just add the new dflags and versions
        if(visitedDep)
        {
            depNode = *visitedDep;
            ///When found 2 different packages requiring a different dependency subConfiguration
            if(visitedDep.requirements.configuration != dep.subConfiguration && !dep.subConfiguration.isDefault)
            {
                BuildRequirements depConfig = parseProjectWithParent(dep, req, compiler);
                if(visitedDep.requirements.targetConfiguration != depConfig.targetConfiguration)
                {
                    //Print merging different subConfigs?
                    visitedDep.requirements = mergeDifferentSubConfigurations(
                        visitedDep.requirements, 
                        depConfig
                    );
                }
            }
        }
        else
        {
            BuildRequirements buildReq = parseProjectWithParent(dep, req, compiler);
            depNode = getProjectTreeImpl(buildReq, compiler, visited, collapsed);
        }

        visited[dep.fullName] = depNode;
        root.addDependency(depNode);
    }
    return root;
}

/** 
 * Parses the project and merges its compilation flags with the parent requirement.
 * Params:
 *   projectPath = 
 *   parent = 
 *   subConfiguration = 
 * Returns: 
 */
private BuildRequirements parseProjectWithParent(Dependency dep, BuildRequirements parent, string compiler)
{
    BuildRequirements depReq = parseProject(dep.path, compiler, dep.subConfiguration, dep.subPackage, null);
    depReq.cfg.name = dep.fullName;
    return mergeProjectWithParent(depReq, parent);
}

private BuildRequirements mergeProjectWithParent(BuildRequirements base, BuildRequirements parent)
{
    base.cfg = base.cfg
                .mergeDFlags(parent.cfg)
                .mergeVersions(parent.cfg);
    return base;
}

private BuildRequirements mergeDifferentSubConfigurations(BuildRequirements existingReq, BuildRequirements newReq)
{
    throw new Error(
        "Error in project: '"~existingReq.name~"' Can't merge different subConfigurations at this " ~
        "moment: "~existingReq.targetConfiguration~ " vs " ~ newReq.targetConfiguration
    );
}

void printProjectTree(ProjectNode node, int depth = 0)
{
    import std.stdio;
    writeln("-".repeat(depth*2), node.name);
    foreach(dep; node.dependencies)
    {
        printProjectTree(dep, depth+1);
    }
}

string repeat(string v, int n)
{
    if(n <= 0) return null;
    char[] ret = new char[](v.length*n);
    foreach(i; 0..n)
        ret[i*v.length..(i+1)*v.length] = v[];
    return cast(string)ret;
}