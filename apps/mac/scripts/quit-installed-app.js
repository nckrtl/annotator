// osascript -l JavaScript quit-installed-app.js /path/to/App.app/Contents/MacOS/executable
// Never select by bundle ID: older helpers register with their parent's ID.
ObjC.import('AppKit');
function run(argv) {
    if (argv.length !== 1) throw new Error('Expected the installed executable path');
    const path = ObjC.unwrap($(argv[0]).stringByStandardizingPath);
    const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    const pids = [];
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i);
        if (!app.executableURL || ObjC.unwrap(app.executableURL.path) !== path) continue;
        if (!app.terminate) throw new Error('Could not terminate PID ' + app.processIdentifier);
        pids.push(Number(app.processIdentifier));
    }
    return pids.join('\n');
}
