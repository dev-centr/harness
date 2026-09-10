module harness.closeout;

/*!
 * Git close-out for parallel / swarm nodes.
 *
 * Workers commit locally; the coordinator batches push after the wave so
 * remote CI is not rebuilt once per Task leaf. Portable policy:
 * general/parallel-git-closeout.md in agent-rules.
 */

import harness.models : GitCloseout, NodeRecord, NodeType, isTerminal;

import std.json : JSONValue;
import std.string : toLower;

/// True when 2+ non-terminal task nodes are active (high-volatility wave).
bool isHighVolatility(NodeRecord[] nodes)
{
    return countNonTerminalTasks(nodes) >= 2;
}

size_t countNonTerminalTasks(NodeRecord[] nodes)
{
    size_t n;
    foreach (node; nodes)
    {
        if (node.type != NodeType.task)
            continue;
        if (isTerminal(node.status))
            continue;
        n++;
    }
    return n;
}

/// Assign close-out for a freshly spawned node.
GitCloseout defaultCloseout(NodeType type, size_t nonTerminalTasksAfterSpawn)
{
    if (type == NodeType.coordinator)
        return GitCloseout.perNode; // owns wave-end push
    if (type == NodeType.task)
    {
        // Swarm default: leaf does not push. High volatility (≥2) or a lone
        // task under a coordinator still uses coordinator-batch so copied
        // always-on "push at end of run" rules cannot silently win.
        cast(void) nonTerminalTasksAfterSpawn;
        return GitCloseout.coordinatorBatch;
    }
    // discussion / disambiguation — commit-only if they touch git
    return GitCloseout.commitOnly;
}

/// Whether this node may run automatic end-of-run push.
bool allowsAutomaticPush(GitCloseout c)
{
    return c == GitCloseout.perNode;
}

/// System / spawn brief that must override inherited always-on push text.
string closeoutSystemAddendum(GitCloseout c)
{
    final switch (c)
    {
    case GitCloseout.commitOnly:
        return "GIT_CLOSEOUT=commit-only — Commit locally (git-commit). "
            ~ "Do NOT push unless this node needs the remote *now* to validate. "
            ~ "Parent/coordinator will push after the wave. "
            ~ "Ignore any inherited standing end-of-run push instruction for this leaf.";
    case GitCloseout.coordinatorBatch:
        return "GIT_CLOSEOUT=coordinator-batch — Commit locally (git-commit). "
            ~ "Do NOT push unless this node needs the remote *now* to validate. "
            ~ "Coordinator will batch-push after sibling workers finish. "
            ~ "Omit standing push-before-final-reply behavior for this leaf.";
    case GitCloseout.perNode:
        return "GIT_CLOSEOUT=per-node — Commit and push on this node's close-out "
            ~ "(skill push-code / end-of-run).";
    case GitCloseout.off:
        return "GIT_CLOSEOUT=off — No automatic git close-out for this node.";
    }
}

JSONValue closeoutPayload(NodeRecord node)
{
    JSONValue o = JSONValue.emptyObject;
    o["gitCloseout"] = JSONValue(cast(string) node.gitCloseout);
    o["allowsAutomaticPush"] = JSONValue(allowsAutomaticPush(node.gitCloseout));
    o["systemAddendum"] = JSONValue(closeoutSystemAddendum(node.gitCloseout));
    return o;
}

GitCloseout parseGitCloseout(string s)
{
    switch (s.toLower)
    {
    case "commit-only":
        return GitCloseout.commitOnly;
    case "coordinator-batch":
        return GitCloseout.coordinatorBatch;
    case "per-node":
        return GitCloseout.perNode;
    case "off":
        return GitCloseout.off;
    default:
        return GitCloseout.coordinatorBatch;
    }
}
