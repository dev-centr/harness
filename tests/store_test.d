module harness_store_test;

import harness.closeout : allowsAutomaticPush, closeoutSystemAddendum, countNonTerminalTasks,
    defaultCloseout, isHighVolatility;
import harness.models : ChatLine, GitCloseout, NodeRecord, NodeStatus, NodeType;
import harness.store : ChatStore;

import std.algorithm : canFind;

unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.random : uniform;
    import std.conv : to;

    auto tmp = buildPath(tempDir, "harness-" ~ uniform(100_000, 999_999).to!string);
    mkdirRecurse(tmp);
    scope (exit)
        if (exists(tmp))
            rmdirRecurse(tmp);

    ChatStore store = { root: tmp };
    auto coord = store.initSession("Test");
    assert(coord.id == "coordinator");
    assert(coord.gitCloseout == GitCloseout.perNode);
    assert(allowsAutomaticPush(coord.gitCloseout));

    auto task = store.spawn("coordinator", NodeType.task, "docs-sync", "", "multi-repo");
    assert(task.spawnedBy == "coordinator");
    assert(task.gitCloseout == GitCloseout.coordinatorBatch);
    assert(!allowsAutomaticPush(task.gitCloseout));
    assert(canFind(store.readChat(task.id)[0]["text"].str, "GIT_CLOSEOUT=coordinator-batch"));
    auto parent = store.loadNode("coordinator");
    assert(canFind(parent.spawned, task.id));

    auto task2 = store.spawn("coordinator", NodeType.task, "ci-fix", "", "parallel");
    assert(isHighVolatility(store.loadAllNodes()));
    assert(countNonTerminalTasks(store.loadAllNodes()) >= 2);
    assert(task2.gitCloseout == GitCloseout.coordinatorBatch);

    auto line = store.appendChat(task.id, ChatLine("user", "hello", 1));
    assert(line == 2); // system close-out brief is line 1
    assert(store.readChat(task.id).length == 2);

    NodeRecord spawned;
    assert(store.proposeSpawnFromMessage("coordinator", "Also, we should fix the CLA thing", spawned));
    assert(spawned.type == NodeType.discussion);
    assert(spawned.gitCloseout == GitCloseout.commitOnly);

    assert(store.proposeSpawnFromMessage("coordinator",
        "Continue the merge or we could also refactor the timeline engine", spawned));
    assert(spawned.type == NodeType.disambiguation);

    assert(defaultCloseout(NodeType.task, 1) == GitCloseout.coordinatorBatch);
    assert(canFind(closeoutSystemAddendum(GitCloseout.coordinatorBatch), "Do NOT push"));
}
