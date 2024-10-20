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
 * It also clears the jsonCache so it is better suited for a library
 * 
 * Params:
 *   req = Root project to build
 * Returns: A tree out of the BuildRequirements, with all its compilation flags merged. It is the final step
 * before being able to correctly use the compilation flags
 */
ProjectNode getProjectTree(BuildRequirements req, CompilationInfo info)
{
    import redub.parsers.json;
    ProjectNode tree = new ProjectNode(req, false);
    string[string] subConfigs = req.getSubConfigurations;
    ProjectNode[string] visited;
    ProjectNode[] queue = [tree];
    getProjectTreeImpl(queue, info, subConfigs, visited);
    detectCycle(tree);
    tree.finish(info.targetOS, info.isa);
    clearJsonCache();
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
        ProjectNode* visitedDep = dep.name in visited;
        ProjectNode depNode;
        if(dep.subConfiguration.isDefault && dep.name in subConfigurations)
            dep.subConfiguration = BuildRequirements.Configuration(subConfigurations[dep.name], false);
        if(visitedDep)
        {
            depNode = *visitedDep;

            if(!dep.isOptional && depNode.isOptional)
            {
                depNode.makeRequired();
                infos("Optional Included: ", dep.name);
            }
            ///When found 2 different packages requiring a different dependency subConfiguration
            /// and the new is a default one.
            if(visitedDep.requirements.configuration != dep.subConfiguration && !dep.subConfiguration.isDefault)
            {
                BuildRequirements depConfig = parseDependency(dep, node.requirements, info);
                if(visitedDep.requirements.targetConfiguration != depConfig.targetConfiguration)
                {
                    //Print merging different subConfigs?
                    visitedDep.requirements = mergeDifferentSubConfigurations(
                        visitedDep.requirements, 
                        depConfig
                    );
                }
            }
            else if(visitedDep.requirements.version_ != dep.version_)
            {
                // error("Found different versions to parse: ", visitedDep.name, " ", visitedDep.requirements.version_, "  vs ", dep.version_);
                BuildRequirements depConfig = parseDependency(dep, node.requirements, info);
                visitedDep.requirements = depConfig;
            }

        }
        else
        {
            depNode = new ProjectNode(parseDependency(dep, node.requirements, info), dep.isOptional);
            subConfigurations = depNode.requirements.mergeSubConfigurations(subConfigurations);
            visited[dep.name] = depNode;
            queue~= depNode;
        }
        node.addDependency(depNode);
    }

    queue = queue[1..$];
    getProjectTreeImpl(queue, info, subConfigurations, visited);
}


private BuildRequirements parseDependency(Dependency dep, BuildRequirements parent, CompilationInfo info)
{
    import redub.package_searching.cache;
    vvlog("Dependency ", dep.name, " ", dep.version_, " ", dep.pkgInfo.bestVersion, " with parent ", parent.name);
    BuildRequirements depReq = parseProject(dep.pkgInfo.path, info, dep.subConfiguration, dep.subPackage, null);
    return depReq;
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

void printProjectTree(ProjectNode root)
{
    bool[ProjectNode] visit;
    void printProjectTreeImpl(ProjectNode node, int depth, ref bool[ProjectNode] visited)
    {
        info("\t".repeat(depth), node.name, " [", node.requirements.configuration.name, "] ", node.requirements.version_);
        if(!(node in visited))
        {
            foreach(dep; node.dependencies)
                printProjectTreeImpl(dep, depth+1, visited);
        }
        visited[node] = true;
    }

    printProjectTreeImpl(root, 0, visit);
}

string repeat(string v, int n)
{
    if(n <= 0) return null;
    char[] ret = new char[](v.length*n);
    foreach(i; 0..n)
        ret[i*v.length..(i+1)*v.length] = v[];
    return cast(string)ret;
}