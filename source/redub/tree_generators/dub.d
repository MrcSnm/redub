module redub.tree_generators.dub;
import redub.logging;
import redub.buildapi;
import redub.package_searching.dub;
import redub.package_searching.entry;
import redub.parsers.automatic;


struct CompilationInfo
{
    string compiler;
    string arch;
    OS targetOS;
    ///Target Instruction Set Architecture
    ISA isa;
}


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
ProjectNode getProjectTree(BuildRequirements req, CompilationInfo info)
{
    ProjectNode tree = new ProjectNode(req);
    string[string] subConfigs = req.getSubConfigurations;
    ProjectNode[string] visited;
    ProjectNode[] queue = [tree];
    getProjectTreeImpl(queue, info, subConfigs, visited);
    detectCycle(tree);
    warn(info.isa);
    tree.finish(info.targetOS, info.isa);
    return tree;
}   


void detectCycle(ProjectNode t)
{
    bool[ProjectNode] visited;
    bool[ProjectNode] inStack;

    void impl(ProjectNode node)
    {
        if(node in inStack) throw new Exception("Found a cycle at "~node.name);
        inStack[node] = true;
        visited[node] = true;
        
        foreach(n; node.dependencies)
        {
            if(!(node in visited)) impl(n);
        }
        inStack.remove(node);
    }
    impl(t);
}

/** 
 * 
 * Params:
 *   queue = A queue for breadth first traversal
 *   info = Compiler information for parsing nodes
 *   subConfigurations = A map of subConfiguration[dependencyName] for mapping sub configuration matching
 *   visited = Cache for unique matching
 *  for saving CPU and memory instead if needing to recursively iterate all the time.
 *  this was moved here because it already implements the `visited` pattern inside the tree,
 *  so, it is an assumption that can be made to make it slightly faster. Might be removed
 *  if it makes code comprehension significantly worse.
 * 
 * Returns: 
 */
private void getProjectTreeImpl(
    ref ProjectNode[] queue,
    CompilationInfo info,
    string[string] subConfigurations,
    ref ProjectNode[string] visited, 
)
{
    if(queue.length == 0) return;
    ProjectNode node = queue[0];
    foreach(dep; node.requirements.dependencies)
    {
        if(dep.isSubConfigurationOnly)
            continue;            
        ProjectNode* visitedDep = dep.fullName in visited;
        ProjectNode depNode;
        if(dep.subConfiguration.isDefault && dep.name in subConfigurations)
            dep.subConfiguration = BuildRequirements.Configuration(subConfigurations[dep.name], false);
        if(visitedDep)
        {
            depNode = *visitedDep;
            ///When found 2 different packages requiring a different dependency subConfiguration
            /// and the new is a default one.
            if(visitedDep.requirements.configuration != dep.subConfiguration && !dep.subConfiguration.isDefault)
            {
                BuildRequirements depConfig = parseProjectWithParent(dep, node.requirements, info);
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
            depNode = new ProjectNode(parseProjectWithParent(dep, node.requirements, info));
            subConfigurations = depNode.requirements.mergeSubConfigurations(subConfigurations);
            visited[dep.fullName] = depNode;
            queue~= depNode;
        }
        node.addDependency(depNode);
    }
    queue = queue[1..$];
    getProjectTreeImpl(queue, info, subConfigurations, visited);
}

/** 
 * Parses the project and merges its compilation flags with the parent requirement.
 * Params:
 *   projectPath = 
 *   parent = 
 *   subConfiguration = 
 * Returns: 
 */
private BuildRequirements parseProjectWithParent(Dependency dep, BuildRequirements parent, CompilationInfo info)
{
    vvlog("Parsing dependency ", dep.name, " with parent ", parent.name);
    BuildRequirements depReq = parseProject(dep.path, info.compiler, info.arch, dep.subConfiguration, dep.subPackage, null, info.targetOS, info.isa);
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
    if(existingReq.configuration.isDefault)
        return newReq;
    throw new Exception(
        "Error in project: '"~existingReq.name~"' Can't merge different subConfigurations at this " ~
        "moment: "~existingReq.targetConfiguration~ " vs " ~ newReq.targetConfiguration
    );
}

void printProjectTree(ProjectNode node, int depth = 0)
{
    info("-".repeat(depth*2), node.name);
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