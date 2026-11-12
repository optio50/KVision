#ifndef HEADLESSEVENTS_H
#define HEADLESSEVENTS_H

#include <QString>

// `kvision --headless-events`: a small, window-less process that keeps the detection log going while the UI is
// closed. It runs no QML and no video; it reads the recorder list and detection settings from the config file,
// listens to every camera's event stream through the same HikvisionEvents/HikvisionEventLogger the UI uses, and
// steps aside (closes its connections) whenever a KVision window process is running, so only one of them ever
// holds a camera's event stream. Returns the process exit code.
int runHeadlessEvents(int argc, char *argv[]);

// True when the command line asks for the headless mode.
bool wantsHeadlessEvents(int argc, char *argv[]);

#endif // HEADLESSEVENTS_H
