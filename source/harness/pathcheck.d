module harness.pathcheck;

import std.algorithm : startsWith;
import std.array : join, split;
import std.format : format;
import std.json : JSONValue;
import std.process : environment;
import std.string : strip, toLower;

enum WINDOWS_PATH_TRUNCATION_DOCS_URL = "https://docs.devcentr.org/general-knowledge/reference/windows-path-truncation/";
enum size_t WINDOWS_EXPLORER_PATH_LIMIT = 2047;
enum size_t MAX_DROPPED_SAMPLE = 6;

struct PathHealthReport
{
    bool checked;
    string platform = "non-windows";
    string status = "not_applicable"; // "ok" | "fixed" | "error" | "not_applicable"
    bool truncated;
    bool registryOverLimit;
    size_t processLengthBefore;
    size_t processLengthAfter;
    size_t machineLength;
    size_t userLength;
    size_t droppedCount;
    string[] droppedSample;
    size_t duplicateCount;
    bool repaired;
    string summary;
    string errorMessage;
    string detailsUrl = WINDOWS_PATH_TRUNCATION_DOCS_URL;

    JSONValue toJson() const
    {
        JSONValue o = JSONValue.emptyObject;
        o["checked"] = JSONValue(checked);
        o["platform"] = JSONValue(platform);
        o["status"] = JSONValue(status);
        o["truncated"] = JSONValue(truncated);
        o["registryOverLimit"] = JSONValue(registryOverLimit);
        o["processLengthBefore"] = JSONValue(cast(long) processLengthBefore);
        o["processLengthAfter"] = JSONValue(cast(long) processLengthAfter);
        o["machineLength"] = JSONValue(cast(long) machineLength);
        o["userLength"] = JSONValue(cast(long) userLength);
        o["droppedCount"] = JSONValue(cast(long) droppedCount);
        JSONValue sample = JSONValue.emptyArray;
        foreach (entry; droppedSample)
            sample.array ~= JSONValue(entry);
        o["droppedSample"] = sample;
        o["duplicateCount"] = JSONValue(cast(long) duplicateCount);
        o["repaired"] = JSONValue(repaired);
        o["summary"] = JSONValue(summary);
        o["errorMessage"] = JSONValue(errorMessage);
        o["detailsUrl"] = JSONValue(detailsUrl);
        return o;
    }
}

struct RegistryPathSnapshot
{
    string processPath;
    string machinePath;
    string userPath;
}

/// Normalize a Windows PATH entry for case-insensitive deduplication and comparison.
string normalizePathEntry(string raw) pure
{
    string s = raw.strip();
    if (s.length >= 2 && s[0] == '"' && s[$ - 1] == '"')
        s = s[1 .. $ - 1].strip();
    while (s.length > 1 && (s[$ - 1] == '\\' || s[$ - 1] == '/'))
    {
        // Preserve drive roots such as "C:\".
        if (s.length == 3 && s[1] == ':')
            break;
        s = s[0 .. $ - 1];
    }
    return s.toLower();
}

private string[] splitPathEntries(string pathValue) pure
{
    string[] result;
    foreach (part; pathValue.split(';'))
    {
        auto trimmed = part.strip();
        if (trimmed.length)
            result ~= trimmed;
    }
    return result;
}

/// Pure analyzer used on all platforms (and unit tests).
/// Detects Registry entries missing from processPath and builds a deduplicated repaired PATH.
PathHealthReport analyzeAndBuildRepairedPath(
    string processPath,
    string machinePath,
    string userPath,
    out string repairedPath) pure
{
    PathHealthReport report;
    report.checked = true;
    report.platform = "windows";
    report.detailsUrl = WINDOWS_PATH_TRUNCATION_DOCS_URL;
    report.processLengthBefore = processPath.length;
    report.machineLength = machinePath.length;
    report.userLength = userPath.length;

    const size_t combinedLen = machinePath.length + userPath.length
        + ((machinePath.length && userPath.length) ? 1 : 0);
    report.registryOverLimit = (userPath.length > WINDOWS_EXPLORER_PATH_LIMIT)
        || (combinedLen > WINDOWS_EXPLORER_PATH_LIMIT);

    auto procEntries = splitPathEntries(processPath);
    auto machineEntries = splitPathEntries(machinePath);
    auto userEntries = splitPathEntries(userPath);

    bool[string] procSet;
    foreach (e; procEntries)
    {
        auto norm = normalizePathEntry(e);
        if (norm.length)
            procSet[norm] = true;
    }

    bool[string] regSeen;
    string[] regDeduped;
    string[] droppedNorms;

    void collectRegistry(string[] entries)
    {
        foreach (e; entries)
        {
            auto norm = normalizePathEntry(e);
            if (!norm.length)
                continue;
            if (norm in regSeen)
            {
                report.duplicateCount++;
                continue;
            }
            regSeen[norm] = true;
            regDeduped ~= e;
            if (!(norm in procSet))
            {
                report.droppedCount++;
                droppedNorms ~= norm;
                if (report.droppedSample.length < MAX_DROPPED_SAMPLE)
                    report.droppedSample ~= e;
            }
        }
    }

    collectRegistry(machineEntries);
    collectRegistry(userEntries);

    // Keep legitimate process-only entries (e.g., activated venvs) at the front,
    // while discarding broken mid-path truncation fragments created by Explorer.
    string[] processOnly;
    bool[string] procOnlySeen;
    foreach (e; procEntries)
    {
        auto norm = normalizePathEntry(e);
        if (!norm.length || (norm in regSeen) || (norm in procOnlySeen))
            continue;
        bool looksTruncatedFragment = false;
        foreach (dropped; droppedNorms)
        {
            if (dropped.length > norm.length && dropped.startsWith(norm))
            {
                looksTruncatedFragment = true;
                break;
            }
        }
        if (looksTruncatedFragment)
            continue;
        procOnlySeen[norm] = true;
        processOnly ~= e;
    }

    string[] merged = processOnly ~ regDeduped;
    repairedPath = merged.join(";");
    report.truncated = report.droppedCount > 0;

    if (!report.truncated)
    {
        report.status = "ok";
        report.repaired = false;
        report.processLengthAfter = processPath.length;
        if (report.registryOverLimit)
        {
            report.summary = format(
                "Windows PATH has all Registry entries (%s chars), but Registry PATH (%s chars) exceeds 2,047 chars and is at risk of Explorer truncation.",
                processPath.length, combinedLen);
        }
        else
        {
            report.summary = "Windows PATH matches Registry Machine + User PATH.";
        }
    }
    else
    {
        report.processLengthAfter = repairedPath.length;
    }

    return report;
}

/// Testable core: reads snapshot via reader delegate and repairs via setter delegate.
PathHealthReport ensureWindowsPathHealthWithHooks(
    RegistryPathSnapshot delegate() reader,
    void delegate(string newPath) setter)
{
    PathHealthReport report;
    report.checked = true;
    report.platform = "windows";
    report.detailsUrl = WINDOWS_PATH_TRUNCATION_DOCS_URL;

    RegistryPathSnapshot snap;
    try
    {
        snap = reader();
    }
    catch (Exception e)
    {
        report.status = "error";
        report.repaired = false;
        report.errorMessage = e.msg;
        report.summary = format(
            "Windows PATH truncation check failed while reading Registry (%s). Tools in User PATH may be unavailable.",
            e.msg);
        return report;
    }

    string repairedPath;
    report = analyzeAndBuildRepairedPath(snap.processPath, snap.machinePath, snap.userPath, repairedPath);
    if (!report.truncated)
        return report;

    const size_t regTotal = snap.machinePath.length + snap.userPath.length
        + ((snap.machinePath.length && snap.userPath.length) ? 1 : 0);

    try
    {
        setter(repairedPath);
        report.status = "fixed";
        report.repaired = true;
        report.processLengthAfter = repairedPath.length;
        report.summary = format(
            "Windows dropped %s PATH %s (process PATH was %s chars vs. %s chars in Registry Machine + User). Harness automatically restored the full PATH (%s chars) for this process and child tools.",
            report.droppedCount,
            report.droppedCount == 1 ? "entry" : "entries",
            report.processLengthBefore,
            regTotal,
            report.processLengthAfter);
    }
    catch (Exception e)
    {
        report.status = "error";
        report.repaired = false;
        report.processLengthAfter = report.processLengthBefore;
        report.errorMessage = e.msg;
        report.summary = format(
            "Windows truncated PATH (%s %s dropped; %s vs. %s chars) and Harness could not repair it: %s",
            report.droppedCount,
            report.droppedCount == 1 ? "entry" : "entries",
            report.processLengthBefore,
            regTotal,
            e.msg);
    }

    return report;
}

/// Check Windows PATH truncation on process launch and automatically repair this process's PATH.
PathHealthReport ensureWindowsPathHealth()
{
    version (Windows)
    {
        return ensureWindowsPathHealthWithHooks(
            () => readWindowsRegistryPaths(),
            (string newPath) => applyWindowsProcessPath(newPath)
        );
    }
    else
    {
        PathHealthReport report;
        report.checked = false;
        report.platform = "non-windows";
        report.status = "not_applicable";
        report.summary = "Windows PATH truncation check is not applicable on this OS.";
        report.detailsUrl = WINDOWS_PATH_TRUNCATION_DOCS_URL;
        return report;
    }
}

version (Windows)
{
    import core.sys.windows.winbase : ExpandEnvironmentStringsW, GetEnvironmentVariableW,
        GetLastError, SetEnvironmentVariableW;
    import core.sys.windows.windef : DWORD, HKEY, LPBYTE;
    import core.sys.windows.winerror : ERROR_FILE_NOT_FOUND, ERROR_MORE_DATA, ERROR_SUCCESS;
    import core.sys.windows.winnt : KEY_READ, WCHAR;
    import core.sys.windows.winreg : HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, REG_EXPAND_SZ, REG_SZ,
        RegCloseKey, RegOpenKeyExW, RegQueryValueExW;
    import std.utf : toUTF16z, toUTF8;

    private string expandWindowsEnvVars(wstring raw)
    {
        if (raw.length == 0)
            return "";
        auto z = toUTF16z(raw);
        auto needed = ExpandEnvironmentStringsW(z, null, 0);
        if (needed == 0)
            return toUTF8(raw);
        auto buf = new WCHAR[](needed);
        auto written = ExpandEnvironmentStringsW(z, buf.ptr, needed);
        if (written == 0 || written > needed)
            return toUTF8(raw);
        // written includes trailing NUL when successful.
        size_t len = written > 0 ? written - 1 : 0;
        while (len > 0 && buf[len - 1] == 0)
            len--;
        return toUTF8(buf[0 .. len]);
    }

    private string readRegistryPathValue(HKEY root, string subkey, string valueName, bool optionalMissing)
    {
        HKEY hKey = null;
        auto openRes = RegOpenKeyExW(root, toUTF16z(subkey), 0, KEY_READ, &hKey);
        if (openRes != ERROR_SUCCESS)
        {
            if (optionalMissing && openRes == ERROR_FILE_NOT_FOUND)
                return "";
            throw new Exception(format("RegOpenKeyExW(%s) failed with code %s", subkey, openRes));
        }
        scope (exit)
            RegCloseKey(hKey);

        DWORD type = 0;
        DWORD byteSize = 0;
        auto queryRes = RegQueryValueExW(hKey, toUTF16z(valueName), null, &type, null, &byteSize);
        if (queryRes == ERROR_FILE_NOT_FOUND && optionalMissing)
            return "";
        if (queryRes != ERROR_SUCCESS && queryRes != ERROR_MORE_DATA)
            throw new Exception(format("RegQueryValueExW(%s\\%s) size query failed with code %s",
                subkey, valueName, queryRes));
        if (byteSize == 0)
            return "";

        auto buf = new ubyte[](byteSize + 2);
        DWORD actualSize = byteSize;
        queryRes = RegQueryValueExW(hKey, toUTF16z(valueName), null, &type, cast(LPBYTE) buf.ptr, &actualSize);
        if (queryRes != ERROR_SUCCESS)
            throw new Exception(format("RegQueryValueExW(%s\\%s) read failed with code %s",
                subkey, valueName, queryRes));

        auto wchars = cast(const(WCHAR)[]) buf[0 .. (actualSize / WCHAR.sizeof) * WCHAR.sizeof];
        size_t len = wchars.length;
        while (len > 0 && wchars[len - 1] == 0)
            len--;
        auto raw = wchars[0 .. len].idup;

        if (type == REG_EXPAND_SZ || type == REG_SZ)
            return expandWindowsEnvVars(raw);
        return toUTF8(raw);
    }

    private string readWindowsProcessPath()
    {
        auto name = toUTF16z("PATH");
        auto needed = GetEnvironmentVariableW(name, null, 0);
        if (needed == 0)
            return environment.get("PATH", "");
        auto buf = new WCHAR[](needed);
        auto written = GetEnvironmentVariableW(name, buf.ptr, needed);
        if (written == 0)
            return environment.get("PATH", "");
        return toUTF8(buf[0 .. written]);
    }

    private RegistryPathSnapshot readWindowsRegistryPaths()
    {
        RegistryPathSnapshot snap;
        snap.processPath = readWindowsProcessPath();
        snap.machinePath = readRegistryPathValue(
            HKEY_LOCAL_MACHINE,
            `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`,
            "Path",
            false);
        snap.userPath = readRegistryPathValue(
            HKEY_CURRENT_USER,
            `Environment`,
            "Path",
            true);
        return snap;
    }

    private void applyWindowsProcessPath(string newPath)
    {
        if (!SetEnvironmentVariableW(toUTF16z("PATH"), toUTF16z(newPath)))
            throw new Exception(format("SetEnvironmentVariableW(PATH) failed with Win32 error %s",
                GetLastError()));
        // Keep D's std.process.environment / CRT synchronized as well.
        environment["PATH"] = newPath;
    }
}
