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

    import harness.models : ProducingAgent;
    auto routed = store.loadNode(task.id);
    routed.mixrModel = "planned-model";
    store.saveNode(routed);
    ChatLine edit = ChatLine("assistant", "observed edit", 2);
    edit.eventKind = "edit";
    edit.producingAgent = ProducingAgent("new-tool", "actual-session", "actual-model", "s_0123456789abcd", "t_abcdef01234567");
    store.appendChat(task.id, edit);
    routed.mixrModel = "another-plan";
    store.saveNode(routed);
    auto persisted = ChatLine.fromJson(store.readChat(task.id)[$-1]);
    assert(persisted.eventKind == "edit");
    assert(persisted.producingAgent.model == "actual-model");
    assert(persisted.producingAgent.id == "actual-session");
    import harness.server : ServerContext, handleRequest;
    ServerContext ctx;
    ctx.store = store;
    auto response = handleRequest(ctx, "POST /api/edit-event HTTP/1.1\r\n\r\n" ~
        `{"nodeId":"` ~ task.id ~ `","role":"assistant","text":"HTTP edit","producing_agent":{"tool":"future-tool","id":"http-session","model":"unknown","git_ai_session_id":"s_0123456789abcd"}}`);
    assert(response.canFind("200 OK"));
    auto httpEvent = ChatLine.fromJson(store.readChat(task.id)[$-1]);
    assert(httpEvent.eventKind == "edit" && httpEvent.producingAgent.id == "http-session");
    store.appendChat(task.id, ChatLine("assistant", "unobserved", 1));
    assert(!ChatLine.fromJson(store.readChat(task.id)[$-1]).producingAgent.present);

    assert(defaultCloseout(NodeType.task, 1) == GitCloseout.coordinatorBatch);
    assert(canFind(closeoutSystemAddendum(GitCloseout.coordinatorBatch), "Do NOT push"));
}

unittest
{
    import harness.models : ProducingAgent;
    import std.json : parseJSON;
    import std.exception : assertThrown;
    auto old = ChatLine.fromJson(parseJSON(`{"role":"assistant","text":"old","tokens":1}`));
    assert(!old.producingAgent.present && old.eventKind == "message");
    auto producer = ProducingAgent("future-harness", "conversation-2", "unknown", "s_0123456789abcd", "t_abcdef01234567");
    auto roundtrip = ProducingAgent.fromJson(producer.toJson());
    assert(roundtrip.tool == "future-harness" && roundtrip.model == "unknown");
    assert(roundtrip.gitAiSessionId == "s_0123456789abcd");
    assertThrown(ProducingAgent.fromJson(parseJSON(`{"tool":"cursor","id":"s"}`)));
    auto bad = ProducingAgent("cursor","s","actual-model","invalid");
    assertThrown(bad.validate());
}
