module tree_generators.dub;
import buildapi;
import package_searching.dub;
import package_searching.entry;
import parsers.automatic;

ProjectNode getProjectTree(BuildRequirements req)
{
    ProjectNode root = new ProjectNode(req);

    foreach(dep; req.dependencies)
    {
        BuildRequirements depReq = parseProject(dep.path);
        depReq.cfg = depReq.cfg
                     .mergeDFlags(req.cfg)
                     .mergeVersions(req.cfg);
        root.addDependency(getProjectTree(depReq));
    }
    return root;
}

void printProjectTree(ProjectNode node, int depth = 0)
{
    import std.stdio;
    writeln("\t".repeat(depth), node.name);
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