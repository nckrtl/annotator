// Read-only running-application identity check; the caller launches the signed app first.
ObjC.import('AppKit');
function run(argv) {
    if (argv.length !== 2) throw new Error('Expected bundle ID and installed executable path');
    const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    const matches = [], helpers = [];
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i);
        if (!app.bundleIdentifier) continue;
        const id = ObjC.unwrap(app.bundleIdentifier);
        if (typeof id !== 'string') continue;
        const entry = {id: id, pid: Number(app.processIdentifier), path: app.executableURL ? ObjC.unwrap(app.executableURL.path) : null};
        if (id === argv[0]) matches.push(entry);
        else if (id.startsWith(argv[0] + '.')) helpers.push(entry);
    }
    if (matches.length !== 1 || matches[0].path !== argv[1])
        throw new Error('Main identity is ambiguous: ' + JSON.stringify(matches));
    return JSON.stringify({main: matches[0], helpers: helpers});
}
