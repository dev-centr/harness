module harness.planstack;

import core.time : msecs;
import std.json : JSONValue, parseJSON;
import std.net.curl : HTTP, get;

/// Default plan-stack daemon (after wait-hub 17357).
enum defaultPlanStackUrl = "http://127.0.0.1:17358";

/**
 * Proxy GET /overview from plan-stackd.
 * Returns { ok, offline?, overview?, error?, planStackUrl }.
 */
JSONValue fetchOverview(string baseUrl = defaultPlanStackUrl)
{
    JSONValue o = JSONValue.emptyObject;
    o["planStackUrl"] = JSONValue(baseUrl);
    string url = baseUrl ~ "/overview";
    try
    {
        auto http = HTTP();
        http.connectTimeout = 500.msecs;
        http.operationTimeout = 1500.msecs;
        auto body = cast(string) get(url, http);
        auto overview = parseJSON(body);
        o["ok"] = JSONValue(true);
        o["offline"] = JSONValue(false);
        o["overview"] = overview;
        return o;
    }
    catch (Exception ex)
    {
        o["ok"] = JSONValue(false);
        o["offline"] = JSONValue(true);
        o["error"] = JSONValue(ex.msg);
        o["overview"] = JSONValue(["windows": JSONValue.emptyArray]);
        return o;
    }
}
