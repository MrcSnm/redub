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
    ProjectNode tree =  getProjectTreeImpl(req, visited);
    tree.finish();
    return tree;

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
            ///When found 2 different packages requiring a different dependency subConfiguration
            if(visitedDep.requirements.targetConfiguration != dep.subConfiguration)
            {
                BuildRequirements depConfig = parseProjectWithParent(dep.path, req, dep.subConfiguration);
                if(visitedDep.requirements.targetConfiguration != depConfig.targetConfiguration)
                {
                    visitedDep.requirements = mergeDifferentSubConfigurations(
                        visitedDep.requirements, 
                        depConfig
                    );
                }
                else //If it is using the same subConfiguration, simply continue 
                    continue;
            }
            else //If it exists, simply merge with the parent project for adjusting its import flags
            {
                depNode = *visitedDep;
                depNode.requirements = mergedProjectWithParent(depNode.requirements, req);
            }
        }
        else
        {
            BuildRequirements buildReq = parseProjectWithParent(dep.path, req, dep.subConfiguration);
            depNode = getProjectTreeImpl(buildReq, visited);

        }
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
private BuildRequirements parseProjectWithParent(string projectPath, BuildRequirements parent, string subConfiguration)
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
    throw new Error("Error in project: '"~a.name~"' Can't merge different subConfigurations at this moment: "~a.targetConfiguration~ " vs " ~ b.targetConfiguration);
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