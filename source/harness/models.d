module harness.models;

import std.json : JSONValue;

enum NodeType : string
{
    coordinator = "coordinator",
    discussion = "discussion",
    task = "task",
    disambiguation = "disambiguation",
}

enum NodeStatus : string
{
    idle = "idle",
    running = "running",
    blocked = "blocked",
    done = "done",
    failed = "failed",
    awaitingUser = "awaiting_user",
}

enum WaitMode : string
{
    warn = "warn",
    enforce = "enforce",
}

/// Who may push after parallel / swarm work (agent-rules parallel-git-closeout).
enum GitCloseout : string
{
    commitOnly = "commit-only",
    coordinatorBatch = "coordinator-batch",
    perNode = "per-node",
    off = "off",
}

struct WaitOn
{
    string node;
    WaitMode mode = WaitMode.warn;
}

/// Temporary local wire type: replace with git-ai-provenance once dependency wiring is approved.
/// The caller reports observed production, never the planned Mixr routing choice.
struct ProducingAgent
{
    string tool;
    string id;
    string model;
    string gitAiSessionId;
    string gitAiTraceId;

    bool present() const { return tool.length || id.length || model.length || gitAiSessionId.length || gitAiTraceId.length; }
    void validate() const
    {
        import std.exception : enforce;
        enforce(!present || (tool.length && id.length && model.length), "producer.identity_required");
        bool key(string value, string prefix) {
            if (value.length != 16 || value[0..2] != prefix) return false;
            foreach(c;value[2..$]) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
            return true;
        }
        enforce(!gitAiSessionId.length || key(gitAiSessionId,"s_"), "producer.session_key");
        enforce(!gitAiTraceId.length || (gitAiSessionId.length && key(gitAiTraceId,"t_")), "producer.trace_key");
    }
    JSONValue toJson() const
    {
        validate();
        JSONValue j = JSONValue.emptyObject;
        j["tool"] = JSONValue(tool); j["id"] = JSONValue(id); j["model"] = JSONValue(model);
        if (gitAiSessionId.length) j["git_ai_session_id"] = JSONValue(gitAiSessionId);
        if (gitAiTraceId.length) j["git_ai_trace_id"] = JSONValue(gitAiTraceId);
        return j;
    }
    static ProducingAgent fromJson(JSONValue j)
    {
        import std.json : JSONType;
        import std.exception : enforce;
        enforce(j.type == JSONType.object,"producer.object_required");
        ProducingAgent p;
        foreach(k;["tool","id","model"]) enforce((k in j.object) !is null && j[k].type == JSONType.string,"producer.identity_required");
        p.tool=j["tool"].str; p.id=j["id"].str; p.model=j["model"].str;
        if ("git_ai_session_id" in j) p.gitAiSessionId=j["git_ai_session_id"].str;
        if ("git_ai_trace_id" in j) p.gitAiTraceId=j["git_ai_trace_id"].str;
        p.validate();
        enforce(p.present,"producer.identity_required");
        return p;
    }
}

struct ChatLine
{
    string role;
    string text;
    int tokens;
    ProducingAgent producingAgent;
    string eventKind = "message";

    static ChatLine fromJson(JSONValue j)
    {
        ChatLine l;
        l.role=j["role"].str; l.text=j["text"].str; l.tokens=cast(int) j["tokens"].integer;
        if ("producing_agent" in j) l.producingAgent=ProducingAgent.fromJson(j["producing_agent"]);
        if ("event_kind" in j) l.eventKind=j["event_kind"].str;
        return l;
    }
}

struct NodeRecord
{
    string id;
    NodeType type;
    string address;
    NodeStatus status = NodeStatus.idle;
    string summary;
    string spawnedBy;
    string[] spawned;
    bool awaitingUser;
    bool hidden;
    string title;
    string topic;
    string mixrModel;
    string mixrReason;
    string lastEventAt;
    string lastTouchedAt;
    string createdAt;
    WaitOn[] waitOn;
    GitCloseout gitCloseout = GitCloseout.coordinatorBatch;

    JSONValue toJson() const
    {
        JSONValue o = JSONValue.emptyObject;
        o["id"] = JSONValue(id);
        o["type"] = JSONValue(cast(string) type);
        o["address"] = JSONValue(address);
        o["status"] = JSONValue(cast(string) status);
        o["summary"] = JSONValue(summary);
        if (spawnedBy.length)
            o["spawnedBy"] = JSONValue(spawnedBy);
        JSONValue sp = JSONValue.emptyArray;
        foreach (s; spawned)
            sp.array ~= JSONValue(s);
        o["spawned"] = sp;
        o["awaitingUser"] = JSONValue(awaitingUser);
        o["hidden"] = JSONValue(hidden);
        o["title"] = JSONValue(title);
        o["topic"] = JSONValue(topic);
        if (mixrModel.length)
            o["mixrModel"] = JSONValue(mixrModel);
        if (mixrReason.length)
            o["mixrReason"] = JSONValue(mixrReason);
        if (lastEventAt.length)
            o["lastEventAt"] = JSONValue(lastEventAt);
        if (lastTouchedAt.length)
            o["lastTouchedAt"] = JSONValue(lastTouchedAt);
        if (createdAt.length)
            o["createdAt"] = JSONValue(createdAt);
        if (waitOn.length)
        {
            JSONValue wa = JSONValue.emptyArray;
            foreach (w; waitOn)
            {
                JSONValue wo = JSONValue.emptyObject;
                wo["node"] = JSONValue(w.node);
                wo["mode"] = JSONValue(cast(string) w.mode);
                wa.array ~= wo;
            }
            o["waitOn"] = wa;
        }
        o["gitCloseout"] = JSONValue(cast(string) gitCloseout);
        return o;
    }

    static NodeRecord fromJson(JSONValue j)
    {
        NodeRecord n;
        n.id = j["id"].str;
        n.type = cast(NodeType) j["type"].str;
        n.address = j["address"].str;
        if ("status" in j)
            n.status = cast(NodeStatus) j["status"].str;
        if ("summary" in j)
            n.summary = j["summary"].str;
        if ("spawnedBy" in j)
            n.spawnedBy = j["spawnedBy"].str;
        if ("spawned" in j)
            foreach (s; j["spawned"].array)
                n.spawned ~= s.str;
        if ("awaitingUser" in j)
            n.awaitingUser = j["awaitingUser"].boolean;
        if ("hidden" in j)
            n.hidden = j["hidden"].boolean;
        if ("title" in j)
            n.title = j["title"].str;
        if ("topic" in j)
            n.topic = j["topic"].str;
        if ("mixrModel" in j)
            n.mixrModel = j["mixrModel"].str;
        if ("mixrReason" in j)
            n.mixrReason = j["mixrReason"].str;
        if ("lastEventAt" in j)
            n.lastEventAt = j["lastEventAt"].str;
        if ("lastTouchedAt" in j)
            n.lastTouchedAt = j["lastTouchedAt"].str;
        if ("createdAt" in j)
            n.createdAt = j["createdAt"].str;
        if ("waitOn" in j)
            foreach (w; j["waitOn"].array)
                n.waitOn ~= WaitOn(w["node"].str, cast(WaitMode) w["mode"].str);
        if ("gitCloseout" in j)
            n.gitCloseout = cast(GitCloseout) j["gitCloseout"].str;
        return n;
    }
}

struct GraphIndex
{
    int version_ = 1;
    string root = "coordinator";
    JSONValue nodes = JSONValue.emptyObject;

    JSONValue toJson() const
    {
        JSONValue o = JSONValue.emptyObject;
        o["version"] = JSONValue(version_);
        o["root"] = JSONValue(root);
        o["nodes"] = nodes;
        return o;
    }

    static GraphIndex fromJson(JSONValue j)
    {
        GraphIndex g;
        if ("version" in j)
            g.version_ = cast(int) j["version"].integer;
        if ("root" in j)
            g.root = j["root"].str;
        if ("nodes" in j)
            g.nodes = j["nodes"];
        return g;
    }
}

bool isTerminal(NodeStatus s)
{
    return s == NodeStatus.done || s == NodeStatus.failed;
}
