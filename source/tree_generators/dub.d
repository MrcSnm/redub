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
ProjectNode getProjectTree(BuildRequirements req)
{
    ProjectNode[string] visited;
    return getProjectTreeImpl(req, visited);

}
private ProjectNode getProjectTreeImpl(BuildRequirements req, ref ProjectNode[string] visited)
{
    ProjectNode root = new ProjectNode(req);
    foreach(dep; req.dependencies)
    {
        ProjectNode* visitedDep = dep.name in visited;
        ProjectNode depNode;
        if(visitedDep)
        {
            if(visitedDep.requirements.targetConfiguration != dep.subConfiguration)
            {
                visitedDep.requirements = mergeDifferentSubConfigurations(
                    visitedDep.requirements, 
                    parseProjectWithParent(dep.path, req, dep.subConfiguration)
                );
            }
            else
            {
                depNode = *visitedDep;
                depNode.requirements = mergedProjectWithParent(depNode.requirements, req);
            }
        }
        else
            depNode = getProjectTreeImpl(parseProjectWithParent(dep.path, req), visited);
        visited[dep.name] = depNode;
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
private BuildRequirements parseProjectWithParent(string projectPath, BuildRequirements parent, string subConfiguration = "")
{
    BuildRequirements depReq = parseProject(projectPath, subConfiguration);
    return mergedProjectWithParent(depReq, parent);
}

private BuildRequirements mergedProjectWithParent(BuildRequirements base, BuildRequirements parent)
{
    base.cfg = base.cfg
                .mergeDFlags(parent.cfg)
                .mergeVersions(parent.cfg);
    return base;
}

private BuildRequirements mergeDifferentSubConfigurations(BuildRequirements a, BuildRequirements b)
{
    throw new Error("Can't merge different subConfigurations at this moment: "~a.targetConfiguration~ " vs " ~ b.targetConfiguration);
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